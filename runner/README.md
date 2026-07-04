# runner — Phase 3 TypeScript sidecar (do not build yet)

Thin wrapper over `@anthropic-ai/claude-agent-sdk`, added only when the
ideation engine needs hooks (PreToolUse gates), subagents, or structured
outputs beyond what `claude -p` provides. Contract: same NDJSON event stream
on stdout that `harness/lib/harness/runs/event_ingest.ex` already consumes —
the Elixir side must never care which runner produced the events (spec §2).
