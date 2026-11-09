-- schema-basic.sql
--
-- Minimal slice of schema.sql -- not a different design, just a deliberately small cut of it:
-- INTAKE -> INPUT -> RESOLUTION -> ENTITY, with ENTITY_NAME and ENTITY_IDENTIFIER as the only
-- facts. See schema.sql for the full version (INSTRUMENT, POSITION, ENTITY_TYPE/
-- ENTITY_ATTRIBUTE, TIME SERIES, ATTACHMENTS) -- this file exists to work out the full
-- create/correct/entitlement/ownership lifecycle in depth on a couple of representative
-- facts before stamping the same shape out across every other one.

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================================================
-- Types
-- ============================================================================================

CREATE TYPE anchor_type AS ENUM ('ENTITY', 'INSTRUMENT', 'POSITION');

-- Which kind of system produced an INGESTION_SOURCE. A real, closed enum, same as legacy's
-- IngestionSourceType -- new sources are rare and deliberate enough to warrant a migration.
CREATE TYPE source_type AS ENUM ('ARCH', 'MANUAL', 'MSCI', 'PITCH_DECK', 'SEC_ADV', 'SEC_EDGAR', 'SYSTEM_MIGRATION');

-- Which orchestration mechanism actually ran the write. AD_HOC covers anything that came
-- straight through the API with no Dagster/Airflow/Lambda job behind it at all.
CREATE TYPE pipe_type AS ENUM ('DAGSTER', 'AIRFLOW', 'AWS_LAMBDA', 'AD_HOC');

-- Determines whether an ingestion source's writer identity needs ORG to disambiguate it when
-- computing CHAIN_GROUP_KEY. PRIVATE sources (an org's own uploads) can be shared by many
-- different orgs through the same generic pipe, so the org is required. LICENSED sources
-- (regulatory filings, licensed vendor feeds) are each inherently a single writer already --
-- there's exactly one SEC, one MSCI -- so no org is needed or allowed.
CREATE TYPE source_visibility AS ENUM ('LICENSED', 'PRIVATE');

-- Entitlement: who is allowed to *read* a fact/attachment. Orthogonal to chain_group_key.
CREATE TYPE access_group AS ENUM ('ARCH', 'OPTO', 'CLIENT', 'SEC', 'MSCI');

CREATE TYPE record_status AS ENUM ('ACTIVE', 'INACTIVE', 'LOGICALLY_DELETED', 'MANUALLY_DELETED', 'TEMPORARY', 'TEST');

-- ============================================================================================
-- Intake
-- ============================================================================================

-- One write run (a job, a one-off API hit, a manual upload). Named and shaped after legacy's
-- INGESTION_SOURCE, with ORG_ID/SOURCE_VISIBILITY promoted to real, checked columns instead of
-- being inferred from SOURCE_TYPE via an app-level lookup table.
--
-- ORG_ID is not a table Atlas owns -- that registry belongs to user_service. It arrives here
-- as a plain, immutable snapshot captured at write time, same as `source_type` -- never
-- looked up via a local join.
--
-- PIPE_RUN_ID is never null -- every write traces back to *something* that ran it, even if
-- that's just "this one API call" (PIPE_TYPE = AD_HOC), in which case it defaults to a fresh
-- random value. SOURCE_EXTERNAL_KEY (legacy's rerun-idempotency key) is deliberately NOT a
-- column here -- callers may still send it on the API, it's just not persisted -- PIPE_RUN_ID
-- plus the UNIQUE constraint below is what rerun-safety is built on instead, and unlike
-- SOURCE_EXTERNAL_KEY it's never redundant with itself (legacy's own pipes passed the exact
-- same `run_id` into both fields in some call sites).
--
-- CHAIN_GROUP_KEY is this ingestion source's writer identity, folded into its SOURCE_TYPE as
-- one opaque, deterministic UUID -- a hash of `source_type` (+ `org_id`, for PRIVATE),
-- computed straight off this same row, no trigger needed:
--   - PRIVATE -> md5(source_type || ':' || org_id)::uuid
--   - LICENSED -> md5(source_type)::uuid -- the source is already a unique writer, nothing
--     to fold in
-- Deliberately opaque, not human-readable -- keying off ORG_ID, not a user_service-owned
-- display name, is the whole point. `source_type`/`org_id` stay around as plain columns for
-- that -- join back here when a human needs to read "whose chain is this."
--
-- SOURCE_TYPE_TO_TEXT exists purely so the GENERATED expression below can call it: Postgres
-- treats an enum's own `::text` cast as STABLE, not IMMUTABLE (a long-standing quirk of
-- enum_out), so it can't be used directly inside a generated column. Wrapping it in our own
-- function we declare IMMUTABLE ourselves sidesteps that -- same trick as `sort_name_words`
-- elsewhere in this file.
CREATE OR REPLACE FUNCTION source_type_to_text(value SOURCE_TYPE) RETURNS TEXT AS $$
    SELECT value::text;
$$ LANGUAGE sql IMMUTABLE;

