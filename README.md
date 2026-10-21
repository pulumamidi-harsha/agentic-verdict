# agentic-verdict

**AI Pass 2 hub** — final LLM review, PR comment, and labels.

Runs **after**:

1. `agentic-review` (Pass 1 + checks + security; may produce coverage)
2. `agentic-quality-gate` (Sonar-style gate using that data)

This repo does **not** run Semgrep, lint, or Docker. It only consumes artifacts and posts the `🤖 AI Code Review` verdict. Future DAST / Burp results can feed the same Pass 2 step.
