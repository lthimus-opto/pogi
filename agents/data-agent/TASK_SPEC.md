# Data Agent — Task Spec

This is the operational spec `run_prompt.md` tells the agent to execute,
end to end, given one source: Tasks 1-5 below. For the why behind this
process — the confidence-bucket philosophy, the use case, where this is
headed — see `project/vision.md`. For the standing rules that apply on
every run regardless of task, see `.pi/AGENTS.md`.

## 0. Mode: inception vs. incremental

Every run is one of two types, decided by `run_prompt.md`'s `{{MODE}}`
(see `knowledge/tooling_process.md`'s "Modes" section for the full
mechanics):

- **inception** — the first run against a source (or scope). Tasks 1-5
  below apply in full, against the entire scope, no delta.
- **incremental** — every run after inception, scheduled or on-demand (the two
  are the same code path, differing only in what triggers them). Task 1
  extracts only what changed since the local raw tables' own last-known
  state (watermark derived live, never persisted); Tasks 2-4 rescore
  only the changed records plus the bounded one-hop set
  `knowledge/ingest_gate_schema.md`'s "Incremental scoring" section defines
  (immediate parent, and for updates, siblings); Task 5 writes the
  changed record unconditionally and any pulled-in parent/sibling only
  if its own recomputed result actually differs from its current latest
  row.

## 1. Extract the data.

- If a DB source is handed over with no specific table named, first
  generate a schema diagram (e.g. `tbls`, `eralchemy2` against the
  reader role) -- get oriented on the whole structure before pulling
  any rows.
- Via `data-agent/connect.sh` (CLI + `psql`, IAM auth token regenerated
  fresh on every call -- tokens are fixed at 15 minutes by AWS, not
  extendable, so the fix is regenerating rather than trying to make one
  last longer) plus one `.env.<database>.prod` file per target
  database.
