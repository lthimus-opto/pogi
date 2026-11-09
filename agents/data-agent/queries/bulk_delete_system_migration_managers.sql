-- Bulk delete: for a list of Security Master manager_id values (= the
-- silver_id on each manager's Atlas entity), delete every SYSTEM_MIGRATION
-- ingestion_source that ever touched that manager's batch (manager + its
-- bundled funds/instruments), then sweep away any now-fully-orphaned bare
-- entity/instrument anchor rows. Only the manager_id needs to be supplied --
-- everything else (Atlas entity_id, ingestion_source_id(s), the funds and
-- instruments bundled in those same batches) is resolved live, every run.
--
-- Does NOT touch any other source's claim on these same entities (e.g.
-- SEC_ADV) -- only ingestion_source rows with source_type = 'SYSTEM_MIGRATION'
-- are ever deleted here. A manager/fund that also exists via SEC_ADV will
-- survive this delete (with that source's facts only) and reload will
-- re-attach to the SAME entity_id via EXACT_SILVER_IDENTIFIER_MATCH -- a
-- manager that was SYSTEM_MIGRATION-only will be fully removed and get a
-- NEW entity_id on reload. The post-checks below tell you which happened
-- for each manager, so you know which ones changed identity.

BEGIN;

-- ============================================================
-- EDIT THIS: the Security Master manager_id values to process.
-- ============================================================
CREATE TEMP TABLE _target_manager_silver_ids (silver_id citext PRIMARY KEY);
INSERT INTO _target_manager_silver_ids (silver_id) VALUES
  ('df62f520-b081-468e-8059-0a8c6e902d1d'),  -- 424 Capital
  ('5f4753f8-164b-46c9-9029-ad5cdcb0f93a'),  -- AE Industrial Partners
  ('2c21d266-a383-463e-9df7-db8cccc61e97'),  -- AEA Investors
  ('1b70bf5f-f5c0-48c9-b991-299cf389182b'),  -- Agility Equity Partners
  ('eec3cbf4-7159-4075-ba8c-87657300c1a4'),  -- Allied Industrial Partners
  ('f12eb169-8006-4a58-a802-ec7367dfd67d'),  -- Altas Partners
  ('7f4a7fcc-207a-47a7-8891-7a6d4a4d3c8e'),  -- Aphias Capital
  ('26aa7ab0-b3e5-4286-a65c-3c00fb14052e'),  -- Architect Equity
  ('f98939cd-46f3-48c4-8384-f76ae00073bd'),  -- BAM Corner Point
  ('18bad7bc-8ff5-4e23-ae66-8fb0b6fd2136'),  -- Banner Ridge Partners
  ('d09f9658-eee6-45c9-995c-7f7ca8f34e3b'),  -- BayHawk Capital
  ('118b5969-afc3-4f18-86b6-4fc9895003b0'),  -- Bear Creek Asset Management LLC
  ('67cc7615-e703-4529-a53c-5975ad363f32'),  -- Blumberg Capital
  ('42d10d37-06a8-424a-a657-9a7d1dfd1614'),  -- Brenton Point Capital Partners
  ('57be1beb-d291-4ded-b643-6e9965c1dfdd'),  -- Broadwing Capital
  ('a62d9d77-c055-4052-83d7-3d0976e9eeda'),  -- Carr's Hill Partners
  ('eb213c9e-6ef5-4725-91c9-ccc0f62cc529'),  -- Crosstown Capital Partners
  ('caa29ad6-1e02-4843-aa86-4122c5f9e07e'),  -- Cypress Ridge
  ('0529d493-92a0-441f-922a-ee5902ca7438'),  -- DalFort Capital
  ('ea28345c-daf7-446f-aa22-f46b86869b2a'),  -- Diversis Capital
  ('b2cd86ea-5b4d-44e6-9b7c-5e349d7e003b'),  -- Eagle Merchant Partners
  ('0fce2080-8414-4d5c-b9bb-9e8b780d0ea1'),  -- EagleTree Capital
  ('0aec44b8-f035-4d13-937c-ede65a44bed8'),  -- Equality Asset Management (EAM)
  ('005003ce-a3ee-459a-9d44-b5978e8dbdb8'),  -- FUSE
  ('50e41091-7b1b-4591-83eb-bc94262ea20d'),  -- Foundation Investment Partners
  ('2298a894-911f-47a5-aea7-3cbccdeafbdb'),  -- Full In
  ('b64ccc0e-1ee8-49b7-ac01-5b77ad234248'),  -- Grove Mountain Partners
  ('1dcaa1a8-5260-4122-b070-4e20824e37c5'),  -- Harkness Capital Partners
  ('b7af61a9-4ce7-4ad1-af0d-df4c8d0bfedb'),  -- Integrity Growth Partners
  ('82c2afd3-73c3-4dc1-be70-89e5c2967707'),  -- Interplay Ventures
  ('2447cde5-9671-4972-9c8a-6a9f861c4184'),  -- K1 Investment Management, LLC
  ('f910f36e-d025-44f6-9334-25f11cf99fd2'),  -- KSD Capital
  ('9ce00a19-a40d-42fa-9bad-4f82af6e04ae'),  -- Lone Star Funds
  ('5b958e1a-de8b-4445-86af-f949eb72adfc'),  -- Lone View Capital
  ('691e7b69-25bc-4ffc-960c-8171ac576acf'),  -- Luminate Capital Partners
  ('ebc6b7e7-e4f9-40f9-8cfa-58b3c836228e'),  -- NMS Capital
  ('c74e6156-e4b7-44bf-b068-033bc4511d49'),  -- New State Capital Partners
  ('9ee5b19f-6b3e-4892-ac93-996297d24b15'),  -- New Vintage Partners
  ('4a7fa7f1-4b70-4a7b-aa34-2cde05b58645'),  -- Nexus Capital Management
  ('8d9bf835-aeaa-4836-9429-c6103effbb3a'),  -- NorthSands Capital
  ('ce6610ba-8630-498d-a926-1469d8409dd8'),  -- OMX Ventures
  ('b5b8f1be-7572-4749-b859-a79e1198d7b8'),  -- One Rock Capital Partners
  ('41c5ffe2-aeb8-40fc-9025-90650cadfa15'),  -- Otro Capital
  ('6da38c64-6ce7-4af2-bf36-1c6a6739caa7'),  -- PACE Healthcare Capital
  ('66ecf944-9936-4468-92f6-3272aef74497'),  -- Princeton Equity Group
  ('4e34769e-a4a2-448c-82b9-dcebd14dcfcf'),  -- Quilvest Capital Partners
  ('d7a1edec-f386-4d7b-9889-c32d85c282d6'),  -- Repeat VC
  ('c444b9c1-75e5-4a4f-be7e-c435b76cdee1'),  -- Rising Point Capital Management
  ('f85031c0-a6a2-4dca-a707-429ac7a27780'),  -- Riverspan Partners
  ('6f6a7d03-5020-48bb-b676-cff62fd4d96f'),  -- Rockbridge
  ('3dd5219a-6921-454c-8127-68278c42d490'),  -- SEVEST Management
  ('1ec5b4a6-ca44-4103-8020-b7f2dd0b258c'),  -- Saw Mill Capital
  ('9b7c1c0c-3093-4aa0-b38d-a0feb8255539'),  -- Software Growth Partners
  ('ba32e010-a635-4c4b-8c34-490d102936b4'),  -- TRM Equity
  ('ac783310-97af-4847-94ad-a336d656fa11'),  -- Terminus Capital Partners
  ('afd9c8ad-a5f0-45bf-9886-91c965b23e64'),  -- TerraMar Capital
  ('6099b417-26e6-4842-9780-105081c6511e'),  -- Thayer Street Partners
  ('e6f7fb40-31a9-41c3-bb85-0562cf7e3206'),  -- The Carlyle Group
  ('805ba7f1-d945-413c-ad43-4c3a2bd4ca07'),  -- Trive Capital
  ('db682a22-f4c8-4ddf-a4b3-36eb7a5f26af'),  -- Turnspire Capital Partners
  ('05252864-4d0e-4599-ad5e-4324669f6a15'),  -- Two Roads Partners
  ('48f9c4cc-7222-4cef-bbd3-43b0a68e60da'),  -- Valspring Capital
  ('dbf886e9-f730-46d4-b332-f46fb22923a7'),  -- WayPoint Capital Partners
  ('11e7ba85-6189-4f55-8a01-64b553c9a6a2');  -- Zero Prime
-- ============================================================

-- Resolve manager silver_ids -> their current Atlas entity_id (if loaded at all).
-- Explicit ::citext cast on the join -- confirmed via live testing that an
-- untyped literal compared against silver_identifier.silver_id (citext) can
-- silently fail to match without it; the temp table's declared column type
-- already protects this specific query, but the cast is kept for defense in
-- depth given how easy that failure mode is to reintroduce by accident.
CREATE TEMP TABLE _target_manager_entities AS
SELECT t.silver_id, si.entity_id
FROM _target_manager_silver_ids t
LEFT JOIN silver_identifier si
  ON si.silver_id = t.silver_id::citext
  AND si.ingestion_source_group_key = 'security_master'
  AND si.scoped_to = 'ENTITY';

\echo '=== pre-check: manager_id -> resolved entity_id (NULL = never loaded, nothing to do for that one) ==='
SELECT * FROM _target_manager_entities ORDER BY silver_id;

\echo '=== pre-check: how many of the requested managers resolved vs not (sanity -- confirm the NULLs above are expected, not a typo/regression) ==='
SELECT count(*) AS managers_given, count(entity_id) AS resolved_to_entity, count(*) - count(entity_id) AS unresolved
FROM _target_manager_entities;

-- Every SYSTEM_MIGRATION ingestion_source that ever touched one of these
-- manager entities (this is the whole batch -- manager + bundled funds).
CREATE TEMP TABLE _target_sources AS
SELECT DISTINCT eis.ingestion_source_id
FROM entity_ingestion_source eis
JOIN ingestion_source s ON s.ingestion_source_id = eis.ingestion_source_id
WHERE eis.entity_id IN (SELECT entity_id FROM _target_manager_entities WHERE entity_id IS NOT NULL)
  AND s.source_type = 'SYSTEM_MIGRATION';

\echo '=== pre-check: resolved ingestion_source batches to be deleted ==='
SELECT * FROM _target_sources;

-- Full affected set: every entity/instrument ever linked to those sources --
-- this is what the post-checks verify against, not just the managers.
CREATE TEMP TABLE _affected_entities AS
SELECT DISTINCT entity_id FROM entity_ingestion_source
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);

