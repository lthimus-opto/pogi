# To Be Reviewed

Raw material copied from `deadlock-atlas` (another repo's worktree), not
yet reviewed or integrated into this agent's `knowledge/`, `queries/`, or
skills. Treat these as **unverified input**, not established fact —
nothing here has been cross-checked against this repo's
`knowledge/capacity_baselines.md` or `knowledge/failure_modes.md` yet.

- `aurora-serverless-min-capacity-request.md`
- `db-incident-investigation-runbook.md`
- `embedding-hnsw-memory-investigation.md`
- `warmup-dry-run-payload.json`

## Next step

Once reviewed: fold confirmed, reusable parts into the real structure
(`knowledge/capacity_baselines.md` for baseline numbers,
`knowledge/failure_modes.md` for catalogued incidents,
`.pi/skills/incident-playbooks` for the runbook-shaped content,
`queries/` for any reusable SQL) and either delete the source file here
or leave it as an archived reference — then delete this README's
"unreviewed" framing.
