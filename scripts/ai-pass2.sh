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
      echo "> **Workflow-only PR:** Failures from repo-wide lint/typecheck/test (e2e/, src/, etc.) are **pre-existing / out of scope**. Verdict must be **approve** unless actionlint/security finds issues **in the workflow files above**."
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

Review this PR. Prefer quality-gate metrics for coverage/duplication/complexity/hotspots; use CI check results for lint/tests. Separate PR-introduced issues from repo_health (pre-existing). Align verdict with quality-gate + automated scans."

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
  # If verdict penalizes PR but no issue is in changed files, correct to approve.
  if [[ -f "${AGENTIC_TMP}/ai-review.txt" ]]; then
    CHANGED_JSON='[]'
    if [[ -f "${AGENTIC_TMP}/pr-changed-files.txt" ]]; then
      CHANGED_JSON=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "${AGENTIC_TMP}/pr-changed-files.txt" 2>/dev/null) || CHANGED_JSON='[]'
    fi
    jq --argjson changed "$CHANGED_JSON" '
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
      | ($r.issues // [] | map(select(.is_pr_change == true or in_changed(.file)))) as $pr_issues
      | if (.verdict == "needs_work" or .verdict == "reject") and ($pr_issues | length) == 0 then
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
  fi
else
  echo '{"summary":"AI review failed - API call error","verdict":"comment","confidence":0,"issues":[],"positives":[],"suggestions":[]}' > "${AGENTIC_TMP}/ai-review.txt"
fi