-- ACCESS_GROUP is derived, never independently chosen -- ported directly from legacy's
-- `get_source_entitlement_group`, the "single point of truth" function legacy's own code
-- warns never to edit without sign-off from the entitlements/data-access owners. Same two
-- inputs as CHAIN_GROUP_KEY (SOURCE_TYPE + ORG_ID), same reasoning: if it's derived from the
-- same facts every time, it shouldn't also be a free column the app can set to anything.
-- OPTO_ORG_ID is legacy's actual hardcoded constant (the firm's own org id) -- kept as the
-- same literal, not re-derived or looked up, matching legacy exactly.
CREATE OR REPLACE FUNCTION source_type_to_access_group(value SOURCE_TYPE, org UUID) RETURNS ACCESS_GROUP AS $$
    SELECT CASE
        WHEN value IN ('SEC_ADV', 'SEC_EDGAR') THEN 'SEC'::access_group
        WHEN value = 'MSCI' THEN 'MSCI'::access_group
        WHEN value = 'ARCH' THEN 'ARCH'::access_group
        WHEN value IN ('MANUAL', 'PITCH_DECK', 'SYSTEM_MIGRATION') THEN
            CASE WHEN org = '2346b7f2-b69f-40bb-a53c-d8447008fe42'::uuid
                THEN 'OPTO'::access_group
                ELSE 'CLIENT'::access_group
            END
    END;
$$ LANGUAGE sql IMMUTABLE;

CREATE TABLE ingestion_source (
    ingestion_source_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    source_type SOURCE_TYPE NOT NULL,
    source_subtype TEXT NOT NULL,
    source_visibility SOURCE_VISIBILITY NOT NULL,
    org_id UUID,
    pipe_type PIPE_TYPE NOT NULL,
    pipe_run_id TEXT NOT NULL DEFAULT gen_random_uuid()::text,
    chain_group_key UUID GENERATED ALWAYS AS (
        CASE WHEN org_id IS NOT NULL
            THEN md5(source_type_to_text(source_type) || ':' || org_id::text)::uuid
            ELSE md5(source_type_to_text(source_type))::uuid
        END
    ) STORED,
    access_group ACCESS_GROUP GENERATED ALWAYS AS (source_type_to_access_group(source_type, org_id)) STORED,
    recorded_by TEXT NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    UNIQUE (chain_group_key, pipe_run_id),
    CHECK ((source_visibility = 'PRIVATE') = (org_id IS NOT NULL))
);

-- ============================================================================================
-- Input
-- ============================================================================================

-- NOT lineage. Lineage (which write produced a fact, through what source/org/pipe, when) is
-- universal -- every fact has it, via INGESTION_SOURCE/INPUT below. PROVENANCE is optional and
-- much narrower: it only ever gets populated when a fact was pulled out of an unstructured
-- document -- a PDF, a pitch deck, a spreadsheet -- via parsing/extraction, and records
-- *where in that document* (page/sheet/row/column) and *how confidently* (confidence/
-- reasoning) the value was pulled out. A fact read straight from a clean structured field
-- (an SEC EDGAR XBRL tag, a named vendor API field) has full lineage but no provenance --
-- there's no "page 14, 73% confidence" to record, because nothing was extracted. Declared
-- before INPUT since INPUT's own fact tables reference it.
CREATE TABLE provenance (
    provenance_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    page INTEGER,
    sheet TEXT,
    source_row INTEGER,
    source_column TEXT,
    confidence NUMERIC,
    reasoning TEXT,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    CHECK (num_nonnulls(page, sheet, source_row, source_column, confidence, reasoning) > 0)
);

-- One addressable item within an ingestion source. Promoted to a real table (legacy only has
-- this implicitly, as a UUID shared across resolution_staging/resolution_input_snapshot rows).
-- PAYLOAD/SCHEMA_VERSION fold in what used to be a separate INPUT_SNAPSHOT table -- the raw
-- claim this input made, before resolution has run, stored as one opaque, replayable blob, not
-- normalized into per-fact-type tables. There's no reason for that to be a separate table: it's
-- a strict one-to-one with INPUT itself, not a one-to-many, so splitting it out just meant an
-- extra join for no benefit. Modeled directly on production's RESOLUTION_INPUT_SNAPSHOT.
-- Unlike that legacy table, this does NOT also carry the resolved target (legacy's
-- origin_entity_id/origin_instrument_id/origin_position_id) -- that's INPUT_ANCHOR's job,
-- exclusively.
--
-- Deliberately no PROVENANCE_ID column here, unlike the fact tables below. PAYLOAD can
-- legitimately bundle several distinct claims (a name, an identifier, an attribute), each
-- potentially extracted from a different page with a different confidence -- a single
-- provenance pointer on the whole INPUT row would be describing all of them at once, which is
-- exactly the kind of granularity mismatch PROVENANCE_ID is supposed to avoid. Provenance only
-- means something at the grain of one atomic claim -- that's each fact table below, not INPUT.
--
-- CHAIN_GROUP_KEY/ACCESS_GROUP here are a straight, one-hop copy of the owning
-- INGESTION_SOURCE's already-finalized values -- set once by a trigger at insert time, never
-- recomputed, never settable directly by app code (same reasoning for both: both are derived
-- from SOURCE_TYPE/ORG_ID, neither is an independent choice). CHAIN_GROUP_KEY gets copied
-- again, one more hop, to every fact table below -- see `set_chain_columns` further down.
-- ACCESS_GROUP stops here; it's a per-INPUT fact, nothing downstream needs its own copy.
--
-- AS_OF lives here, not on INGESTION_SOURCE -- a single ingest (one batch upload) can easily
-- contain items from different reporting periods, so it's a per-item fact, not a per-batch
-- one. Nullable -- not every input has a meaningful business-as-of date.
CREATE TABLE input (
    input_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    ingestion_source_id UUID NOT NULL REFERENCES ingestion_source (ingestion_source_id),
    index INTEGER NOT NULL,
    anchor_type ANCHOR_TYPE NOT NULL,
    access_group ACCESS_GROUP NOT NULL,
    as_of DATE,
    chain_group_key UUID NOT NULL,
    payload JSONB NOT NULL,
    schema_version TEXT NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    UNIQUE (anchor_type, input_id),
    UNIQUE (ingestion_source_id, index)
);

