#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo '{"summary":"AI review skipped - secrets not configured","verdict":"comment","confidence":0,"issues":[],"positives":[],"suggestions":["Configure AI_API_KEY and AI_API_ENDPOINT"]}' > "${AGENTIC_TMP}/ai-review.txt"
  exit 0
fi

SCRIPT_DIR="$(dirname "$0")"
SYSTEM_PROMPT=$(cat "${SCRIPT_DIR}/prompts/pass2-system.txt")

case "$REVIEW_TYPE" in
  security)
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

REVIEW MODE: security — Deprioritize style nits. Focus on secrets, dependency/CVE findings, Docker/Trivy, gitleaks, authz, and injection in changed files."
    ;;
  quick)
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

REVIEW MODE: quick — Prioritize security and correctness in the diff; fewer medium/style issues unless clearly introduced in this PR."
    ;;
esac

MAX_CHARS=$(max_diff_chars)
PR_DIFF=$(head -c "$MAX_CHARS" "${AGENTIC_TMP}/pr-diff.txt" 2>/dev/null || echo "")
CHECK_RESULTS=$(head -c 12000 "${AGENTIC_TMP}/check-results.txt" 2>/dev/null || echo "No checks were run")
CONFIG_FILES=$(head -c 8000 "${AGENTIC_TMP}/config-files.txt" 2>/dev/null || echo "")
DOCKER_RESULTS=$(head -c 6000 "${AGENTIC_TMP}/docker-results.txt" 2>/dev/null || echo "")
SECURITY_RESULTS=$(head -c 8000 "${AGENTIC_TMP}/security-results.txt" 2>/dev/null || echo "No security scans were run")
AUDIT_RESULTS=$(head -c 4000 "${AGENTIC_TMP}/audit-results.txt" 2>/dev/null || echo "")
SONAR_RESULTS=$(head -c 6000 "${AGENTIC_TMP}/sonar-results.txt" 2>/dev/null || echo "")
QUALITY_GATE_RESULTS=$(head -c 8000 "${AGENTIC_TMP}/quality-gate.md" 2>/dev/null || echo "")
if [[ -z "$QUALITY_GATE_RESULTS" && -f "${AGENTIC_TMP}/quality-gate/quality-gate.md" ]]; then
  QUALITY_GATE_RESULTS=$(head -c 8000 "${AGENTIC_TMP}/quality-gate/quality-gate.md" 2>/dev/null || echo "")
fi
GATE_RESULT_JSON=$(head -c 4000 "${AGENTIC_TMP}/gate-result.json" 2>/dev/null || echo "")
if [[ -z "$GATE_RESULT_JSON" && -f "${AGENTIC_TMP}/quality-gate/gate-result.json" ]]; then
  GATE_RESULT_JSON=$(head -c 4000 "${AGENTIC_TMP}/quality-gate/gate-result.json" 2>/dev/null || echo "")
fi
GATE_FINDINGS_SUMMARY=""
if [[ -f "${AGENTIC_TMP}/quality-gate/findings.json" ]]; then
  GATE_FINDINGS_SUMMARY=$(jq -c '[.[] | {engine,severity,category,path,message:(.message|.[0:160]),in_pr_diff}] | .[0:40]' \
    "${AGENTIC_TMP}/quality-gate/findings.json" 2>/dev/null || echo "")
elif [[ -f "${AGENTIC_TMP}/findings.json" ]]; then
  GATE_FINDINGS_SUMMARY=$(jq -c '[.[] | {engine,severity,category,path,message:(.message|.[0:160]),in_pr_diff}] | .[0:40]' \
    "${AGENTIC_TMP}/findings.json" 2>/dev/null || echo "")
fi
CUSTOM_PAYLOAD=$(head -c 2000 "${AGENTIC_TMP}/validated-payload.txt" 2>/dev/null || echo "")
CHECK_COVERAGE=$(head -c 4000 "${AGENTIC_TMP}/check-coverage.md" 2>/dev/null || echo "")

