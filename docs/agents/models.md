# Models

Each ticket carries a tier (set by `ticket-gen`), and each subagent task has a model. Skills read this file to pick the model; edit the names to match your harness.

| Tier | Use for | Model |
| --- | --- | --- |
| Mechanical | rename, config, docs, copy of an existing pattern | Haiku |
| Standard | one module, a clear seam, tests that describe it | Sonnet |
| Hard | crosses modules, a new seam, concurrency, unclear spec | Opus |

| Subagent task | Model |
| --- | --- |
| Exploration | the Mechanical model |
| Merging | the Standard model |
| Standards review | the Standard model |
| Spec review | the Hard model |