CREATE OR REPLACE FUNCTION set_input_derived_columns() RETURNS TRIGGER AS $$
BEGIN
    SELECT chain_group_key, access_group INTO NEW.chain_group_key, NEW.access_group
      FROM ingestion_source WHERE ingestion_source_id = NEW.ingestion_source_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER input_set_derived_columns
    BEFORE INSERT ON input
    FOR EACH ROW EXECUTE FUNCTION set_input_derived_columns();

-- A correction to an old INGESTION_SOURCE's `org_id` (e.g. fixing a wrong `org_id` after the
-- fact) changes `chain_group_key` AND `access_group` on that row automatically -- both are
-- GENERATED columns, see above. But every INPUT already written under that ingestion source
-- copied the *old* values at insert time, and would otherwise silently keep them forever,
-- going stale. This trigger is the retroactive half: it pushes changed values down to every
-- INPUT row still carrying a stale one. See `cascade_input_chain_group_key` further down for
-- the next hop, from INPUT down to every fact table (CHAIN_GROUP_KEY only -- ACCESS_GROUP has
-- nowhere further to go).
CREATE OR REPLACE FUNCTION cascade_ingestion_source_derived_columns() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.chain_group_key IS DISTINCT FROM OLD.chain_group_key
       OR NEW.access_group IS DISTINCT FROM OLD.access_group THEN
        UPDATE input SET chain_group_key = NEW.chain_group_key, access_group = NEW.access_group
         WHERE ingestion_source_id = NEW.ingestion_source_id
           AND (chain_group_key IS DISTINCT FROM NEW.chain_group_key
                OR access_group IS DISTINCT FROM NEW.access_group);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER ingestion_source_cascade_derived_columns
    AFTER UPDATE ON ingestion_source
    FOR EACH ROW EXECUTE FUNCTION cascade_ingestion_source_derived_columns();

-- Which orgs currently have read access to an input's data. Versioned full-snapshot, same
-- rationale as schema.sql. This is ENTITLEMENT, not ownership -- it's never consulted for
-- chain_group_key/supersession, and changing it never changes who can overwrite what. It can
-- be revised (shared, then un-shared) at any time without touching the fact rows it governs.
--
-- Distinct from ACCESS_GROUP, which isn't a knob at all -- it's derived from SOURCE_TYPE/
-- ORG_ID (see INGESTION_SOURCE above), same as CHAIN_GROUP_KEY. INPUT_GRANT is the only
-- genuinely independent, mutable entitlement lever -- used for the CLIENT case specifically,
-- to share a client's otherwise-private data with other named orgs.
CREATE TABLE input_grant (
    input_id UUID NOT NULL REFERENCES input (input_id),
    version INTEGER NOT NULL,
    org_id UUID[] NOT NULL,
    recorded_by TEXT NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    PRIMARY KEY (input_id, version)
);

-- Dropped for now from this minimal file -- see schema.sql for the real version. Conceptually
-- right (a lookup table of trusted identifier schemes, see the full discussion in that file),
-- but it's one more table to carry through every worked example on this slice, more
-- complexity than this file needs while working out the core lifecycle. ENTITY_IDENTIFIER's
-- `identifier_type` below is a plain TEXT column here, with no FK, as a result.

-- ============================================================================================
-- Chain-group-key propagation -- the structural fix for the write-ownership bug
-- ============================================================================================

-- Every fact table below carries `chain_group_key`, always populated by this trigger as a
-- straight one-hop copy from the INPUT behind the row's `input_id` -- never settable directly
-- by app code. The "one open row per slot" unique index on each fact table keys on this single
-- column, so two different writers (two orgs, or an org vs. a licensed source) can never
-- collide, no matter what source_type either of them shares.
CREATE OR REPLACE FUNCTION set_chain_columns() RETURNS TRIGGER AS $$
BEGIN
    SELECT chain_group_key INTO NEW.chain_group_key FROM input WHERE input_id = NEW.input_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================================
-- Resolution
-- ============================================================================================

-- Generic cross-type identity. Entity/Instrument/Position mint their real-world id here, then
-- carry their own rich data in their own typed table below -- one resolution mechanism shared
-- across all three anchor types instead of three near-duplicate pipelines.
CREATE TABLE anchor (
    anchor_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    type ANCHOR_TYPE NOT NULL,

    UNIQUE (type, anchor_id)
);

