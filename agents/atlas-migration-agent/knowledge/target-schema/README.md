## README.md -- Atlas Data Model: Core Principles

This is the core-principles companion to `schema.sql`. Before anything about
overwriting/correcting, five questions have to be answered, each by its own mechanism, each
deliberately kept separate from the others:

| Question | Mechanism | Mutable? |
| --- | --- | --- |
| **Where did this come from?** | `ingestion_source` -> `input` -> `provenance` | No -- immutable lineage, never rewritten |
| **Who owns the write?** | `chain_group_key` | No -- frozen at write time, propagates automatically if corrected upstream |
| **Who is allowed to read?** | `access_group` / `input_grant` | Yes -- a live, versioned, revisable list |
| **What does this input resolve to?** | `anchor` / `input_anchor` | Append-only -- a new version, never an edit |
| **How does a mistake get fixed?** | `input_anchor` (remap) / `anchor_status_correction` (status) / `rich_data_correction` (value) | Each is its own mechanism, for a reason |

Getting each of these right, and keeping them from leaking into each other, is what makes the
rest of the schema (INTAKE -> INPUT -> RESOLUTION -> ENTITY/INSTRUMENT/POSITION) safe to
overwrite and correct at all.

---

## 1. Lineage: where did this come from?

```
ingestion_source  (one write run -- a job, a one-off API hit, a manual upload)
  -> input        (one record within that run)
    -> entity_name / entity_identifier / ... (the actual facts)
```

- `INGESTION_SOURCE` -- one row per run: `source_type`, `source_subtype` (free text, e.g.
  `"form_adv_monthly"` vs `"form_adv_daily"`, or which legacy system a `system_migration` run
  came from -- pure review/diff metadata, never structural: it plays no part in
  `chain_group_key` or any uniqueness, and isn't duplicated onto any fact table, so two runs
  with different `source_subtype` but the same `source_type`/`org_id` still chain together as
  one writer), `org_id` (private sources only), `pipe_type`, `pipe_run_id` (rerun-safety).
- `INPUT` -- one row per *record* within that run, not per run. This is the real point of
  `INPUT`: one `INGESTION_SOURCE` can contain many `INPUT`s, and now that each one is its own
  addressable row, a single record out of a whole batch can be corrected, or shared with
  another org, without touching any of the others in that same run. Legacy has no equivalent --
  a batch is correctable/shareable only as a whole.
- `PROVENANCE` -- fully optional. Only exists for a fact pulled out of an unstructured document
  (a PDF, a pitch deck): which page, how confident. A fact read from a clean structured field
  has none, because there's nothing to say.

**Worked example** -- one `INGESTION_SOURCE`, three `INPUT`s, each independently correctable:
```sql
INSERT INTO ingestion_source (source_type, source_visibility, pipe_type, recorded_by)
VALUES ('SEC_EDGAR', 'LICENSED', 'DAGSTER', 'pipe-bot');

INSERT INTO input (ingestion_source_id, index, anchor_type, access_group, payload, schema_version) VALUES
  (<source_id>, 0, 'ENTITY', 'SEC', '{"name": "Acme Corp"}', 'v1'),
  (<source_id>, 1, 'ENTITY', 'SEC', '{"name": "Beta Fund"}', 'v1'),
  (<source_id>, 2, 'ENTITY', 'SEC', '{"name": "Acme Corp", "identifier": "123-CIK"}', 'v1');
-- all three came from the same run -- correcting or sharing index 2 never touches 0 or 1
-- access_group is shown here for readability, but it's not an independent choice: it's
-- derived from ingestion_source.source_type/org_id (here, SEC_EDGAR -> 'SEC', see section 3)
-- and the input-insert trigger overwrites whatever value is passed with that derived one.
```

---

## 2. Write ownership: `chain_group_key`

**Whoever wrote a row owns it, full stop.** No "shared ownership" case:

- A `LICENSED` source (SEC, MSCI) is owned by **the source itself** -- there's only one.
- A `PRIVATE` source (a client upload) is owned by **that source's org** -- the same generic
  pipe can be reused by many orgs, so `org_id` is what disambiguates.

`CHAIN_GROUP_KEY` folds that into one opaque, deterministic `UUID`, computed once on
`INGESTION_SOURCE`:

```sql
chain_group_key UUID GENERATED ALWAYS AS (
    CASE WHEN org_id IS NOT NULL
        THEN md5(source_type_to_text(source_type) || ':' || org_id::text)::uuid
        ELSE md5(source_type_to_text(source_type))::uuid
    END
) STORED
```

Deliberately opaque (keyed off `org_id`, not a renameable display name) and a real `GENERATED`
column -- Postgres itself rejects writing to it directly.

**What this avoids**: legacy's equivalent key is a free-text string
(`ingestion_source_group_key`), with no structural tie to who actually wrote a row -- two
different orgs both naming their pipe `"manual"` can collide. Worse, legacy's "one open row per
slot" rule isn't even a real constraint today -- its unique index doesn't cover that case at
all, so the rule is enforced by application code alone, with no backstop. `CHAIN_GROUP_KEY`
closes both gaps: two owners can never land in the same slot, and it's a real `UNIQUE` index,
not a convention:

```sql
CREATE UNIQUE INDEX entity_name_open_slot_idx ON entity_name (entity_id, name_type, chain_group_key)
    WHERE valid_to IS NULL;
```

### The cascade