- For extraction itself: DuckDB's `postgres_scanner` reading directly
  from the live source into MotherDuck — no CSV intermediary, no local
  `.duckdb` file. See `data-agent/knowledge/tooling_process.md` for the
  standard pipeline and why: CSV round-trips burned tokens and
  introduced their own bugs (column misalignment, type coercion), and a
  local file is opaque to a human reviewing the work — MotherDuck isn't.
  **For an `incremental` run** (per step 0 above), this step pulls a delta
  (`updated_at` past the local raw table's own live-derived watermark)
  and merges it into the existing raw table by replace-by-id
  (`ANTI JOIN` + `UNION ALL`, never `NOT IN`), not a full
  `CREATE OR REPLACE TABLE ... AS SELECT *` — see
  `data-agent/knowledge/tooling_process.md`'s "Modes" section for the
  exact SQL pattern.
- For building the actual Atlas SDK payload (nested attributes, fees,
  strategies) — SQL directly against the raw MotherDuck tables
  (`to_json()`/struct literals), same as everything else in this
  pipeline -- no `.py` file, see `data-agent/knowledge/tooling_process.md`
  and the `tooling-pipeline` skill. Verify the target shape against the
  installed `opto_atlas_service` package directly (see `atlas-ontology`)
  rather than assuming any doc's shape is complete.
- All prod databases share one Aurora cluster -- same host/region/
  profile, different `POSTGRES_DB` and reader role per target.

## 2. Map the source onto Atlas.

- What's constant across every session is **Atlas itself** -- its
  decision test and its attribute vocabulary (`../docs/atlas_data_model.md`)
  -- never the source's own table shape. A source can arrive as several
  relational tables, one flat table, a JSON payload, a PDF extraction,
  anything; the mapping method doesn't change with it.
- For every discrete fact in the source, apply Atlas's own decision
  test ("Deciding Where Data Lives" in `atlas_data_model.md`), in
  order: is this true of the legal person itself, independent of any
  claim it issued (-> Entity)? Is this true of the terms of a specific
  claim, shared by everyone who holds it (-> Instrument)? Is this
  specific to one holder's economics on that claim (-> Position)?
- Watch for source-specific reification and conflation while doing
  this -- a source construct whose only job is to group other
  constructs under a shared label (e.g. SM's fund-family table vs.
  Atlas's `fund_family_label`, a plain grouping attribute) collapses
  into an attribute, not its own entity; a source row that blends two
  Atlas levels (e.g. SM's `SECURITY` row mixing fund-level term-length
  facts with true instrument-level fee facts) needs to be split back
  apart.
- Applying the mapping is diagnostic on its own, before any row-level
  value is checked: reification, conflation, and source columns that
  describe internal workflow rather than Atlas facts (approval status,
  diligence status, deal-pipeline state) all surface at this stage --
  these fail the decision test on their own terms, no out-of-scope
  list needed.
- The general method, plus the Security Master mapping
  (manager -> fund family -> fund -> security) worked all the way
  through as the first case study, lives in
  `data-agent/knowledge/mapping_guide.md`. Extend that doc with new
  sources as they come up; don't re-derive the reasoning from scratch
  each time.

## 3. Find data points that are wrong.

- Once a source has a mapping, "wrong" means "violates the mapping
  already derived for this source" -- not "re-derive what Atlas would
  expect here from scratch." This step checks specific data
  instances, not the source's structure (that's Task 2's job).
- Only flag an instance when the problem, or the fix, is unambiguous
  -- not something reasonable people could disagree on.
- Every confirmed instance becomes an entry in
  `data-agent/knowledge/failure_modes.md` -- a name, a falsifiable
  trigger predicate, the evidence to capture, and an honest note on how
  many instances confirm it so far. An incident is one bad row; a
  failure mode is the generalized rule that would catch it again. Don't
  skip straight from one incident to "this is a rule now."
- Not every failure mode gates the same thing -- some mean the whole
  record shouldn't load yet (or ever, without a source fix); others
  mean the record is fine but one specific value on it looks wrong.
  `knowledge/failure_modes.md` calls out which is which.

## 4. Propose what the corrected version should look like.

- For whole-record admission failures, this is a verdict --
  `LOAD` / `DEFER` / `REJECT` -- not a value correction, written as one
  row in the single `gate_verdict` table
  (`data-agent/knowledge/ingest_gate_schema.md`). That table replaced an
  earlier three-table design mirroring Atlas's own `RESOLUTION_STAGING` /
  `RESOLUTION_INPUT_TARGET` / `RESOLUTION_INPUT_SNAPSHOT` pattern --
  tested against real data and simplified once the extra tables proved
  to add nothing a human reviewing verdicts needed.
- Verdicts are based on **two independent QC dimensions**, not raw
  source fill rates: **completeness** (a core field mapped, ratio
  against expected fields) and **accuracy** (does the content
  contradict itself, e.g. name says "Credit" but strategy says
  "Private Equity"). See `knowledge/ingest_gate_schema.md` for the
  current rule and how the two combine into `verdict`.
- For field-level value failures (a record that should load, but one
  value on it is likely wrong), the correction itself is what gets
  proposed -- as the `accuracy_severity = 'correct'` case on the same
  `gate_verdict` row (`accuracy_proposed_value`), not a separate table.
  There is no `ingest_correction_schema.md` anymore. **Before using a
  `correct`-severity failure mode, verify the field actually contains
  convertible content** -- a narrative/free-text field holding a
  placeholder (`'null'`, `'none'`, `'n/a'`, empty/whitespace) is not
  "narrative has a rate," it's just missing data, and firing an
  accuracy rule on it produces a garbage `accuracy_proposed_value`
  (confirmed real case: `narrative_rate_not_captured` firing on literal
  `'null'` strings and proposing `"null|null"` as the fix -- see
  `knowledge/failure_modes.md`). The standing goal is to map **any**
  data point that has a real home in Atlas's ontology, narrative or
  structured -- so a `correct`-severity rule must actually parse the
  narrative into the real target value (e.g. "2% of committed capital"
  -> `0.02`), not just restate or concatenate the raw text into
  `accuracy_proposed_value`.
- Every record's `gate_verdict` row carries its own place in the
  source's hierarchy via `parent_input_id` -- the parent record's own
  `input_id` one level up (manager for a fund, fund for an instrument;
  `NULL` for a manager, which has no parent). This is in addition to,
  not instead of, `gate_relationship` below -- it's what makes the
  hierarchy readable directly off `gate_verdict` without rejoining raw
  source tables, and it's exactly the FK `gate_relationship` needs to
  build its own rows. **A run that writes `gate_verdict` rows without
  `parent_input_id` populated is incomplete** -- see
  `knowledge/ingest_gate_schema.md`.
- A relationship between two records (manager `manages` fund, etc.) is
  **not** a `gate_verdict` row -- it goes in the separate
  `gate_relationship` table (`knowledge/ingest_gate_schema.md`), because
  its payload needs a real, already-resolved Atlas `entity_id` on the
  target side, which this agent never has at write time. **Writing
  `gate_verdict` without also writing `gate_relationship` for every
  parent/child pair in scope is an incomplete run, not an optional
  extra** -- confirmed real gap: a full-source run wrote 17,770
  `gate_verdict` rows and zero `gate_relationship` rows, leaving no
  record anywhere of which manager a fund belongs to or which fund an
  instrument belongs to.

## 5. Store the proposal into MotherDuck.

- `gate_verdict` **and** `gate_relationship` both live in MotherDuck
  directly, per the storage boundary noted below -- not a
  local-DuckDB-only artifact promoted later. Every run writes both
  tables; a run is not done until `gate_relationship` has a row for
  every parent/child pair among the records just scored (`DEFER`,
  with `payload = NULL`, is a valid and expected state here when the
  parent hasn't resolved in Atlas yet -- it is not a reason to skip
  writing the row).
- `meta.agent_run` gets exactly one row for this invocation, written by
  `run.ts` itself after the agent's work completes (success or
  failure) -- not something the agent writes as part of Tasks 1-4. See
  `knowledge/tooling_process.md`'s "Run tracking" section.

Nothing here ever mutates existing data; the agent only ever proposes; the
existing infrastructure (resolution, `silver_id` attach, source-type
filtering) does everything else, exactly the way it already does for any
other source.

**Storage boundary**: Atlas's Postgres/Aurora cluster and Security Master
are read-only for this agent, full stop -- reached only via `connect.sh`.
Every artifact the agent itself produces (raw extracted tables, gate
verdicts, correction proposals) lives in MotherDuck, never in Postgres,
and never in an opaque local file either -- see
`data-agent/knowledge/tooling_process.md` for why local `.duckdb` files
and CSV intermediaries were dropped. `knowledge/ingest_gate_schema.md` is
written in DuckDB terms for this reason.
