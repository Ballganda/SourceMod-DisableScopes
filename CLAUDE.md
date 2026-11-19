## Agent skills

- Issue tracker: GitHub Issues on `Ballganda/SourceMod-DisableScopes` via `gh`. See `docs/agents/issue-tracker.md`.
- Triage labels: see `docs/agents/triage-labels.md`.
- Domain docs: see `docs/agents/domain.md`.
- Models: see `docs/agents/models.md`.
- Replies: to the user in chat. First line, when the message gave an instruction, decision or correction beyond a bare "yes": "Understood: <your interpretation>". Next line: the outcome, in one sentence. Then bullets, each a short clause holding exactly one fact; a reason, example or consequence gets its own bullet. Number them when the user answers per item. Each offer of further work is its own numbered item with a recommendation that "yes" accepts, as is each of two or more decisions. Use a table to compare items across attributes, a code block for code. Write prose when the user asks for an explanation. A subagent's Report follows its caller's format.