Correcting `org_id` on an `INGESTION_SOURCE` recomputes its `chain_group_key` automatically, but
every `INPUT`/fact row underneath it already copied the old value. Two triggers cascade the fix
down, one hop at a time (`ingestion_source -> input -> every fact table`), touching only rows
still carrying the stale value.

**The safety net**: the cascade runs through each table's normal `UNIQUE` constraint, not around
it. If a correction would merge two already-independent, already-open chains, Postgres rejects
the whole thing, atomically -- a real collision that needs a human, not something to silently
let one owner overwrite another's row.

---

## 3. Read entitlement: `access_group` / `input_grant`

Orthogonal to ownership -- never consulted for who can overwrite what, only for who can *read*.

- `access_group` -- **not an independent choice.** Derived from `source_type`/`org_id`, same
  two inputs as `chain_group_key`, computed on `ingestion_source` and copied down to `input`:
  `SEC_ADV`/`SEC_EDGAR` -> `SEC`, `MSCI` -> `MSCI`, `ARCH` -> `ARCH`, `MANUAL`/`PITCH_DECK`/
  `SYSTEM_MIGRATION` -> `OPTO` if the firm's own org, else `CLIENT`. Correcting `org_id` later
  cascades a changed `access_group` the same way it cascades `chain_group_key`.
- `input_grant` -- the only genuinely independent, mutable entitlement lever, used for the
  `CLIENT` case specifically: a versioned, full-snapshot list of which orgs currently have read
  access:
  ```sql
  CREATE TABLE input_grant (
      input_id UUID NOT NULL REFERENCES input (input_id),
      version INTEGER NOT NULL,
      org_id UUID[] NOT NULL,
      recorded_by TEXT NOT NULL,
      recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
      PRIMARY KEY (input_id, version)
  );
  ```
  Each version is the entire grant list at that point, not a single add/revoke -- full history,
  no extra bookkeeping.

Granting Org B read access to Org A's row never lets Org B's writes supersede it -- Org B's
writes still land under Org B's own `chain_group_key`. Revoking the grant later has zero effect
on ownership either. The two mechanisms never influence each other, in either direction.

---

## 4. Resolution: what does this input resolve to?

- **`ANCHOR`** -- a bare `(anchor_id, type)` registry. Lets one column point generically at
  `ENTITY`/`INSTRUMENT`/`POSITION` with a real, type-checked foreign key.
- **`INPUT_RESOLUTION_ATTEMPT`** (+ `INPUT_RESOLUTION_CANDIDATE`) -- the process log. One row
  per resolver *execution*, including failed/ambiguous ones that never produce a belief.
- **`INPUT_ANCHOR`** -- the belief. Versioned, one row per `(input_id, version)` -- NOT
  append-only: `version = 0` is always the current belief, and a correction retires the old
  current row to a historical slot before inserting the new belief at `version = 0` (see
  section 5a). The only thing anything else reads to know "what anchor does this input
  resolve to" -- never the attempt log, never a separate pointer table.

`version = 0` per `input_id` is always current by construction, so there's no separate
"current pointer" to maintain. Legacy actually built one of those once
(`resolution_input_target`) and its own correction code never kept it updated -- confirmed by
reading the code. Not repeating that mistake here.

---

## 5. Correction: how does a mistake get fixed?

Three different kinds of mistake, three different mechanisms -- merging them into one generic
table was tried and rejected, because each needs its own shape to stay type-safe.

### 5a. Remapping -- fixing *which anchor* an input resolves to

Lives on `INPUT_ANCHOR` itself. `VERSION = 0` is always the current belief -- same convention
already used elsewhere in the codebase (`ATTACHMENT_VERSION`). Correcting it retires the old
current row to a permanent historical slot (`UPDATE ... SET version = COALESCE(MAX(version),
0) + 1`), then inserts the new belief at `version = 0` with `correction_operation`/`reason`
attached -- enforced by a trigger: the very first belief must have no reason, every correction
always must.

**The fact rows underneath it get hard-deleted, never closed with `valid_to`.** `valid_to` means
"this was true, until it wasn't." A remapping correction means something else: this row was
never true for this entity at all -- the resolver got it wrong from the start. There's no date
it "stopped" being true, so the row is deleted outright (with any surviving rows in that same
ownership slot getting their temporal chain repaired). The correction's own history still
isn't lost -- that lives on `INPUT_ANCHOR`, not on the fact table.

### 5b. Status flips -- no remapping at all

`ANCHOR_STATUS_CORRECTION` -- pure status changes (mark as test, delete, reactivate) that never
touch `INPUT_ANCHOR`, because the anchor an input resolves to isn't changing.

### 5c. Value-level fixes -- correcting one fact row's content

`RICH_DATA_CORRECTION` -- a surgical fix to one row's value (a typo, a mis-keyed identifier),
with a full `old_value`/`new_value` snapshot. Routes through a real `INPUT_ID` like every other
write, instead of the special-cased `NULL` legacy writes for manual fixes today.

### Why these three stay separate

Remapping needs real foreign keys into `ANCHOR` (a generic JSONB pair would lose that).
Status flips have no before/after value to record at all. Value fixes need a full row
snapshot, not an anchor pointer. Different questions, different shapes.

---

## Net effect

Ownership and read entitlement are unchanged -- sections 2 and 3 are what Atlas already has.
What's new is lineage, resolution, and correction sitting on top with real constraints where
production currently relies on application code alone: a real `UNIQUE` index, a required
`INPUT_ID`, one versioned belief table instead of three uncoordinated ones, and a correction
model that's honest about "this changed" versus "this was never true."
