Standing authority - **this project only**. Approved by Yoni 2026-11-09 ("add the AUTHORITY.md to the other repositories"). Act on it; do not re-ask.

Written from Yoni's global rules (`~/.claude/CLAUDE.md`) and the shared plan (Vault `3 Resources/playbooks/RAZI-PLAN.md`). It gives no extra
power beyond them. Where this file and the repo's own `CLAUDE.md` disagree, follow the repo's file and fix this one in the same change.

**Do these without asking:**
create and close worktrees and branches · open PRs · **fix failing CI and push again until green**
(rules in `~/.claude/rules/ci-loop.md`) · verify the result · close finished issues · update this repo's notes
(`STATUS.md`, `DECISIONS.md`, `ROADMAP.md`) when they exist, in the same change.

**Agents never merge and never push `main` directly.** The CI robot merges where this repo has it; otherwise Yoni merges.

**Always ask first - these are NOT covered:**
- Anything touching production data, real customers, money or messages that reach a real person.
- Secrets, keys, DNS, servers, billing.
- Going live (a deploy), or publishing to a live site, Google, social or a client.
- Rewriting a decision already locked in `DECISIONS.md`.

**Two rules that survive the authority:**
1. Never skip or weaken a test to get green.
2. "CI green" is not "it works". After a visible change, open it and look. If you cannot, say so.
