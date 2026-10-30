-- =============================================================================
-- Delete all data belonging to the SYSTEM_MIGRATION ingestion source
-- (currently: 11 ingestion_source rows, group_key = 'security_master',
--  org_id = 2346b7f2-b69f-40bb-a53c-d8447008fe42)
--
-- Scope confirmed live in atlas_prod on 2024-xx-xx:
--   ingestion_source rows   : 11  (source_type = 'SYSTEM_MIGRATION')
--   entity_ingestion_source : 107 rows -> 107 distinct entities touched
--       - 54 of those entities also have links from OTHER sources (keep)
--       - up to 53 become orphan (no other source claims them) -> delete
--   instrument_ingestion_source : 26 rows -> 26 distinct instruments touched
--       - 0 of those instruments have links from any other source
--         -> all 26 become orphan -> delete
--   position_ingestion_source   : 0 rows (no positions touched)
--
-- Why this isn't a single `DELETE FROM ingestion_source ...`:
--   1. ingestion_source is referenced with ON DELETE RESTRICT (not CASCADE)
--      from resolution_staging / resolution_input_snapshot /
--      resolution_input_target / resolution_correction -- these audit/
--      replay tables must be cleared first or the delete will fail with a
--      FK violation.
--   2. entity/instrument/position rows are NOT FK'd *to* ingestion_source
--      (the relationship is the other way, via *_ingestion_source join
--      tables), so deleting the ingestion_source rows cascades away every
--      fact and the join rows themselves, but leaves the bare entity/
--      instrument/position anchor rows behind even when they now have
--      zero remaining sources. Those orphans need an explicit follow-up
--      delete, which itself DOES cascade (entity -> instrument -> position
--      -> everything else) once we're sure no other source still claims
--      them.
--
-- Run the whole thing in one transaction so either all of it lands or none
-- of it does. The verification SELECTs at top/bottom are there so you can
-- sanity check row counts without re-running the hairy CTEs by hand.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Snapshot scope into temp tables (so we don't recompute "affected"
--    sets after we've already started deleting rows out from under them).
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _mig_sources AS
SELECT ingestion_source_id
FROM ingestion_source
WHERE source_type = 'SYSTEM_MIGRATION';

CREATE TEMP TABLE _mig_entities AS
SELECT DISTINCT entity_id
FROM entity_ingestion_source
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

CREATE TEMP TABLE _mig_instruments AS
SELECT DISTINCT instrument_id
FROM instrument_ingestion_source
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

CREATE TEMP TABLE _mig_positions AS
SELECT DISTINCT position_id
FROM position_ingestion_source
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

-- Pre-delete sanity check -- compare against the counts in the header
-- comment above before going any further.
SELECT
  (SELECT count(*) FROM _mig_sources)    AS n_ingestion_sources,
  (SELECT count(*) FROM _mig_entities)   AS n_entities_touched,
  (SELECT count(*) FROM _mig_instruments) AS n_instruments_touched,
  (SELECT count(*) FROM _mig_positions)   AS n_positions_touched;

-- ---------------------------------------------------------------------------
-- 1. Clear the RESTRICT-FK audit/replay tables for these sources first --
--    they block DELETE FROM ingestion_source otherwise.
-- ---------------------------------------------------------------------------

DELETE FROM resolution_staging
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

DELETE FROM resolution_input_target
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

DELETE FROM resolution_input_snapshot
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

DELETE FROM resolution_correction
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

-- ---------------------------------------------------------------------------
-- 2. Delete the ingestion_source rows themselves. This cascades (via
--    ON DELETE CASCADE) through: entity_ingestion_source,
--    instrument_ingestion_source, position_ingestion_source,
--    entity_attribute, entity_name, entity_type, entity_identifier,
--    entity_relationship, entity_strategy, entity_operational_phase,
--    instrument_attribute, instrument_fee(+fee_attribute),
--    instrument_coupon(+coupon_attribute), instrument_identifier,
--    instrument_name, instrument_type, analytics, valuation,
--    operating_cash_flow, position_attribute, silver_identifier, tag,
--    tag_definition, contact, attachment_version, benchmark_percentile,
--    benchmark_return_index -- i.e. every fact this source ever claimed.
--
--    It does NOT delete the entity/instrument/position anchor rows
--    themselves -- that's handled explicitly below, only for the ones
--    that are now orphaned.
-- ---------------------------------------------------------------------------

DELETE FROM ingestion_source
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _mig_sources);

-- ---------------------------------------------------------------------------
-- 3. Delete orphaned instruments first (no remaining
--    instrument_ingestion_source row from ANY source). This cascades to
--    that instrument's positions, attributes, fees, coupons, identifiers,
--    names, types, analytics, valuations, tags, attachments, etc.
--
--    Must run before the entity orphan check in step 4, so an entity that
--    still owns a *kept* instrument (one with a surviving link from some
--    other source) is correctly seen as "not orphan" there.
-- ---------------------------------------------------------------------------

DELETE FROM instrument i
WHERE i.instrument_id IN (SELECT instrument_id FROM _mig_instruments)
  AND NOT EXISTS (
    SELECT 1 FROM instrument_ingestion_source iis
    WHERE iis.instrument_id = i.instrument_id
  );

-- ---------------------------------------------------------------------------
-- 4. Delete orphaned entities (no remaining entity_ingestion_source row
--    from ANY source, AND no remaining instrument under them -- the
--    latter guards against deleting an entity that still has a live
--    instrument from another source, which would otherwise cascade that
--    instrument away too). Cascades to that entity's remaining
--    attributes, names, types, identifiers, relationships, strategies,
--    operational phases, analytics, valuations, tags, attachments,
--    positions it holds, etc.
-- ---------------------------------------------------------------------------

DELETE FROM entity e
WHERE e.entity_id IN (SELECT entity_id FROM _mig_entities)
  AND NOT EXISTS (
    SELECT 1 FROM entity_ingestion_source eis
    WHERE eis.entity_id = e.entity_id
  )
  AND NOT EXISTS (
    SELECT 1 FROM instrument i
    WHERE i.entity_id = e.entity_id
  );

-- ---------------------------------------------------------------------------
-- 5. Post-delete verification -- all four should read 0.
-- ---------------------------------------------------------------------------

SELECT
  (SELECT count(*) FROM ingestion_source WHERE source_type = 'SYSTEM_MIGRATION') AS remaining_mig_sources,
  (SELECT count(*) FROM entity e WHERE e.entity_id IN (SELECT entity_id FROM _mig_entities)
     AND NOT EXISTS (SELECT 1 FROM entity_ingestion_source eis WHERE eis.entity_id = e.entity_id)
     AND NOT EXISTS (SELECT 1 FROM instrument i WHERE i.entity_id = e.entity_id)
  ) AS remaining_orphan_entities,
  (SELECT count(*) FROM instrument i WHERE i.instrument_id IN (SELECT instrument_id FROM _mig_instruments)
     AND NOT EXISTS (SELECT 1 FROM instrument_ingestion_source iis WHERE iis.instrument_id = i.instrument_id)
  ) AS remaining_orphan_instruments;

-- Review the two SELECT outputs above.
-- If everything looks right:      COMMIT;
-- If anything looks off:           ROLLBACK;
