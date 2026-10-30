-- Fixes the "Pre-Fund Investments" generic-name conflation
-- (knowledge/failure_modes.md: name-collision-driven wrong merge, confirmed
-- instance under entry "Why this matters enough to log" / multi-parent
-- review). Two unrelated managers -- Allied Industrial Partners (AIP) and
-- Diversis Capital -- each had a fund literally named "Pre-Fund
-- Investments" in the source. Atlas's resolution auto-attached the second
-- one onto the first via a 100%-confidence EXACT_NAME_MATCH / DEDUP_IGNORE
-- fast path (no LLM, no manager-level disambiguation), so entity
-- d9c2de94-96be-400a-b239-1ffc7705aaf5 ended up with two conflicting
-- MANAGES parents (AIP and Diversis both).
--
-- Decision: delete ALL sides, not just the stale one(s), so the generic
-- name "Pre-Fund Investments" has no entity left in Atlas to act as a
-- magnet for yet another manager's same-named record later. Upstream, a
-- name-overwrite rule will disambiguate each manager's record before
-- reload (e.g. "AIP Pre-Fund Investments" / "Diversis Pre-Fund
-- Investments" / "NorthSands Pre-Fund Investments"), so the reload
-- creates distinct, correctly-named entities instead of re-colliding.
--
-- UPDATE: a 3rd manager (NorthSands Capital, ingestion_source_id
-- eb718075-adcf-4e5b-9419-090765999db3) collided onto the same entity
-- in a later batch, before this fix was applied -- confirming the exact
-- compounding risk that motivated deleting all sides rather than just
-- the original two. The fix below is unchanged in mechanism (it was
-- already entity-scoped, not source-scoped, so it doesn't care how many
-- parents have piled on) -- only the pre/post-check baseline is extended
-- to cover NorthSands' batch too.
--
-- Scope check already done (see conversation): all three ingestion_source_id
-- batches involved (46c142e3-..., AIP's batch; 95b7f465-..., Diversis's
-- batch; eb718075-..., NorthSands' batch) each contain OTHER
-- correctly-loaded funds too (Allied Industrial Partners I/II, Chronos
-- Fund, Diversis Capital Fund I/II/III, NorthSands Fund I) -- deleting
-- the whole ingestion_source rows would wipe those out as collateral
-- damage. This script deletes only the single conflated ENTITY row
-- (d9c2de94...) -- every FK from `entity` is ON DELETE CASCADE except
-- resolution_staging.input_entity_id (ON DELETE SET NULL, not RESTRICT),
-- confirmed via pg_constraint, so one entity-level DELETE is sufficient
-- and safe -- it will NOT touch AIP's, Diversis's, or NorthSands' other
-- entities, their ingestion_source rows, or any other fund.

BEGIN;

-- Pre-check: full picture of everything currently tied to the conflated entity.
\echo '=== entity row itself ==='
SELECT entity_id FROM entity WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5';

\echo '=== entity_relationship (all conflicting MANAGES edges -- expect 3 now: AIP, Diversis, NorthSands) ==='
SELECT relationship_id, parent_entity_id, child_entity_id, relationship_type, valid_from, input_id, ingestion_source_id
FROM entity_relationship WHERE child_entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5';

\echo '=== entity_name / entity_type ==='
SELECT 'name' AS kind, name AS value, valid_to FROM entity_name WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5'
UNION ALL
SELECT 'type', entity_type::text, valid_to FROM entity_type WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5';

\echo '=== entity_ingestion_source links (should be exactly the 3 batches: AIP + Diversis + NorthSands) ==='
SELECT ingestion_source_id, input_id FROM entity_ingestion_source WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5';

\echo '=== pre-delete sibling-entity counts for all three source batches (baseline to compare against post-check) ==='
SELECT
  (SELECT count(DISTINCT entity_id) FROM entity_ingestion_source WHERE ingestion_source_id = '46c142e3-4a90-4506-93c7-97b4cc114ce1') AS aip_batch_entities_before,
  (SELECT count(DISTINCT entity_id) FROM entity_ingestion_source WHERE ingestion_source_id = '95b7f465-223c-4ba5-b5eb-7797b32edaf4') AS diversis_batch_entities_before,
  (SELECT count(DISTINCT entity_id) FROM entity_ingestion_source WHERE ingestion_source_id = 'eb718075-adcf-4e5b-9419-090765999db3') AS northsands_batch_entities_before;

-- The actual fix: one cascading delete.
DELETE FROM entity WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5';

-- Post-check 1: the entity and everything FK'd to it should be fully gone.
\echo '=== post-check: should all be 0 ==='
SELECT
  (SELECT count(*) FROM entity WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5') AS entity_remaining,
  (SELECT count(*) FROM entity_relationship WHERE child_entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5') AS relationships_remaining,
  (SELECT count(*) FROM entity_name WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5') AS names_remaining,
  (SELECT count(*) FROM entity_ingestion_source WHERE entity_id = 'd9c2de94-96be-400a-b239-1ffc7705aaf5') AS links_remaining;

-- Post-check 2: AIP's, Diversis's, and NorthSands' OTHER entities must be
-- untouched -- each count should be exactly 1 less than the "before"
-- baseline above (Pre-Fund Investments gone, nothing else).
\echo '=== post-check: sibling-entity counts, should each be exactly 1 less than before ==='
SELECT
  (SELECT count(DISTINCT entity_id) FROM entity_ingestion_source WHERE ingestion_source_id = '46c142e3-4a90-4506-93c7-97b4cc114ce1') AS aip_batch_entities_after,
  (SELECT count(DISTINCT entity_id) FROM entity_ingestion_source WHERE ingestion_source_id = '95b7f465-223c-4ba5-b5eb-7797b32edaf4') AS diversis_batch_entities_after,
  (SELECT count(DISTINCT entity_id) FROM entity_ingestion_source WHERE ingestion_source_id = 'eb718075-adcf-4e5b-9419-090765999db3') AS northsands_batch_entities_after;

\echo '=== post-check: confirm AIP, Diversis, and NorthSands managers themselves, and their OTHER funds, are all still present ==='
SELECT eis.ingestion_source_id, eis.entity_id, en.name
FROM entity_ingestion_source eis
LEFT JOIN entity_name en ON en.entity_id = eis.entity_id AND en.valid_to IS NULL
WHERE eis.ingestion_source_id IN ('46c142e3-4a90-4506-93c7-97b4cc114ce1', '95b7f465-223c-4ba5-b5eb-7797b32edaf4', 'eb718075-adcf-4e5b-9419-090765999db3')
ORDER BY eis.ingestion_source_id, en.name;

-- Review every output above:
--   - entity_remaining / relationships_remaining / names_remaining / links_remaining must all be 0
--   - the sibling-entity counts must each have dropped by exactly 1
--   - the final listing must show AIP Management LP, Allied Industrial Partners I/II,
--     Diversis Capital Management, Chronos Fund, Diversis Capital Fund I/II/III,
--     NorthSands Capital, NorthSands Fund I -- everything except "Pre-Fund Investments"
-- If all of that checks out:      COMMIT;
-- If anything looks off:          ROLLBACK;
