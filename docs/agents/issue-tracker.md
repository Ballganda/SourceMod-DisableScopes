# Issue tracker: GitHub

Issues and specs live as GitHub issues in `Ballganda/SourceMod-DisableScopes`. Use `gh`; inside a clone it infers the repo from `git remote -v`.

File issues only into the user's own repo, never into `Ballganda/BG-skills` (the repo these skills come from) unless the user owns it. In a fork, `gh` can default to the upstream parent: before the first `gh issue create` of a session, check `gh repo view --json nameWithOwner` and confirm with the user if it is not their repo.

## Operations

- **Create** (also "publish to the issue tracker"): `gh issue create --title "..." --body "..."`, with a heredoc for multi-line bodies.
- **Read** (also "fetch the relevant ticket"): `gh issue view <n> --json number,title,body,labels,comments`.
- **List**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`, plus `--label` / `--state` filters.
- **Sub-issue**: `gh issue create --parent <parent> ...`, or `gh issue edit <parent> --add-sub-issue <child>`. Without sub-issues, put `Part of #<parent>` at the top of the child body.
- **Blocking**: native issue dependencies (UI-visible, canonical). `gh issue create --blocked-by <n>,<n> ...` or `gh issue edit <child> --add-blocked-by <blocker>`. Without dependencies, put `Blocked by: #<n>, #<n>` at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Count open blockers**: `gh api repos/Ballganda/SourceMod-DisableScopes/issues/<n> --jq .issue_dependencies_summary.blocked_by` (0 means startable).
- **Comment**: `gh issue comment <n> --body "..."`.
- **Labels**: `gh issue edit <n> --add-label "..."` / `--remove-label "..."`.
- **Close**: `gh issue comment <n> --body "<why>"`, then `gh issue close <n>` (on an already-closed issue, `gh issue close --comment` drops the comment and still exits 0).

**PRs as a request surface: no.** (`/triage` reads this flag. To turn it on, re-run `/bg-setup` and answer yes.)

## Wayfinding operations

Used by `/wayfinder`. The **map** is one issue; its **child** issues are the tickets.

- **Map**: an issue labelled `wayfinder:map` holding the Notes / Decisions-so-far / Fog body: `gh issue create --label wayfinder:map ...`.
- **Child ticket**: a sub-issue of the map (see **Sub-issue**), labelled `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Without sub-issues, list the child in a task list in the map body and put `Part of #<map>` at the top of the child body.
- **Frontier**: the map's open children (sub-issues or task list), minus any with an open blocker (**Count open blockers** > 0, or an open issue in its `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: comment the answer, close the issue (see **Close**), then append a context pointer (gist + link) to the map's Decisions-so-far.