-- One row per resolution attempt. INPUT_NAME/INPUT_NAME_TYPE/INPUT_IDENTIFIER_TYPE/
-- INPUT_IDENTIFIER/INPUT_SILVER_ID are what the input actually claimed *at the moment this
-- attempt ran*, denormalized directly onto the row -- matching legacy's RESOLUTION_STAGING.
-- Not redundant with INPUT.PAYLOAD: PAYLOAD is an opaque JSON blob, not indexed/queryable the
-- way these real columns are, and the resolution engine needs to show/filter on exactly what
-- it searched with. RESOLUTION_TARGET_ID/RESOLUTION_CONFIDENCE_SCORE are this attempt's own
-- final decision, denormalized here too (also recorded, authoritatively, in INPUT_ANCHOR via
-- ATTEMPT_ID -- this is a convenience copy for querying attempts directly, not a second
-- source of truth: INPUT_ANCHOR is still what the rest of the system reads from).
--
-- Legacy's INPUT_ENTITY_ID (the entity an INSTRUMENT resolution attempt is scoped to, i.e.
-- its believed issuer) is deliberately not ported here -- this minimal file doesn't model
-- INSTRUMENT at all yet. Needs to come back in schema.sql once instrument resolution is in
-- scope.
CREATE TABLE input_resolution_attempt (
    attempt_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    input_id UUID NOT NULL REFERENCES input (input_id),
    input_name CITEXT,
    input_name_type TEXT,
    input_identifier_type TEXT,
    input_identifier CITEXT,
    input_silver_id CITEXT,
    outcome TEXT NOT NULL,
    method TEXT NOT NULL,
    resolution_target_id UUID REFERENCES anchor (anchor_id),
    resolution_confidence_score NUMERIC,
    reason TEXT,
    recorded_by TEXT NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

-- Two candidate-matching aids. Unlike everything else in this Resolution cluster, these are
-- NOT generalized across anchor types, and deliberately don't live here in the file -- see
-- ENTITY_FUZZY_MATCH/ENTITY_EMBEDDING in the Entity section below instead. Restored to match
-- legacy's real shape exactly: legacy keeps ENTITY_FUZZY_MATCH/INSTRUMENT_FUZZY_MATCH (and
-- the EMBEDDING equivalents) as two separate, entity_id-keyed/instrument_id-keyed tables,
-- never collapsed into one generic, INPUT_ID-keyed table -- and since this file doesn't
-- model INSTRUMENT facts at all, there's nothing to collapse across here either. An earlier
-- version of this file generalized these to INPUT_ID specifically so they'd be reusable
-- across anchor types, but that discovery (worth recording): these aren't facts with their
-- own lineage at all, they're a pure derived SEARCH CACHE of ENTITY_NAME, maintained by
-- application code the same way legacy's `entity_name_store.py` does it (write ENTITY_NAME,
-- then write ENTITY_FUZZY_MATCH/ENTITY_EMBEDDING, same transaction) -- no INPUT_ID, no
-- lineage question, no correction-cascade question, because they're not a source of truth in
-- their own right. The real lineage for a name already lives on ENTITY_NAME itself.