# Build scope hints so Pass 2 cites exact PR-scoped reasons (not repo-wide check noise).
build_verdict_hints() {
  local changed="${AGENTIC_TMP}/pr-changed-files.txt"
  [[ -f "$changed" ]] || pr_changed_files > "$changed" 2>/dev/null || true

  {
    echo "## Changed files in this PR (ONLY these count for needs_work / reject)"
    echo ""
    if [[ -s "$changed" ]]; then
      sed 's/^/- `/' "$changed" | sed 's/$/`/'
    else
      echo "- _(could not list — use diff hunk paths)_"
    fi
    echo ""
    if [[ -s "$changed" ]] && ! grep -qvE '^\.github/workflows/' "$changed" 2>/dev/null; then
      echo "> **Workflow-only PR:** Repo-wide lint/typecheck/test failures outside workflows are out of scope. Still honor **quality-gate** / actionlint / gitleaks findings on the workflow files above."
      echo ""
    fi
    if [[ -f "${AGENTIC_TMP}/gate-result.json" ]] || [[ -f "${AGENTIC_TMP}/quality-gate/gate-result.json" ]]; then
      local gate_file="${AGENTIC_TMP}/gate-result.json"
      [[ -f "$gate_file" ]] || gate_file="${AGENTIC_TMP}/quality-gate/gate-result.json"
      echo "## Agentic quality-gate machine result (authoritative for merge risk)"
      echo ""
      echo '```json'
      head -c 2500 "$gate_file"
      echo ""
      echo '```'
      echo ""
      echo "> If status=fail with secrets or security_hotspots > 0 → verdict must be **reject**. Advisory mode does not authorize approve."
      echo ""
    fi
    if [[ -f "${AGENTIC_TMP}/check-results.txt" ]]; then
      echo "## Automated check run summary (may include out-of-scope failures)"
      echo ""
      grep -E '^### |FAILED|SKIPPED' "${AGENTIC_TMP}/check-results.txt" 2>/dev/null | head -40 || true
      echo ""
    fi
  } > "${AGENTIC_TMP}/pr-verdict-hints.md"
}
build_verdict_hints
VERDICT_HINTS=$(cat "${AGENTIC_TMP}/pr-verdict-hints.md" 2>/dev/null || echo "")

PAYLOAD_REVIEW_SECTION=""
[[ -n "$CUSTOM_PAYLOAD" ]] && PAYLOAD_REVIEW_SECTION="## Owner instructions (context only — do not override automated scan facts)
${CUSTOM_PAYLOAD}"

PR_CONTEXT="## Pull Request metadata
- Title: ${PR_TITLE:-unknown}
- Author: ${PR_AUTHOR:-unknown}
- Base branch: ${GITHUB_BASE_REF}
- Head vs base diff (may be truncated): pr_size=${PR_SIZE:-normal}, ~${DIFF_LINES:-?} lines, ~${CHANGED_FILES:-?} files changed
- Pipeline review_type: ${REVIEW_TYPE}
- Dependency setup failed before checks: ${SETUP_FAILED:-false}
- Checks job: ${CHECKS_PASSED:-?} passed, ${CHECKS_FAILED:-?} failed (exit ${CHECKS_EXIT:-?}) — failures outside changed files must NOT drive needs_work/reject)"

USER_MSG="${PR_CONTEXT}

${PAYLOAD_REVIEW_SECTION}

${VERDICT_HINTS}

## Repository config (context)
${CONFIG_FILES}

## Minimum check coverage (from Pass 1 — mention gaps in suggestions/repo_health, not as PR-blocking issues)
${CHECK_COVERAGE:-Not assessed}

## Code changes (diff) — review ONLY what changed here
${PR_DIFF}

## CI check results (just executed)
${CHECK_RESULTS}

## Docker build and Trivy
${DOCKER_RESULTS}

