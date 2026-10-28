# Data Agent

An autonomous agent that reads data from a source (Security Master
first), maps it onto Atlas's ontology, QCs it, and proposes
`gate_verdict` rows in MotherDuck for a downstream pipe to load into
Atlas. It never writes to the source or to Atlas directly.

This directory is organized into three parts:

## 1. Operating instructions — `.pi/`

- `.pi/AGENTS.md` — standing rules that apply on every run (tool
  restrictions, storage boundary, non-interactive behavior). Loaded
  automatically every session.
- `.pi/skills/` — on-demand instructions for each task, each pointing at
  the matching file in `knowledge/` for the actual substance:
  - `tooling-pipeline` → `knowledge/tooling_process.md`
  - `source-mapping` → `knowledge/mapping_guide.md`
  - `failure-modes` → `knowledge/failure_modes.md`
  - `ingest-schemas` → `knowledge/ingest_gate_schema.md`
  - `atlas-ontology` → `../docs/atlas_data_model.md` (+ the live Atlas
    schema and the `opto_atlas_service` SDK — see that skill for the
    authority order between the three)
- `.pi/extensions/safety-guard.ts` — enforces the storage boundary
  (read-only sources, headless runs confined to `.scratch/`).

## 2. Knowledge — `knowledge/`

The living, incident-driven reference docs. Each one is discovered,
tested against real data, and refined by a human across sessions — this
is where confirmed facts and rules accumulate, not where they're
invented mid-run (see `.pi/AGENTS.md`'s non-interactive rules).

- `knowledge/mapping_guide.md` — how to map any source onto Atlas's
  Entity/Instrument/Position ontology; the Security Master worked example.
- `knowledge/failure_modes.md` — catalog of confirmed data-quality
  failure modes, with trigger predicates and severities.
- `knowledge/ingest_gate_schema.md` — the `gate_verdict`/`gate_relationship`
  table schema and verdict logic.
- `knowledge/tooling_process.md` — the extract/build/write pipeline,
  and the incident history behind why it's shaped the way it is.

## 3. Project background — `project/`

Narrative docs for humans; nothing here is read by the agent at runtime.

- `project/vision.md` — why this exists, the confidence-bucket
  philosophy, the use case, and where the process is headed.
- `project/roadmap.md` — the longer-term always-on, multi-source
  architecture (Loop A/B). Not being built yet.

## The task spec and the runner

- `TASK_SPEC.md` — the actual Tasks 1-5 the agent executes end to end
  for one source. This is what `run_prompt.md` tells the agent to run.
- `run_prompt.md` / `run.ts` — the invocation harness (prompt template +
  SDK entry point: `npm run run:sm`, or `npx tsx run.ts <source> <env-file>`).
  See `run.ts` directly for how a run is actually kicked off.

## Everything else

- `connect.sh` + `.env.<database>.prod` — read-only DB access via IAM
  auth, fresh token every call.
- `queries/` — ad-hoc reference SQL from past investigations.
- `.scratch/` (gitignored) — scratch SQL, reproducible pipeline scripts
  per run, and the only place headless runs may write on disk.
