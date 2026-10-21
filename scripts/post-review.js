const fs = require('fs');
const path = require('path');

const AGENTIC_TMP = process.env.AGENTIC_TMP || '/tmp/agentic-review';
const COMMENT_MARKER = '<!-- agentic-review:comment -->';

function read(filePath, fallback = '') {
  try { return fs.readFileSync(filePath, 'utf8'); } catch { return fallback; }
}

function details(summary, content, open = false) {
  if (!content || !String(content).trim()) return '';
  const tag = open ? '<details open>' : '<details>';
  return `${tag}<summary>${summary}</summary>\n\n${String(content).trim()}\n\n</details>\n`;
}

function subsection(title, content) {
  if (!content || !String(content).trim()) return '';
  return `#### ${title}\n\n${String(content).trim()}\n`;
}

function toBulletLines(value) {
  if (value == null || value === '') return [];
  if (Array.isArray(value)) return value.flatMap(v => toBulletLines(v));
  if (typeof value === 'object') {
    return Object.entries(value).map(([k, v]) => `- ${k}: ${v}`);
  }
  return String(value).split('\n').map(l => l.trim()).filter(Boolean);
}

function shortSummary(text, maxLen = 280) {
  const t = (Array.isArray(text) ? text.join(' ') : String(text || '')).trim();
  if (t.length <= maxLen) return t;
  const cut = t.slice(0, maxLen);
  const last = cut.lastIndexOf('. ');
  return (last > 100 ? cut.slice(0, last + 1) : cut) + '…';
}

function formatDuration(seconds) {
  if (seconds == null || Number.isNaN(seconds) || seconds < 0) return '—';
  const s = Math.round(seconds);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return rem ? `${m}m ${rem}s` : `${m}m`;
}

function getDurationSeconds() {
  const timerPaths = [
    process.env.TIMER_FILE,
    path.join(process.env.RUNNER_TEMP || '/tmp', 'timer.txt'),
  ].filter(Boolean);

  for (const p of timerPaths) {
    try {
      const start = parseInt(read(p).trim(), 10);
      if (start > 0) return Math.round(Date.now() / 1000) - start;
    } catch { /* try next */ }
  }

  if (process.env.TIMER_START) {
    const start = parseInt(process.env.TIMER_START, 10);
    if (start > 0) return Math.round(Date.now() / 1000) - start;
  }

  if (process.env.GITHUB_RUN_STARTED_AT) {
    const started = Date.parse(process.env.GITHUB_RUN_STARTED_AT);
    if (!Number.isNaN(started)) return Math.round((Date.now() - started) / 1000);
  }

  return null;
}

