---
name: codex-monitor
description: Inspect and monitor all local Codex processes, active network connection metadata, locally recorded token usage, rate-limit windows, and credit balance. Use when the user asks about Codex traffic, tokens, quota, balance, processes, resource usage, or requests a local monitoring report.
---

# Codex Monitor

Use the bundled script at `../../scripts/codex_monitor.py`.

## Commands

- Current human-readable status: `python3 ../../scripts/codex_monitor.py snapshot`
- Machine-readable status: `python3 ../../scripts/codex_monitor.py snapshot --json`
- Write one HTML report: `python3 ../../scripts/codex_monitor.py report`
- Start continuous macOS monitoring: `python3 ../../scripts/codex_monitor.py install-daemon --interval 10`
- Stop continuous monitoring: `python3 ../../scripts/codex_monitor.py uninstall-daemon`
- Show daemon state: `python3 ../../scripts/codex_monitor.py daemon-status`
- The native menu bar widget is installed at `~/Applications/Codex Monitor.app` by `scripts/install.sh`.

Resolve the script path relative to this SKILL.md before running it. If process or network inspection is denied by the sandbox, request permission and rerun the same read-only command outside the sandbox.

## Interpretation rules

- Say "local observed total" for token totals. The value covers locally retained Codex session files, not necessarily the account's full server-side billing history.
- Report `credits.balance` only when Codex itself recorded a value. Never infer a monetary balance from rate-limit percentages or token totals.
- Treat ChatGPT subscription limits, API billing, and prepaid API credits as distinct concepts.
- `rate_limits` are usage-window telemetry, not currency.
- Network results contain endpoint metadata only. The monitor does not decrypt or capture request/response bodies.
- Never read or print `~/.codex/auth.json`, prompts, responses, tool arguments, terminal command text, environment variables, cookies, or API keys.
- If macOS tools are unavailable, preserve partial results and state which collector failed.

## Reporting

Lead with: running process count, active connection count, local observed tokens, latest rate-limit state, and recorded balance availability. Then list process resource usage and remote endpoints. Mention collector warnings last.