CREATE TEMP TABLE _affected_instruments AS
SELECT DISTINCT instrument_id FROM instrument_ingestion_source
WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);

\echo '=== pre-check: every entity in scope, with name + whether other sources also claim it ==='
SELECT ae.entity_id,
       (SELECT array_agg(DISTINCT name) FROM entity_name en WHERE en.entity_id = ae.entity_id AND en.valid_to IS NULL) AS names,
       (SELECT array_agg(DISTINCT s.source_type) FROM entity_ingestion_source eis2
          JOIN ingestion_source s ON s.ingestion_source_id = eis2.ingestion_source_id
          WHERE eis2.entity_id = ae.entity_id) AS all_claiming_sources
FROM _affected_entities ae
ORDER BY 1;

\echo '=== pre-check: every instrument in scope ==='
SELECT ai.instrument_id,
       (SELECT array_agg(DISTINCT name) FROM instrument_name inm WHERE inm.instrument_id = ai.instrument_id AND inm.valid_to IS NULL) AS names
FROM _affected_instruments ai
ORDER BY 1;

-- Clear the RESTRICT-FK audit/replay tables for these sources first (same
-- reason as delete_system_migration_source.sql: these block DELETE FROM
-- ingestion_source otherwise).
DELETE FROM resolution_staging WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);
DELETE FROM resolution_input_target WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);
DELETE FROM resolution_input_snapshot WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);
DELETE FROM resolution_correction WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);

