# Agent Rules — Source & Attribution

The engineering rule sets in this repo are derived from **agent-rules-books** by ciembor.

- Source: https://github.com/ciembor/agent-rules-books
- Pinned source commit: see `SOURCE_COMMIT.txt`
- License: see `LICENSE` (applies to the derived rule text)

## What is wired where

| Rule set | Mechanism | Location |
| --- | --- | --- |
| Clean Architecture (R. C. Martin) | always-on baseline | `AGENTS.md` (imported by `CLAUDE.md`); full ref `clean-architecture.full.md` |
| Clean Code (R. C. Martin) | on-demand skill | `.claude/skills/clean-code/` |
| Refactoring (M. Fowler) | on-demand skill | `.claude/skills/refactoring/` |
| A Philosophy of Software Design (J. Ousterhout) | on-demand skill | `.claude/skills/a-philosophy-of-software-design/` |
| Domain-Driven Design (E. Evans) | on-demand skill | `.claude/skills/domain-driven-design/` |

Each skill embeds the `mini` rule body; `reference.md` holds the `full` version.

Mandatory, stricter, and outside this set: `/clean-naming` and `/comment-discipline` (global skills) — they win on any naming/comment conflict. See `CLAUDE.md`.

## Updating

Re-clone the source repo, re-copy the `mini` bodies into each `SKILL.md` and the `full` files into `reference.md`, and bump `SOURCE_COMMIT.txt`.