function parseFailedChecks(text) {
  const failed = [];
  for (const m of String(text).matchAll(/^### (.+?) -- FAILED/gm)) {
    failed.push(m[1].trim());
  }
  return failed;
}

function parseSkippedChecks(text) {
  const skipped = [];
  for (const m of String(text).matchAll(/^### (.+?) -- SKIPPED/gm)) {
    skipped.push(m[1].trim());
  }
  return skipped;
}

/** Remove summary line from check-results — stats shown once in run summary. */
function stripCheckResultsHeader(text) {
  let t = String(text).trim();
  t = t.replace(/^\*\*Summary:\*\*[^\n]*\n+/i, '');
  return t.trim();
}

function buildCiCoverageBlock(data) {
  if (!data || !Object.keys(data).length) return '';

  const expectations = data.expectations || [];
  const gaps = expectations.filter(e => e.is_gap);
  const parts = [];

  if (data.summary) parts.push(String(data.summary).trim());

  if (gaps.length) {
    parts.push('', '**Recommended — add these CI checks:**');
    gaps.forEach(g => {
      const rec = g.recommendation || 'Configure this in your repo and CI pipeline.';
      parts.push(`- **${g.label}** — ${rec}`);
    });
  } else if (expectations.length && data.status === 'complete') {
    parts.push('', '_Expected CI categories (lint, tests, build, etc.) are configured or covered._');
  } else if (expectations.length) {
    parts.push('', '_See coverage matrix below._');
  }

  const showMatrix = expectations.length > 0 && (gaps.length > 0 || data.status !== 'complete');
  if (showMatrix) {
    parts.push(
      '',
      '| Check | In repo | This run |',
      '|-------|:-------:|:--------:|',
      ...expectations.map(e =>
        `| ${e.label} | ${e.repo_configured ? '✅' : '—'} | ${e.pipeline_planned ? '✅' : '—'} |`
      ),
    );
  }

  return parts.join('\n').trim();
}

function workflowRunUrl() {
  const server = process.env.GITHUB_SERVER_URL || 'https://github.com';
  const repo = process.env.GITHUB_REPOSITORY;
  const runId = process.env.GITHUB_RUN_ID;
  if (!repo || !runId) return null;
  return `${server}/${repo}/actions/runs/${runId}`;
}

function severityEmoji(sev) {
  return { critical: '🚨', high: '🔴', medium: '🟡', low: '🔵', info: 'ℹ️' }[sev] || '·';
}

let review = read(`${AGENTIC_TMP}/ai-review.txt`, '{}');
let checks = read(`${AGENTIC_TMP}/check-results.txt`, 'No results');
let commands = {};
try { commands = JSON.parse(read(`${AGENTIC_TMP}/ai-commands.json`, '{}')); } catch {}
const dockerResults = read(`${AGENTIC_TMP}/docker-results.txt`).trim();
const securityResults = read(`${AGENTIC_TMP}/security-results.txt`).trim();
const auditResults = read(`${AGENTIC_TMP}/audit-results.txt`).trim();
const customPayload = read(`${AGENTIC_TMP}/validated-payload.txt`).trim();
const checkCoverageMd = read(`${AGENTIC_TMP}/check-coverage.md`).trim();
let coverageData = {};
try { coverageData = JSON.parse(read(`${AGENTIC_TMP}/check-coverage.json`, '{}')); } catch {}
const pass1SummaryMd = read(`${AGENTIC_TMP}/pass1-summary.md`).trim();
const instructionSource = read(`${AGENTIC_TMP}/instruction-source.txt`, 'none').trim();
const passed = process.env.CHECKS_PASSED ?? '0';
const failed = process.env.CHECKS_FAILED ?? '0';
const checksExit = process.env.CHECKS_EXIT ?? '0';
const setupFailed = process.env.SETUP_FAILED === 'true';
const dockerFound = process.env.DOCKER_FOUND === 'true';
const securityExit = process.env.SECURITY_EXIT || '0';
const prSize = process.env.PR_SIZE || 'normal';
const diffLines = process.env.DIFF_LINES || '0';
const changedFiles = process.env.CHANGED_FILES || '0';
const reviewType = process.env.REVIEW_TYPE || 'full';
const prScope = (process.env.PR_SCOPE || read(`${AGENTIC_TMP}/pr-scope.txt`, 'code')).trim() || 'code';

const durationStr = formatDuration(getDurationSeconds());
const runUrl = workflowRunUrl();
const failedChecks = parseFailedChecks(checks);
const skippedChecks = parseSkippedChecks(checks);

let reviewData = {};
try {
  const cleaned = review.replace(/^```json\n?/, '').replace(/\n?```$/, '');
  reviewData = JSON.parse(cleaned);
} catch {
  reviewData = { summary: review.substring(0, 500), verdict: 'comment', confidence: 0, issues: [], positives: [], suggestions: [] };
}

const stackInfo = commands.stack
  ? `${commands.stack.language || '?'} · ${commands.stack.framework || '?'} · ${commands.stack.package_manager || '?'}`
  : 'Unknown';

const payloadAnalysis = commands.payload_analysis || null;

const setupCount = (commands.setup_commands || []).length;
const checkCount = (commands.check_commands || []).length;

const checksRan = Number(passed) + Number(failed);
const checksSkipped = skippedChecks.length;
const checksPlanned = checkCount;

const cmdList = (commands.check_commands || [])
  .map((c, i) => `${i + 1}. \`${c.cmd}\` — ${c.purpose} _(${c.confidence})_`)
  .join('\n');

const verdictMap = {
  approve: ['✅', 'APPROVED', 'No blocking issues in the files you changed.'],
  needs_work: ['⚠️', 'NEEDS WORK', 'Fix the issues in your changed files before merge.'],
  reject: ['🔴', 'CHANGES REQUIRED', 'Blocking issues in your changed files must be fixed.'],
  comment: ['ℹ️', 'REVIEW', 'See findings below.'],
};
const [verdictEmoji, verdictLabel, verdictLead] = verdictMap[reviewData.verdict] || verdictMap.comment;

function formatChecksSummary() {
  if (checksPlanned === 0 && checksRan === 0) return 'None configured';
  const parts = [];
  if (checksPlanned > 0) parts.push(`${checksPlanned} planned`);
  parts.push(`${checksRan} run`, `${passed} passed`);
  if (Number(failed) > 0) parts.push(`${failed} failed`);
  if (checksSkipped > 0) parts.push(`${checksSkipped} skipped`);
  return parts.join(' · ');
}

const checksStatusLine = formatChecksSummary();
const sandboxInformational = Number(failed) > 0
  && (reviewData.verdict === 'approve' || reviewData.verdict === 'comment');
let checksStatus;
if (prScope === 'workflow_only') {
  checksStatus = '— skipped (workflow-only PR · use repo CI)';
} else if (Number(failed) > 0 && sandboxInformational) {
  checksStatus = `ℹ️ ${checksStatusLine} (sandbox only · not repo CI)`;
} else if (Number(failed) > 0) {
  checksStatus = `❌ ${checksStatusLine}`;
} else if (setupFailed) {
  checksStatus = `⚠️ ${checksStatusLine} (setup failed)`;
} else if (checksRan === 0 && checksPlanned === 0) {
  checksStatus = '— none configured';
} else {
  checksStatus = `✅ ${checksStatusLine}`;
}
const securityStatus = securityExit === '0' ? '✅ clean' : '⚠️ findings';

const prIssues = (reviewData.issues || []).filter(i => i.is_pr_change !== false);
const otherIssues = (reviewData.issues || []).filter(i => i.is_pr_change === false);
const filesWithPrIssues = [...new Set(prIssues.map(i => i.file).filter(Boolean))];

const verdictReasons = reviewData.verdict_reasons || [];
const prReasons = verdictReasons.filter(r => r.scope === 'pr_change');
const outsideReasons = verdictReasons.filter(r => r.scope === 'check_failure_outside_diff' || r.scope === 'pre_existing');
const prChangedFiles = read(`${AGENTIC_TMP}/pr-changed-files.txt`).trim().split('\n').filter(Boolean);

const verdictWhyLines = [];
toBulletLines(reviewData.verdict_rationale).forEach(l => {
  verdictWhyLines.push(l.startsWith('-') ? l : `- ${l}`);
});
if (prReasons.length) {
  prReasons.forEach(r => verdictWhyLines.push(`- \`${r.file || 'PR'}\`: ${r.reason}`));
}
if (outsideReasons.length) {
  verdictWhyLines.push('', '_Not counted against this PR:_');
  outsideReasons.forEach(r => verdictWhyLines.push(`- ${r.reason}`));
}

const quickLinks = [
  prIssues.length || reviewData.verdict !== 'approve' ? '[Issues](#issues-in-your-changed-files)' : null,
  '[Checks & logs](#full-check-output)',
  '[Repo health](#repository-health)',
  runUrl ? `[Workflow run](${runUrl})` : null,
].filter(Boolean).join(' · ');

const verdictSection = [
  `### ${verdictEmoji} ${verdictLabel}`,
  '',
  verdictLead,
  '',
  shortSummary(reviewData.summary) ? `**Summary:** ${shortSummary(reviewData.summary)}` : '',
  prChangedFiles.length
    ? `**Files you changed (${prChangedFiles.length}):** ${prChangedFiles.map(f => `\`${f}\``).join(' · ')}`
    : '',
  filesWithPrIssues.length && reviewData.verdict !== 'approve'
    ? `**Fix these files:** ${filesWithPrIssues.map(f => `\`${f}\``).join(' · ')}`
    : '',
  verdictWhyLines.length ? `\n**Why**\n${verdictWhyLines.join('\n')}` : '',
].filter(Boolean).join('\n');

const failedChecksAlert = Number(failed) > 0 && failedChecks.length
  ? (sandboxInformational
    ? `\n> ℹ️ **Sandbox checks:** ${failed} of ${checksRan} did not pass in the agentic runner (this is **not** your repo CI). The verdict above is based on your **PR diff** only.\n`
    : `\n> ⚠️ **${failed} of ${checksRan} check(s) failed:** ${failedChecks.map(c => `\`${c}\``).join(' · ')} — expand [Full check output](#full-check-output) for logs.\n`)
  : setupFailed
    ? '\n> ⚠️ **Dependency setup failed** — sandbox checks were skipped or may reflect missing secrets (e.g. Artifactory), not your code.\n'
    : prScope === 'workflow_only'
      ? '\n> ℹ️ **Sandbox lint/test skipped** — this PR only changes workflows. Trust your repo CI for quality gates.\n'
      : '';

const checkLogBody = stripCheckResultsHeader(checks);
const checkLogSummary = checksRan > 0
  ? `_Showing output for ${checksRan} executed check(s).${checksSkipped ? ` ${checksSkipped} skipped (low confidence or out of scope).` : ''}_`
  : '';

const issuesTable = prIssues.length
  ? [
    '| File | Sev | Issue |',
    '|------|:---:|-------|',
    ...prIssues.map(i => {
      const file = i.file ? `\`${i.file}${i.line ? ':' + i.line : ''}\`` : '—';
      const title = i.suggestion
        ? `**${i.title}** — ${i.description}<br>💡 ${i.suggestion}`
        : `**${i.title}** — ${i.description}`;
      return `| ${file} | ${severityEmoji(i.severity)} | ${title} |`;
    }),
  ].join('\n')
  : '';

const runSummaryTable = [
  '| | |',
  '|:---|:---|',
  `| **Stack** | ${stackInfo} |`,
  `| **Checks** | ${checksStatus} |`,
  `| **Security scans** | ${securityStatus} |`,
  `| **Review mode** | ${reviewType} · ${changedFiles} files · ${diffLines} diff lines |`,
  `| **Duration** | ${durationStr} |`,
  runUrl ? `| **Workflow** | [View run #${process.env.GITHUB_RUN_ID || '?'}](${runUrl}) |` : '',
].filter(Boolean).join('\n');

const ownerInstructionsBlock = customPayload ? [
  customPayload.split('\n').filter(l => l.trim()).map(l => `> ${l.trim()}`).join('\n'),
  '',
  `- **Source:** \`${instructionSource}\``,
  `- **Accepted:** ${payloadAnalysis?.accepted_count ?? 'all'}`,
  payloadAnalysis?.overrides?.length
    ? `- **Overrides:** ${payloadAnalysis.overrides.join('; ')}`
    : '',
].filter(Boolean).join('\n') : '';

const commandsRunBlock = [
  `**Setup commands (${setupCount}):**`,
  setupCount
    ? (commands.setup_commands || []).map((c, i) => `${i + 1}. \`${c.cmd}\` — ${c.purpose}`).join('\n')
    : '_None_',
  '',
  `**Check commands (${checkCount}):**`,
  cmdList || '_None_',
  commands.dependency_audit?.cmd
    ? `\n**Dependency audit:** \`${commands.dependency_audit.cmd}\``
    : '',
].join('\n');

const ciCoverageBlock = buildCiCoverageBlock(coverageData)
  || (checkCoverageMd ? checkCoverageMd.replace(/^##[^\n]*\n+/, '').trim() : '');

const repoHealth = reviewData.repo_health || {};
const healthEmoji = { healthy: '✅', needs_attention: '⚠️', critical: '🚨' }[repoHealth.status] || 'ℹ️';
const repoHealthBlock = [
  repoHealth.summary ? `**Status:** ${healthEmoji} ${(repoHealth.status || 'unknown').replace(/_/g, ' ')}\n\n${repoHealth.summary}` : '',
  (repoHealth.issues || []).length
    ? '\n**Pre-existing issues**\n' + repoHealth.issues.map(i =>
      typeof i === 'string' ? `- ${i}` : `- ${i.title || i.description || ''}`
    ).filter(Boolean).join('\n')
    : '',
  (repoHealth.recommendations || []).length
    ? '\n**Recommendations**\n' + repoHealth.recommendations.map(r => `- ${r}`).join('\n')
    : '',
].filter(Boolean).join('\n');

const positives = (reviewData.positives || []).map(p => `- ${p}`).join('\n');
const suggestions = (reviewData.suggestions || []).map(s => `- ${s}`).join('\n');
const issuesOther = otherIssues.map(i => {
  const loc = i.file ? `\`${i.file}\`` : '';
  return `- ${severityEmoji(i.severity)} **${i.title}** ${loc} — ${i.description}`;
}).join('\n');

const securityAndHygiene = [
  securityResults,
  dockerFound && dockerResults ? `**Docker / Trivy**\n\n${dockerResults}` : '',
  auditResults ? `**Dependency audit**\n\n${auditResults}` : '',
].filter(Boolean).join('\n\n---\n\n');

const fullCheckOutput = [
  subsection('🧪 CI analysis', reviewData.check_results_analysis),
  subsection('🔒 Security analysis', reviewData.security_analysis),
  subsection('⚙️ Commands run', commandsRunBlock),
  checkLogBody
    ? details(
      `📋 Check logs (${checksRan} run · ${passed} passed · ${failed} failed${checksSkipped ? ` · ${checksSkipped} skipped` : ''})`,
      [checkLogSummary, checkLogBody].filter(Boolean).join('\n\n'),
      Number(failed) > 0,
    )
    : '',
  securityAndHygiene.trim()
    ? subsection('🛡️ Security & hygiene scans', securityAndHygiene)
    : '',
].filter(Boolean).join('\n\n');

const repositoryHealth = [
  repoHealthBlock,
  ciCoverageBlock ? subsection('📊 CI check coverage', ciCoverageBlock) : '',
  issuesOther ? subsection(`🔍 Outside your diff (${otherIssues.length})`, issuesOther) : '',
  positives ? subsection('✅ What\'s good (repository)', positives) : '',
  suggestions ? subsection('💡 Suggestions (repository)', suggestions) : '',
].filter(Boolean).join('\n\n');

const sizeWarning = prSize === 'very_large'
  ? `\n> ⚠️ **Large PR** — ${diffLines} lines across ${changedFiles} files. Consider splitting.\n`
  : prSize === 'large'
  ? `\n> 📝 ${diffLines} lines · ${changedFiles} files\n`
  : '';

const body = [
  COMMENT_MARKER,
  `## 🤖 AI Code Review — ${verdictEmoji} ${verdictLabel}`,
  '',
  quickLinks ? `**Jump to:** ${quickLinks}` : '',
  '',
  verdictSection,
  failedChecksAlert,
  sizeWarning,
  '',
  runSummaryTable,
  '',
  prIssues.length
    ? `### Issues in your changed files (${prIssues.length})\n\n${issuesTable}\n`
    : reviewData.verdict !== 'approve'
      ? '### Issues in your changed files\n\n_No file-specific issues listed — see verdict above._\n'
      : '',
  customPayload
    ? `### Owner instructions\n\n${details('Custom rules for this repo', ownerInstructionsBlock)}`
    : '',
  fullCheckOutput.trim()
    ? `### Full check output\n\n${details('Expand — CI analysis, commands, logs, scans', fullCheckOutput)}`
    : '',
  repositoryHealth.trim()
    ? `### Repository health\n\n${details('Expand — CI gaps, pre-existing issues, repo-wide suggestions', repositoryHealth)}`
    : '',
  pass1SummaryMd
    ? `### Pipeline plan\n\n${details('Expand — Pass 1 detection details', pass1SummaryMd)}`
    : '',
  '',
  '---',
  `<sub>🤖 <a href="https://github.com/pulumamidi-harsha/agentic-review">agentic-review</a> · updated each run · ${durationStr} total</sub>`,
].filter(Boolean).join('\n');

module.exports = {
  body,
  reviewData,
  durationStr,
  COMMENT_MARKER,
};