-- The actual delete. Cascades through entity_ingestion_source,
-- instrument_ingestion_source, entity_name/type/relationship/attribute/
-- strategy/identifier, instrument_name/type/fee/identifier, analytics,
-- valuation, silver_identifier, tag, etc. for THESE sources only -- does
-- NOT remove the bare entity/instrument anchor row, and does NOT touch
-- any other source's rows on the same entities.
DELETE FROM ingestion_source WHERE ingestion_source_id IN (SELECT ingestion_source_id FROM _target_sources);

-- Orphan sweep -- instruments first (same ordering reason as
-- delete_system_migration_source.sql: an entity that still owns a kept
-- instrument from another source must not be treated as orphaned below).
DELETE FROM instrument i
WHERE i.instrument_id IN (SELECT instrument_id FROM _affected_instruments)
  AND NOT EXISTS (SELECT 1 FROM instrument_ingestion_source iis WHERE iis.instrument_id = i.instrument_id);

DELETE FROM entity e
WHERE e.entity_id IN (SELECT entity_id FROM _affected_entities)
  AND NOT EXISTS (SELECT 1 FROM entity_ingestion_source eis WHERE eis.entity_id = e.entity_id)
  AND NOT EXISTS (SELECT 1 FROM instrument i WHERE i.entity_id = e.entity_id);

-- ============================================================
-- POST-CHECKS -- the actual "no orphan" verification requested.
-- ============================================================

-- ============================================================
-- HARD SAFETY GATE -- automatic, not a human judgment call.
-- If either invariant fails, this RAISEs and aborts the whole transaction
-- before it can ever reach COMMIT below. No orphan/dangling-reference
-- state can ever be committed by this script, full stop.
-- ============================================================
DO $$
DECLARE
  orphaned_entities int;
  orphaned_instruments int;
  dangling_relationships int;
  instruments_missing_issuer int;
  dangling_positions int;
