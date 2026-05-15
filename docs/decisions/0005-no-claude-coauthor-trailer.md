# 0005 — No `Co-Authored-By: Claude` trailer in commits

**Status:** Accepted
**Date:** 2026-05-14

## Context

Earlier sessions appended a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer to commits Claude helped with. This is harmless on private repos, but the homelab repo is public on GitHub. The trailer:

1. Reads as marketing on every commit page.
2. Doesn't reflect responsibility — every change is reviewed and validated by the operator before commit; the trailer overstates the AI's role.
3. Clutters `git log --author=...` and shortlog views.

## Decision

No `Co-Authored-By: Claude` trailer in any commit on this repo. Existing trailers in 18 historical commits were stripped via a bulk rewrite on 2026-05-14.

## Consequences

- Commit messages stay terse and operator-attributed.
- AI assistance is implicit, not a publication credit on every change.
- Don't reintroduce the trailer in future commits.

## Alternatives considered

- **Keep the trailer** — fits the emerging GitHub convention for AI tooling, but doesn't match this repo's authorship reality (every change is operator-reviewed before commit).
- **Trailer only on Claude-written-then-merged-as-is changes** — too fiddly to enforce in practice; default to off.