-- Cross-source dedup aid, ported from legacy's SILVER_IDENTIFIER (collapsed across anchor
-- types -- unlike ENTITY_FUZZY_MATCH/ENTITY_EMBEDDING, legacy's own SILVER_IDENTIFIER
-- already generalizes across ENTITY/INSTRUMENT and already carries INPUT_ID, so collapsing
-- it onto INPUT_ID here is restoring legacy's real shape, not inventing a new one). A
-- SILVER_ID is NOT a
-- trusted, registry-grade identifier like a CIK/CUSIP (that's ENTITY_IDENTIFIER's job) -- it's
-- whatever a specific pipeline/vendor uses *internally* to mean "same real-world thing" within
-- its own feed, a weaker but still useful same-source dedup signal. Legacy scoped its
-- uniqueness by (silver_id, ingestion_source_group_key, scoped_to) -- GROUP_KEY doesn't exist
-- in this schema anymore, so CHAIN_GROUP_KEY (already the structural stand-in for "which
-- writer/pipeline produced this") takes over that role instead: a given SILVER_ID is only
-- meaningful for dedup *within* the same CHAIN_GROUP_KEY, never compared across writers.
CREATE TABLE input_silver_identifier (
    silver_identifier_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    input_id UUID NOT NULL REFERENCES input (input_id),
    silver_id CITEXT NOT NULL,
    chain_group_key UUID NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    UNIQUE (chain_group_key, silver_id)
);
CREATE TRIGGER input_silver_identifier_set_chain_columns
    BEFORE INSERT OR UPDATE OF input_id ON input_silver_identifier
    FOR EACH ROW EXECUTE FUNCTION set_chain_columns();

-- An anchor considered (and scored) as a possible match during an attempt. Column names
-- drop the redundant CANDIDATE_/CANDIDATE_MATCH_ prefix legacy's RESOLUTION_STAGING used
-- (this table is already named for exactly that -- same pattern as ATTEMPT_ID not repeating
-- the full INPUT_RESOLUTION_ATTEMPT table name), but otherwise keeps every distinct signal
-- legacy tracked, separately -- these are NOT alternate representations of one score, they
-- routinely co-occur on the same row: CONFIDENCE_SCORE is the final normalized score,
-- RAW_SCORE/EDIT_DISTANCE are the strategy-specific numbers it was computed from (e.g.
-- trigram similarity's raw value), and LLM_CONFIDENCE/LLM_REASONING are a separate, later,
-- independent re-assessment of this same candidate -- only populated if it actually went
-- through the LLM tiebreaker stage, additive to whatever score it already had, never a
-- replacement for it. MATCH_STATUS (what kind of match this was -- EXACT_MATCH, NO_MATCH,
-- LLM_AMBIGUOUS_MATCH...) is a different vocabulary from STRATEGY (how the candidate was
-- found -- TRIGRAM_SIMILARITY_MATCH, EXACT_IDENTIFIER_MATCH...) -- both real, both kept.
-- MATCH_NAME is the candidate's name *as it was at match time* -- kept here even though it's
-- also visible via ANCHOR_ID -> ENTITY_NAME, since that may have since changed; this is a
-- permanent record of what was actually compared against, at the time.
CREATE TABLE input_resolution_candidate (
    attempt_id UUID NOT NULL REFERENCES input_resolution_attempt (attempt_id),
    anchor_id UUID NOT NULL REFERENCES anchor (anchor_id),
    strategy TEXT NOT NULL,
    match_name CITEXT,
    match_status TEXT,
    confidence_score NUMERIC,
    raw_score NUMERIC,
    edit_distance INTEGER,
    llm_confidence NUMERIC,
    llm_reasoning TEXT,
    comment TEXT,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    PRIMARY KEY (attempt_id, anchor_id)
);

-- Versioned mapping of an input to the anchor it resolved to -- NOT append-only, matching the
-- real convention already established elsewhere in this codebase (ATTACHMENT_VERSION):
-- VERSION = 0 is always the current belief, full stop, regardless of how many corrections
-- have happened. Correcting it is a two-step dance, not a plain insert:
--   1. UPDATE the current (version = 0) row to NEXT_VERSION = COALESCE(MAX(version), 0) + 1
--      for this INPUT_ID -- retiring it into a permanent historical slot.
--   2. INSERT the new belief at VERSION = 0.
-- (Same pattern legacy's `attachment_store.py` already uses for ATTACHMENT_VERSION -- not a
-- new idea, just applying the same established convention here.) Concurrency note, matching
-- legacy exactly: the app must lock the owning INPUT row (`SELECT ... FOR UPDATE`) before
-- computing NEXT_VERSION, so two concurrent corrections on the same input can't race on the
-- same retirement slot.
--
-- CORRECTION_OPERATION/REASON/REASON_COMMENT live right here, on whichever row is current --
-- no separate correction table/mechanism needed, and no separate audit table either. Because
-- VERSION = 0 no longer distinguishes "the first belief" from "the tenth" (unlike the
-- earlier, append-only design this replaces), that invariant can't be a plain CHECK anymore --
-- it needs a trigger that looks at whether any row already exists for this INPUT_ID (see
-- `check_input_anchor_reason` below): no prior row -> this is the first belief, nothing to
-- explain yet, reason must be NULL; a prior (now-retired) row exists -> this is a correction,
-- reason is required. RECORDED_BY already captures who wrote this row (for a correction,
-- that's the same person who's correcting it), so no separate CORRECTED_BY is needed either.
--
-- This does NOT cover every correction legacy logs, though -- MARK_AS_TEST/MANUALLY_DELETE/
-- MARK_AS_ACTIVE are pure ANCHOR status changes with no remapping at all, so they never
-- produce a new INPUT_ANCHOR row to attach a reason to. Those still need their own table --
-- see ANCHOR_STATUS_CORRECTION in the Correction cluster below.
CREATE TABLE input_anchor (
    version INTEGER NOT NULL DEFAULT 0,
    input_id UUID NOT NULL,
    input_anchor_type ANCHOR_TYPE NOT NULL,
    anchor_id UUID NOT NULL,
    anchor_type ANCHOR_TYPE NOT NULL,
    attempt_id UUID UNIQUE REFERENCES input_resolution_attempt (attempt_id),
    correction_operation TEXT,
    reason TEXT,
    reason_comment TEXT,
    recorded_by TEXT NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    PRIMARY KEY (version, input_id),
    FOREIGN KEY (input_id, input_anchor_type) REFERENCES input (input_id, anchor_type),
    FOREIGN KEY (anchor_id, anchor_type) REFERENCES anchor (anchor_id, type),
    CHECK (anchor_type = input_anchor_type)
);

-- Enforces the reason rule a plain CHECK can no longer express now that VERSION = 0 doesn't
-- distinguish "first belief" from "tenth" -- this needs to look at other rows for the same
-- INPUT_ID, which a CHECK constraint can't do. Only fires on the VERSION = 0 row being
-- inserted (the retire-UPDATE in step 1 of a correction touches the *other* row, not this
-- one, and isn't a reason-bearing event itself).
CREATE OR REPLACE FUNCTION check_input_anchor_reason() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM input_anchor WHERE input_id = NEW.input_id) THEN
        -- a prior (now-retired) row already exists -- this is a correction, must explain itself
        IF NEW.correction_operation IS NULL OR NEW.reason IS NULL THEN
            RAISE EXCEPTION 'input_anchor: correction_operation and reason are required when correcting an existing belief (input_id=%)', NEW.input_id;
        END IF;
    ELSE
        -- nothing to correct yet -- this is the first belief, nothing to explain
        IF NEW.correction_operation IS NOT NULL OR NEW.reason IS NOT NULL THEN
            RAISE EXCEPTION 'input_anchor: correction_operation and reason must be NULL for the first belief (input_id=%)', NEW.input_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER input_anchor_check_reason
    BEFORE INSERT ON input_anchor
    FOR EACH ROW WHEN (NEW.version = 0)
    EXECUTE FUNCTION check_input_anchor_reason();

-- Current-row lookup by INPUT_ID needs no index at all -- (0, input_id) is a direct PK hit.
-- The other direction ("which inputs currently point at anchor Y" -- ANCHOR_STATUS_
-- CORRECTION's/legacy's ENTITY_INGESTION_SOURCE's job, generalized) does need one: a partial
-- index scoped to just the current rows, small and cheap, since retired rows (VERSION > 0)
-- are never relevant to "what's true right now."
CREATE INDEX input_anchor_current_by_anchor_idx ON input_anchor (anchor_id) WHERE version = 0;

-- ============================================================================================
-- Correction
-- ============================================================================================

-- Manual, human-initiated overrides -- grouped by *what kind of thing* they fix, not by which
-- cluster that thing happens to live in. Two siblings so far:
--   - ANCHOR_STATUS_CORRECTION (below): pure ANCHOR.status flips, no remapping involved.
--   - RICH_DATA_CORRECTION (elsewhere): a direct value-level fix to one fact row.
-- Remapping corrections are deliberately NOT a third member of this cluster -- see
-- INPUT_ANCHOR above, which already carries its own correction reason on the row it corrects,
-- no separate table needed for that case.
--
-- Modeled on legacy's RESOLUTION_CORRECTION, now narrowed to just the operations that don't
-- touch INPUT_ANCHOR at all: MARK_AS_TEST/MANUALLY_DELETE/MARK_AS_ACTIVE are pure ANCHOR
-- status changes (e.g. "this turned out to be test data, hide it") with no input-to-anchor
-- remapping involved -- there's no before/after anchor pair to record, just ANCHOR_ID itself
-- and what happened to it. CORRECTION_OPERATION/REASON stay free TEXT, matching the rest of
-- this file's ops-defined vocabulary columns. CORRECTED_BY/CORRECTED_AT, not
-- RECORDED_BY/RECORDED_AT -- kept distinct from every other table's creation-event columns,
-- same distinction legacy draws, to keep "this fact was first written" and "this fact was
-- later corrected" visually distinct at a glance.
--
-- INPUT_ID, not INGESTION_SOURCE_ID -- same fix as RICH_DATA_CORRECTION below: every write in
-- this file traces to an INPUT, never directly to an INGESTION_SOURCE (that's always one hop
-- further up, via INPUT.ingestion_source_id). Nullable, matching legacy (not every status
-- correction is tied to a specific input -- e.g. an ops action taken on an anchor as a whole,
-- with no single input driving it).
CREATE TABLE anchor_status_correction (
    correction_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    anchor_type ANCHOR_TYPE NOT NULL,
    anchor_id UUID NOT NULL,
    input_id UUID REFERENCES input (input_id),
    correction_operation TEXT NOT NULL,
    reason TEXT NOT NULL,
    reason_comment TEXT,
    corrected_by TEXT,
    corrected_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    FOREIGN KEY (anchor_id, anchor_type) REFERENCES anchor (anchor_id, type)
);
CREATE INDEX anchor_status_correction_anchor_idx ON anchor_status_correction (anchor_type, anchor_id);

-- A direct, surgical fix to the *value* of one specific fact row -- a typo in a name, a
-- mis-keyed identifier -- not a remapping (that's INPUT_ANCHOR's job) and not a status change
-- (that's ANCHOR_STATUS_CORRECTION's job, above). Modeled on legacy's RICH_DATA_CORRECTION,
-- generalized here to cover both of this file's facts instead of just ENTITY_ATTRIBUTE.
--
-- FACT_TYPE ('entity_name'/'entity_identifier') says which fact table was touched; FACT_KEY
-- says which slot within it (a NAME_TYPE or IDENTIFIER_TYPE value) -- an anchor can have many
-- rows of the same FACT_TYPE, so FACT_TYPE alone doesn't pin down which one. Free TEXT, not
-- enums, same convention as this file's other ops-defined vocabulary columns -- expected to
-- grow as more facts get added.
--
-- ORIGINAL_ROW_ID/CORRECTING_ROW_ID deliberately have no FK. Which table they point into
-- (ENTITY_NAME.name_id vs ENTITY_IDENTIFIER.identifier_id) depends on FACT_TYPE, a real FK
-- can't express "points into one of several tables depending on another column" -- legacy has
-- the same gap, not a new weakness introduced here. OLD_VALUE/NEW_VALUE are full JSONB
-- snapshots of the row's values, which is what actually keeps this safe: the correction stays
-- legible even if ORIGINAL_ROW_ID's row is later deleted outright and the id reused by
-- nothing else.
--
-- CORRECTION_OPERATION is 'update' or 'delete' -- an update is modeled the same way every
-- other fact correction in this file is (close/replace, not edit-in-place): the old row gets
-- removed, a brand new row (CORRECTING_ROW_ID) gets written with the corrected values, and
-- both the before and after are captured here. The two CHECKs tie CORRECTING_ROW_ID/NEW_VALUE
-- to 'update' specifically, so a 'delete' can't accidentally carry a dangling "new" value and
-- an 'update' can't accidentally omit one -- same self-documenting-constraint approach as
-- INPUT_ANCHOR's version/correction-reason check above.
--
-- CORRECTED_BY is NOT NULL here, unlike ANCHOR_STATUS_CORRECTION's nullable one -- matching
-- legacy exactly: a rich-data correction requires a real human identity, a resolution-side
-- correction doesn't.
--
-- INPUT_ID, not INGESTION_SOURCE_ID -- a correction is a write, same as everything else in
-- this file, so it goes through the same front door: a real INPUT row (SOURCE_TYPE = MANUAL,
-- PIPE_TYPE = AD_HOC) carries the correction's payload, and this points at it. This also
-- means the new ENTITY_NAME/ENTITY_IDENTIFIER row this correction writes (CORRECTING_ROW_ID)
-- gets a real, non-null INPUT_ID of its own -- no special-cased NULL, unlike legacy's
-- RICH_DATA_CORRECTION, which has to write its corrected ENTITY_ATTRIBUTE row with
-- input_id=None since it has nothing better to point to. A real INPUT_ID here also means
-- CHAIN_GROUP_KEY propagates to that row through the ordinary `set_chain_columns` trigger,
-- same path every other fact table's write already goes through -- no bespoke plumbing
-- needed just for corrections. INGESTION_SOURCE_ID itself is never stored directly, same as
-- every other table here once INPUT_ID is present -- it's always one hop away via
-- INPUT.ingestion_source_id.
--
-- ANCHOR_ID/ANCHOR_TYPE still stay as their own explicit columns, though, unlike the normal
-- resolution path -- the one deliberate asymmetry worth calling out here. A correction's
-- whole point is that ops already knows which anchor is right, so it bypasses
-- INPUT_RESOLUTION_ATTEMPT/INPUT_ANCHOR entirely: no re-resolution happens, no new belief
-- version gets written, the anchor itself never changes -- only a fact's value does.
-- INPUT_ID grounds the write, ANCHOR_ID says where it goes -- same division of labor as
-- everywhere else in this file.
CREATE TABLE rich_data_correction (
    correction_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    anchor_type ANCHOR_TYPE NOT NULL,
    anchor_id UUID NOT NULL,
    fact_type TEXT NOT NULL,
    fact_key TEXT NOT NULL,
    original_row_id UUID NOT NULL,
    input_id UUID NOT NULL REFERENCES input (input_id),
    old_value JSONB NOT NULL,
    correcting_row_id UUID,
    new_value JSONB,
    correction_operation TEXT NOT NULL,
    reason TEXT NOT NULL,
    reason_comment TEXT,
    corrected_by TEXT NOT NULL,
    corrected_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    FOREIGN KEY (anchor_id, anchor_type) REFERENCES anchor (anchor_id, type),
    CHECK ((correction_operation = 'update') = (correcting_row_id IS NOT NULL)),
    CHECK ((correction_operation = 'update') = (new_value IS NOT NULL))
);
CREATE INDEX rich_data_correction_anchor_idx ON rich_data_correction (anchor_type, anchor_id, fact_type);

-- ============================================================================================
-- Entity
-- ============================================================================================

-- Deliberately a real, directly-queryable table -- analysts and BI tools need `SELECT * FROM
-- entity WHERE entity_id = ...` to work today, not after a materialized view gets built.
CREATE TABLE entity (
    entity_id UUID NOT NULL PRIMARY KEY,
    anchor_type ANCHOR_TYPE NOT NULL DEFAULT 'ENTITY' CHECK (anchor_type = 'ENTITY'),
    status RECORD_STATUS NOT NULL DEFAULT 'ACTIVE',
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    FOREIGN KEY (entity_id, anchor_type) REFERENCES anchor (anchor_id, type)
);

-- A resolution correction on INPUT_ANCHOR (see above) never touches these rows by setting
-- VALID_TO -- it hard-deletes them instead, for a specific reason: VALID_TO means "this was
-- true, until it wasn't" -- ordinary temporal supersession. A resolution correction is saying
-- something else entirely: this row was never true for this ENTITY_ID at all, the resolver
-- just got it wrong from the start. There's no date on which it "stopped" being true, so
-- closing it with VALID_TO would be recording a fact that never happened. Deleting it outright
-- is the honest move -- and since deleting a row from the middle of a (ENTITY_ID, NAME_TYPE,
-- CHAIN_GROUP_KEY) temporal chain can leave a gap, the surviving rows in that same slot (if
-- any, from other inputs under the same writer) get their own VALID_FROM/VALID_TO recomputed
-- first, so the remaining chain still connects cleanly.
--
-- None of this loses the correction's history, though -- it isn't entity_name's job to keep
-- it. INPUT_ANCHOR already holds the full versioned belief history (including the WRONG
-- entity_id this input used to point to, and why it was corrected) -- that's where "what
-- happened and why" lives. ENTITY_NAME/ENTITY_IDENTIFIER only ever need to answer "what's
-- currently true," never "what used to be (wrongly) believed."
CREATE TABLE entity_name (
    name_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    entity_id UUID NOT NULL REFERENCES entity (entity_id),
    name CITEXT NOT NULL,
    name_type TEXT NOT NULL,
    valid_from DATE NOT NULL,
    valid_to DATE,
    input_id UUID NOT NULL REFERENCES input (input_id),
    chain_group_key UUID NOT NULL,
    provenance_id UUID REFERENCES provenance (provenance_id),
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE TRIGGER entity_name_set_chain_columns
    BEFORE INSERT OR UPDATE OF input_id ON entity_name
    FOR EACH ROW EXECUTE FUNCTION set_chain_columns();
-- One open row per (entity, name_type, writer) -- the actual fix: two different writers (two
-- orgs, or an org vs. a licensed source) sharing the same source_type still get two
-- independent slots, because their chain_group_key values differ structurally -- never one.
CREATE UNIQUE INDEX entity_name_open_slot_idx ON entity_name (entity_id, name_type, chain_group_key)
    WHERE valid_to IS NULL;
CREATE INDEX entity_name_trgm_idx ON entity_name USING gin (upper(name::text) gin_trgm_ops);
CREATE INDEX entity_name_embedding_hnsw_idx ON entity_name USING hnsw (embedding vector_cosine_ops);

-- Same hard-delete-on-correction behavior as ENTITY_NAME above (see that table's comment) --
-- a resolution correction removes the wrong row outright, never VALID_TO, with the same
-- temporal-chain repair for any surviving rows in the affected (ENTITY_ID, IDENTIFIER_TYPE,
-- CHAIN_GROUP_KEY) slot.
CREATE TABLE entity_identifier (
    identifier_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    entity_id UUID NOT NULL REFERENCES entity (entity_id),
    identifier CITEXT NOT NULL,
    identifier_type TEXT NOT NULL,
    valid_from DATE NOT NULL,
    valid_to DATE,
    input_id UUID NOT NULL REFERENCES input (input_id),
    chain_group_key UUID NOT NULL,
    provenance_id UUID REFERENCES provenance (provenance_id),
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);
CREATE TRIGGER entity_identifier_set_chain_columns
    BEFORE INSERT OR UPDATE OF input_id ON entity_identifier
    FOR EACH ROW EXECUTE FUNCTION set_chain_columns();
CREATE UNIQUE INDEX entity_identifier_open_slot_idx
    ON entity_identifier (entity_id, identifier_type, chain_group_key)
    WHERE valid_to IS NULL;
CREATE INDEX entity_identifier_lookup_idx ON entity_identifier (identifier_type, identifier);

-- Two candidate-matching aids for the resolver, restored to match legacy's real shape:
-- ENTITY_FUZZY_MATCH/ENTITY_EMBEDDING, kept here in the Entity section (not up in Resolution
-- with everything else) since they're keyed directly by ENTITY_ID, plain FK, no cross-type
-- genericity -- this file doesn't model INSTRUMENT facts, so there's no INSTRUMENT_FUZZY_
-- MATCH/INSTRUMENT_EMBEDDING counterpart to share a generic shape with here (legacy itself
-- keeps those two pairs as four separate tables, never one shared one).
--
-- Neither is a domain fact, and neither carries INPUT_ID or its own lineage -- they're a
-- pure derived SEARCH CACHE of ENTITY_NAME, nothing more. Maintained by application code the
-- same way legacy's `entity_name_store.py` does it: write ENTITY_NAME, then write
-- ENTITY_FUZZY_MATCH/ENTITY_EMBEDDING, same transaction -- not a DB trigger, matching legacy
-- exactly. Confirmed from legacy: rows are never pruned even after ENTITY_NAME supersedes a
-- name (valid_to set) -- this is a deliberately growing superset of every name variant ever
-- attributed to the entity, kept for matching recall. The real lineage for a name (who wrote
-- it, from which input, under what provenance) already lives on ENTITY_NAME -- this cache
-- doesn't need its own, because it's not a source of truth in its own right.
--
-- Fuzzy text matching -- column names kept exactly as legacy's ENTITY_FUZZY_MATCH had them
-- (NAME/NAME_SORTED). NAME is whatever name variant has ever been attributed to this entity.
-- Two techniques:
--   - trigram similarity on NAME, for fast candidate retrieval (`entity_fuzzy_match_trgm_idx`)
--   - NAME_SORTED: NAME uppercased, stripped of punctuation, split into words, words sorted
--     and concatenated (e.g. "Smith John Corp" and "John Smith Corp" both normalize to the
--     same value) -- used for word-order-insensitive Levenshtein-distance scoring. A
--     generated column, computed deterministically from NAME, never set directly.
-- Soundex (legacy's third technique on this table) is deliberately NOT ported -- cruder than
-- embedding similarity and trigram/Levenshtein together already cover, and dropping it avoids
-- needing the fuzzystrmatch extension.
CREATE OR REPLACE FUNCTION sort_name_words(value TEXT) RETURNS TEXT AS $$
    SELECT COALESCE(string_agg(word, '' ORDER BY word), '')
    FROM unnest(string_to_array(regexp_replace(upper(value), '[^A-Z0-9 ]', '', 'g'), ' ')) AS word
    WHERE word <> '';
$$ LANGUAGE sql IMMUTABLE;

CREATE TABLE entity_fuzzy_match (
    fuzzy_match_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    entity_id UUID NOT NULL REFERENCES entity (entity_id),
    name CITEXT NOT NULL,
    name_sorted TEXT GENERATED ALWAYS AS (sort_name_words(name)) STORED,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    UNIQUE (entity_id, name)
);
CREATE INDEX entity_fuzzy_match_trgm_idx ON entity_fuzzy_match USING gin (upper(name::text) gin_trgm_ops);

-- Vector embedding matching -- a separate mechanism from fuzzy text matching above, not a
-- duplicate of it. EMBEDDING_TYPE is free text, not an enum (legacy's EmbeddingType currently
-- has exactly one value, NAME, but is clearly meant to grow). SOURCE_TEXT is the raw text the
-- embedding was computed from, kept alongside the vector for auditability/replay. IS_ACTIVE
-- lets an embedding be superseded (e.g. after a model upgrade) without deleting the row.
CREATE TABLE entity_embedding (
    embedding_id UUID NOT NULL PRIMARY KEY DEFAULT uuidv7(),
    entity_id UUID NOT NULL REFERENCES entity (entity_id),
    embedding_type TEXT NOT NULL,
    source_text TEXT NOT NULL,
    as_of DATE NOT NULL,
    embedding_model TEXT NOT NULL,
    embedding VECTOR(1536) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    recorded_at TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),

    UNIQUE (entity_id, source_text, embedding_model)
);
CREATE INDEX entity_embedding_active_idx ON entity_embedding (entity_id, embedding_type, is_active);
CREATE INDEX entity_embedding_hnsw_idx ON entity_embedding USING hnsw (embedding vector_cosine_ops);

-- Second (and last) hop of the retroactive cascade started by
-- `cascade_ingestion_source_chain_group_key` above: once an INPUT's chain_group_key has been pushed to
-- the corrected value, push it one more hop down to every fact-table row written under that
-- INPUT. In the full schema.sql this function lists every fact table explicitly (nine, as of
-- writing) -- here, scoped to this file's two fact tables, ENTITY_NAME and
-- ENTITY_IDENTIFIER, so the pattern is easy to read with more than one table but still small.
-- Same safety property either way: if correcting chain_group_key would collide an open row
-- with another row that already legitimately holds that (entity, slot, chain_group_key)
-- combination, Postgres raises a constraint violation and the whole correction is rolled
-- back.
CREATE OR REPLACE FUNCTION cascade_input_chain_group_key() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.chain_group_key IS DISTINCT FROM OLD.chain_group_key THEN
        UPDATE entity_name SET chain_group_key = NEW.chain_group_key
         WHERE input_id = NEW.input_id AND chain_group_key IS DISTINCT FROM NEW.chain_group_key;
        UPDATE entity_identifier SET chain_group_key = NEW.chain_group_key
         WHERE input_id = NEW.input_id AND chain_group_key IS DISTINCT FROM NEW.chain_group_key;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER input_cascade_chain_group_key
    AFTER UPDATE ON input
    FOR EACH ROW EXECUTE FUNCTION cascade_input_chain_group_key();
