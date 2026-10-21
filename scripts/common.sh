#!/usr/bin/env bash
# Shared helpers for agentic-review pipeline scripts.
set -euo pipefail

AGENTIC_TMP="${AGENTIC_TMP:-/tmp/agentic-verdict}"
mkdir -p "$AGENTIC_TMP"

REVIEW_TYPE="${REVIEW_TYPE:-${INPUT_REVIEW_TYPE:-full}}"
SKIP_DOCKER="${SKIP_DOCKER:-false}"

if [[ -f "${AGENTIC_TMP}/pipeline-flags.json" ]]; then
  REVIEW_TYPE=$(jq -r '.review_type // "'"${REVIEW_TYPE}"'"' "${AGENTIC_TMP}/pipeline-flags.json")
  SKIP_DOCKER=$(jq -r '.skip_docker // "false"' "${AGENTIC_TMP}/pipeline-flags.json")
  SKIP_SECURITY=$(jq -r '.skip_security // "false"' "${AGENTIC_TMP}/pipeline-flags.json")
  SKIP_CHECKS=$(jq -r '.skip_checks // "false"' "${AGENTIC_TMP}/pipeline-flags.json")
  MAX_DIFF_LINES=$(jq -r '.max_diff_lines // 15000' "${AGENTIC_TMP}/pipeline-flags.json")
fi
SKIP_SECURITY="${SKIP_SECURITY:-false}"
SKIP_CHECKS="${SKIP_CHECKS:-false}"
MAX_DIFF_LINES="${MAX_DIFF_LINES:-15000}"
AI_MODEL="${AI_MODEL:-gpt-4.1}"
GITHUB_BASE_REF="${GITHUB_BASE_REF:-${GITHUB_EVENT_PULL_REQUEST_BASE_REF:-main}}"

agentic_log() { echo "$@"; }

should_run_checks() {
  [[ "$SKIP_CHECKS" == "true" ]] && return 1
  [[ "$REVIEW_TYPE" == "security" ]] && return 1
  return 0
}

should_run_docker() {
  [[ "$SKIP_DOCKER" == "true" ]] && return 1
  [[ "$REVIEW_TYPE" == "quick" ]] && return 1
  return 0
}

should_run_dep_audit() {
  [[ "$REVIEW_TYPE" == "quick" ]] && return 1
  return 0
}

should_run_security_scans() {
  [[ "$SKIP_SECURITY" == "true" ]] && return 1
  return 0
}

should_run_heavy_hygiene() {
  [[ "$REVIEW_TYPE" == "quick" ]] && return 1
  return 0
}

truncate_pr_diff() {
  local diff_file="${AGENTIC_TMP}/pr-diff.txt"
  [[ -f "$diff_file" ]] || return 0
  local lines
  lines=$(wc -l < "$diff_file" | tr -d ' ')
  if [[ "$lines" -gt "$MAX_DIFF_LINES" ]]; then
    agentic_log "  Truncating PR diff from ${lines} to ${MAX_DIFF_LINES} lines (max_diff_lines)"
    head -n "$MAX_DIFF_LINES" "$diff_file" > "${diff_file}.trunc"
    mv "${diff_file}.trunc" "$diff_file"
  fi
}

max_diff_chars() {
  echo $(( MAX_DIFF_LINES * 120 ))
}

# Files added or modified in this PR (one path per line)
pr_changed_files() {
  git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" 2>/dev/null || true
}

pr_added_files() {
  git diff --name-only --diff-filter=A "origin/${GITHUB_BASE_REF}...HEAD" 2>/dev/null || true
}

write_github_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}