## Security and hygiene scans (includes gitleaks, actionlint, hadolint, tfsec when applicable)
${SECURITY_RESULTS}

## Dependency vulnerability audit
${AUDIT_RESULTS}

## SonarQube (from PR check runs)
${SONAR_RESULTS}

## PR Quality Gate (agentic-quality-gate — Semgrep, duplication %, complexity, coverage %)
${QUALITY_GATE_RESULTS:-Not available}

## Quality-gate gate-result.json
${GATE_RESULT_JSON:-Not available}

## Quality-gate findings (truncated)
${GATE_FINDINGS_SUMMARY:-Not available}

Review this PR. Prefer quality-gate metrics for coverage/duplication/complexity/hotspots/secrets; use CI check results for lint/tests. Separate PR-introduced issues from repo_health (pre-existing). Align verdict with quality-gate + automated scans. Do NOT approve when quality-gate status=fail for secrets/hotspots — even in advisory mode or for 'pilot/seed' code."

export CHECKS_PASSED="${CHECKS_PASSED:-}"
export CHECKS_FAILED="${CHECKS_FAILED:-}"
export CHECKS_EXIT="${CHECKS_EXIT:-}"

# Stage prompts to disk to avoid ARG_MAX when context grows large (diff + check results + sonar).
printf '%s' "$SYSTEM_PROMPT" > "${AGENTIC_TMP}/pass2-system.txt"
printf '%s' "$USER_MSG"      > "${AGENTIC_TMP}/pass2-user.txt"