BEGIN
  SELECT count(*) INTO orphaned_entities FROM entity e
    WHERE e.entity_id IN (SELECT entity_id FROM _affected_entities)
      AND NOT EXISTS (SELECT 1 FROM entity_ingestion_source eis WHERE eis.entity_id = e.entity_id);

  SELECT count(*) INTO orphaned_instruments FROM instrument i
    WHERE i.instrument_id IN (SELECT instrument_id FROM _affected_instruments)
      AND NOT EXISTS (SELECT 1 FROM instrument_ingestion_source iis WHERE iis.instrument_id = i.instrument_id);

  SELECT count(*) INTO dangling_relationships FROM entity_relationship er
    WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = er.parent_entity_id)
       OR NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = er.child_entity_id);

  SELECT count(*) INTO instruments_missing_issuer FROM instrument i
    WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = i.entity_id);

  SELECT count(*) INTO dangling_positions FROM "position" p
    WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = p.holder_entity_id)
       OR NOT EXISTS (SELECT 1 FROM instrument i WHERE i.instrument_id = p.held_instrument_id);

  IF orphaned_entities > 0 OR orphaned_instruments > 0
     OR dangling_relationships > 0 OR instruments_missing_issuer > 0 OR dangling_positions > 0 THEN
    RAISE EXCEPTION
      'SAFETY GATE FAILED -- aborting, nothing will be committed. orphaned_entities=%, orphaned_instruments=%, dangling_relationships=%, instruments_missing_issuer=%, dangling_positions=%',
      orphaned_entities, orphaned_instruments, dangling_relationships, instruments_missing_issuer, dangling_positions;
  END IF;
END $$;

\echo '=== post-check 1: literal orphans -- entity/instrument that EXISTS but has ZERO ingestion_source links. Must be 0/0 (the DO block above already hard-fails on this -- this SELECT is just for visibility). ==='
SELECT
  (SELECT count(*) FROM entity e WHERE e.entity_id IN (SELECT entity_id FROM _affected_entities)
     AND NOT EXISTS (SELECT 1 FROM entity_ingestion_source eis WHERE eis.entity_id = e.entity_id)) AS orphaned_entities_remaining,
  (SELECT count(*) FROM instrument i WHERE i.instrument_id IN (SELECT instrument_id FROM _affected_instruments)
     AND NOT EXISTS (SELECT 1 FROM instrument_ingestion_source iis WHERE iis.instrument_id = i.instrument_id)) AS orphaned_instruments_remaining;

\echo '=== post-check 2: dangling cross-references -- relationship/position pointing at a now-missing entity/instrument. Must be 0 everywhere (DB FK cascade should already guarantee this; confirming). ==='
SELECT
  (SELECT count(*) FROM entity_relationship er
     WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = er.parent_entity_id)
        OR NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = er.child_entity_id)) AS dangling_relationships,
  (SELECT count(*) FROM instrument i WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = i.entity_id)) AS instruments_with_missing_issuer,
  (SELECT count(*) FROM "position" p
     WHERE NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = p.holder_entity_id)
        OR NOT EXISTS (SELECT 1 FROM instrument i WHERE i.instrument_id = p.held_instrument_id)) AS dangling_positions;

\echo '=== post-check 3: which managers survived (still present) vs were fully removed -- tells you which keep their entity_id on reload vs will get a new one ==='
SELECT t.silver_id, t.entity_id AS old_entity_id,
       EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = t.entity_id) AS entity_still_present,
       (SELECT array_agg(DISTINCT s.source_type) FROM entity_ingestion_source eis
          JOIN ingestion_source s ON s.ingestion_source_id = eis.ingestion_source_id
          WHERE eis.entity_id = t.entity_id) AS remaining_sources_if_any
FROM _target_manager_entities t
WHERE t.entity_id IS NOT NULL
ORDER BY 1;

\echo '=== post-check 4: surviving entities that are now "thin" -- kept (another source claims them) but lost ALL name/type/relationship facts because those only ever came from the deleted source. Not an error, just worth knowing before reload. ==='
SELECT ae.entity_id
FROM _affected_entities ae
WHERE EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = ae.entity_id)
  AND NOT EXISTS (SELECT 1 FROM entity_name en WHERE en.entity_id = ae.entity_id AND en.valid_to IS NULL);

-- The hard safety gate above has already enforced post-checks 1 and 2 --
-- if you're reading this, the script completed without raising, so this
-- transaction is already safe to commit. Review post-check 3 (which
-- managers will get a NEW entity_id on reload) and post-check 4
-- (informational) before deciding.
-- COMMIT;
-- or, to abandon everything instead:
-- ROLLBACK;
