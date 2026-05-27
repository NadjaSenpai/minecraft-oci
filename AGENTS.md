# AGENTS.md

Guidance for AI coding agents working in the `minecraft-oci` repository.

## Agent skills

### Issue tracker

Issues and PRDs are tracked as **GitHub issues** via the `gh` CLI (the repo is inferred from the git remote). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles using their **default label names** (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

**Single-context**: one `CONTEXT.md` + `docs/adr/` at the repo root (created lazily by `/grill-with-docs`). See `docs/agents/domain.md`.