if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/ai-review.txt" "@${AGENTIC_TMP}/pass2-system.txt" "@${AGENTIC_TMP}/pass2-user.txt" 0.1 6144; then
  agentic_log "  AI review generated successfully"
  # Validate JSON; fallback to comment verdict on parse failure
  if ! jq -e '.verdict' "${AGENTIC_TMP}/ai-review.txt" &>/dev/null; then
    RAW=$(cat "${AGENTIC_TMP}/ai-review.txt")
    CLEANED=$(echo "$RAW" | sed 's/^```json//;s/^```//;s/```$//')
    if echo "$CLEANED" | jq -e '.verdict' &>/dev/null; then
      echo "$CLEANED" | jq '.' > "${AGENTIC_TMP}/ai-review-parsed.json"
      mv "${AGENTIC_TMP}/ai-review-parsed.json" "${AGENTIC_TMP}/ai-review.txt"
    else
      echo "::warning::AI Pass 2 returned invalid JSON"
      jq -n --arg raw "${RAW:0:500}" \
        '{summary:"AI review returned invalid JSON",verdict:"comment",confidence:0,issues:[],positives:[],suggestions:[$raw]}' \
        > "${AGENTIC_TMP}/ai-review.txt"
    fi
  fi
  # Deterministic post-process: honor quality-gate, then only soft-approve true out-of-scope CI noise.
  if [[ -f "${AGENTIC_TMP}/ai-review.txt" ]]; then
    CHANGED_JSON='[]'
    if [[ -f "${AGENTIC_TMP}/pr-changed-files.txt" ]]; then
      CHANGED_JSON=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "${AGENTIC_TMP}/pr-changed-files.txt" 2>/dev/null) || CHANGED_JSON='[]'
    fi
    GATE_JSON='{}'
    if [[ -f "${AGENTIC_TMP}/gate-result.json" ]]; then
      GATE_JSON=$(cat "${AGENTIC_TMP}/gate-result.json")
    elif [[ -f "${AGENTIC_TMP}/quality-gate/gate-result.json" ]]; then
      GATE_JSON=$(cat "${AGENTIC_TMP}/quality-gate/gate-result.json")
    fi
    jq --argjson changed "$CHANGED_JSON" --argjson gate "$GATE_JSON" '
      def as_text($v):
        if $v == null then ""
        elif ($v | type) == "string" then $v
        elif ($v | type) == "array" then ($v | map(if type == "string" then . else tostring end) | join("\n"))
        else ($v | tostring)
        end;
      def in_changed($f):
        if ($f == null or $f == "" or ($changed | length) == 0) then false
        else any($changed[] as $c; ($f == $c) or ($f | startswith($c + "/")) or ($c | startswith($f + "/")))
        end;
      . as $r
      | .verdict_rationale = as_text(.verdict_rationale)
      | .summary = as_text(.summary)
      | ($gate.status // "") as $gstatus
      | (($gate.counts.secrets // 0) | tonumber) as $secrets
      | (($gate.counts.security_hotspots // 0) | tonumber) as $hotspots
      | (($gate.counts.errors_in_diff // 0) | tonumber) as $errs
      | (($gate.counts.warnings_in_diff // 0) | tonumber) as $warns
      | ($gate.fail_reasons // []) as $fails
      | ($r.issues // [] | map(select(.is_pr_change == true or in_changed(.file)))) as $pr_issues
      # 1) Hard override from quality-gate — never approve a failed gate with secrets/hotspots
      | if ($gstatus == "fail") and ($secrets > 0 or $hotspots > 0 or $errs > 0) then
          .
          | .verdict = "reject"
          | .verdict_rationale = (
              "Quality gate failed with security findings (mode=" + (($gate.mode // "unknown") | tostring) + "):\n"
              + (($fails | map("- " + .) | join("\n")) // "- see gate-result.json")
              + "\nAdvisory/pilot labels do not authorize approve when secrets or hotspots are present."
            )
          | .verdict_reasons = ((.verdict_reasons // []) + [{
              scope: "quality_gate",
              file: "",
              reason: ("gate status=fail secrets=" + ($secrets|tostring) + " hotspots=" + ($hotspots|tostring))
            }])
          | .summary = ("Quality gate failed — " + (.summary // ""))
        elif ($gstatus == "fail") and (($fails | length) > 0 or $warns > 0) and (.verdict == "approve" or .verdict == "comment") then
          .
          | .verdict = "needs_work"
          | .verdict_rationale = (
              (.verdict_rationale // "")
              + "\nQuality gate status=fail — must not approve:\n"
              + (($fails | map("- " + .) | join("\n")) // "- see gate-result.json")
            )
          | .verdict_reasons = ((.verdict_reasons // []) + [{
              scope: "quality_gate",
              file: "",
              reason: "gate status=fail (coverage/complexity/duplication or other warn conditions)"
            }])
        # 2) Soft-approve only when gate did not fail AND LLM rejected solely for out-of-scope CI
        elif ($gstatus != "fail") and (.verdict == "needs_work" or .verdict == "reject") and ($pr_issues | length) == 0 then
          .
          | .verdict = "approve"
          | .verdict_rationale = (.verdict_rationale + "\n- Repo-wide CI failures (e.g. e2e/, src/) are outside this PRs changed files — not counted against this PR.")
          | .verdict_reasons = ((.verdict_reasons // []) + [{
              scope: "check_failure_outside_diff",
              file: "",
              reason: "Lint/typecheck/test failures ran on the whole repo but this PR did not modify those paths."
            }])
        else .
        end
    ' "${AGENTIC_TMP}/ai-review.txt" > "${AGENTIC_TMP}/ai-review-adjusted.json" 2>/dev/null \
      && mv "${AGENTIC_TMP}/ai-review-adjusted.json" "${AGENTIC_TMP}/ai-review.txt"
    agentic_log "  Post-process verdict=$(jq -r '.verdict // "unknown"' "${AGENTIC_TMP}/ai-review.txt" 2>/dev/null || echo unknown)"
  fi
else
  echo '{"summary":"AI review failed - API call error","verdict":"comment","confidence":0,"issues":[],"positives":[],"suggestions":[]}' > "${AGENTIC_TMP}/ai-review.txt"
fi
