-- Deep review of all SYSTEM_MIGRATION ingestion_source data currently live
-- in Atlas: financial-graph solidity, duplicate detection, consistency.
-- Read-only role -> no temp tables; scope is inlined via psql variables.
-- Usage: ./connect.sh .env.atlas.prod -f queries/review_system_migration.sql

\set mig_sources '(SELECT ingestion_source_id FROM ingestion_source WHERE source_type = ''SYSTEM_MIGRATION'')'
\set mig_entities '(SELECT DISTINCT entity_id FROM entity_ingestion_source WHERE ingestion_source_id IN :mig_sources)'
\set mig_instruments '(SELECT DISTINCT instrument_id FROM instrument_ingestion_source WHERE ingestion_source_id IN :mig_sources)'
\set mig_positions '(SELECT DISTINCT position_id FROM position_ingestion_source WHERE ingestion_source_id IN :mig_sources)'

\echo '========== SCOPE =========='
SELECT (SELECT count(*) FROM :mig_sources) AS sources,
       (SELECT count(*) FROM :mig_entities) AS entities,
       (SELECT count(*) FROM :mig_instruments) AS instruments,
       (SELECT count(*) FROM :mig_positions) AS positions,
       (SELECT count(*) FROM entity_relationship WHERE ingestion_source_id IN :mig_sources) AS relationships;

\echo ''
\echo '========== GRAPH SOLIDITY =========='

\echo '--- 1. dangling entity_relationship (parent or child entity missing entirely) ---'
SELECT er.relationship_id, er.parent_entity_id, er.child_entity_id, er.relationship_type
FROM entity_relationship er
WHERE er.ingestion_source_id IN :mig_sources
  AND (NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = er.parent_entity_id)
   OR  NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = er.child_entity_id));

\echo '--- 2. instruments whose issuing entity_id does not exist ---'
SELECT i.instrument_id, i.entity_id
FROM instrument i
WHERE i.instrument_id IN :mig_instruments
  AND NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = i.entity_id);

\echo '--- 3. positions whose holder_entity_id or held_instrument_id does not exist ---'
SELECT p.position_id, p.holder_entity_id, p.held_instrument_id
FROM position p
WHERE p.position_id IN :mig_positions
  AND (NOT EXISTS (SELECT 1 FROM entity e WHERE e.entity_id = p.holder_entity_id)
   OR  NOT EXISTS (SELECT 1 FROM instrument i WHERE i.instrument_id = p.held_instrument_id));

\echo '--- 4. self-referencing relationships (parent = child) ---'
SELECT relationship_id, parent_entity_id, relationship_type
FROM entity_relationship
WHERE ingestion_source_id IN :mig_sources
  AND parent_entity_id = child_entity_id;

\echo '--- 5. relationship cycles: grandchild == original parent within this scope (2-hop check) ---'
SELECT a.parent_entity_id, a.child_entity_id, b.child_entity_id AS grandchild
FROM entity_relationship a
JOIN entity_relationship b ON b.parent_entity_id = a.child_entity_id
WHERE a.ingestion_source_id IN :mig_sources
  AND b.ingestion_source_id IN :mig_sources
  AND b.child_entity_id = a.parent_entity_id;

\echo '--- 6. count of entities touched by this source with ZERO relationship edges at all (isolated nodes) ---'
SELECT count(*) AS isolated_entities
FROM :mig_entities me
WHERE NOT EXISTS (SELECT 1 FROM entity_relationship er WHERE er.parent_entity_id = me.entity_id OR er.child_entity_id = me.entity_id);

\echo '--- 6b. sample of isolated entities with their names/types ---'
SELECT me.entity_id, en.name, et.entity_type
FROM :mig_entities me
LEFT JOIN entity_name en ON en.entity_id = me.entity_id AND en.valid_to IS NULL
LEFT JOIN entity_type et ON et.entity_id = me.entity_id AND et.valid_to IS NULL
WHERE NOT EXISTS (SELECT 1 FROM entity_relationship er WHERE er.parent_entity_id = me.entity_id OR er.child_entity_id = me.entity_id)
LIMIT 30;

\echo '--- 7. instruments whose issuing entity has no parent relationship at all (dangling in the hierarchy) ---'
SELECT i.instrument_id, i.entity_id, en.name AS issuer_name
FROM instrument i
JOIN entity_name en ON en.entity_id = i.entity_id AND en.valid_to IS NULL
WHERE i.instrument_id IN :mig_instruments
  AND NOT EXISTS (SELECT 1 FROM entity_relationship er WHERE er.child_entity_id = i.entity_id);

\echo '--- 8. relationship_type distribution ---'
SELECT relationship_type, COUNT(*) FROM entity_relationship
WHERE ingestion_source_id IN :mig_sources
GROUP BY 1 ORDER BY 2 DESC;

\echo '--- 9. entities with MULTIPLE distinct parents ---'
SELECT er.child_entity_id, COUNT(DISTINCT er.parent_entity_id) AS n_parents, array_agg(DISTINCT er.parent_entity_id) AS parents
FROM entity_relationship er
WHERE er.ingestion_source_id IN :mig_sources
GROUP BY er.child_entity_id
HAVING COUNT(DISTINCT er.parent_entity_id) > 1;

\echo ''
\echo '========== DUPLICATES =========='

\echo '--- 10. entities sharing the exact same current legal_name ---'
SELECT en.name, COUNT(DISTINCT en.entity_id) AS n_entities, array_agg(DISTINCT en.entity_id) AS entity_ids
FROM entity_name en
WHERE en.entity_id IN :mig_entities
  AND en.valid_to IS NULL
GROUP BY en.name
HAVING COUNT(DISTINCT en.entity_id) > 1
ORDER BY n_entities DESC;

\echo '--- 11. instruments sharing the exact same current name under the same issuing entity ---'
SELECT i.entity_id, inm.name, COUNT(DISTINCT i.instrument_id) AS n_instruments, array_agg(DISTINCT i.instrument_id) AS instrument_ids
FROM instrument i
JOIN instrument_name inm ON inm.instrument_id = i.instrument_id AND inm.valid_to IS NULL
WHERE i.instrument_id IN :mig_instruments
GROUP BY i.entity_id, inm.name
HAVING COUNT(DISTINCT i.instrument_id) > 1
ORDER BY n_instruments DESC;

\echo '--- 12a. silver_identifier columns (confirm shape before dup check) ---'
SELECT column_name FROM information_schema.columns WHERE table_name = 'silver_identifier' ORDER BY ordinal_position;

\echo '--- 13. duplicate (anchor, ingestion_source, input_id) link rows in *_ingestion_source join tables ---'
SELECT 'entity' AS anchor_type, entity_id AS anchor_id, ingestion_source_id, input_id, COUNT(*) AS n
FROM entity_ingestion_source
WHERE ingestion_source_id IN :mig_sources
GROUP BY 1,2,3,4 HAVING COUNT(*) > 1
UNION ALL
SELECT 'instrument', instrument_id, ingestion_source_id, input_id, COUNT(*)
FROM instrument_ingestion_source
WHERE ingestion_source_id IN :mig_sources
GROUP BY 1,2,3,4 HAVING COUNT(*) > 1;

\echo '--- 14. duplicate active entity_name rows for the same entity (>1 row with valid_to IS NULL, same name_type) ---'
SELECT en.entity_id, en.name_type, COUNT(*) AS n_active_names, array_agg(en.name) AS names
FROM entity_name en
WHERE en.entity_id IN :mig_entities AND en.valid_to IS NULL
GROUP BY en.entity_id, en.name_type
HAVING COUNT(*) > 1;

\echo '--- 15. duplicate active entity_type rows for the same entity ---'
SELECT et.entity_id, COUNT(*) AS n_active_types, array_agg(DISTINCT et.entity_type) AS types
FROM entity_type et
WHERE et.entity_id IN :mig_entities AND et.valid_to IS NULL
GROUP BY et.entity_id
HAVING COUNT(*) > 1;

\echo '--- 16. duplicate entity_relationship edges (same parent/child/type, >1 active row) ---'
SELECT parent_entity_id, child_entity_id, relationship_type, COUNT(*) AS n
FROM entity_relationship
WHERE ingestion_source_id IN :mig_sources AND valid_to IS NULL
GROUP BY 1,2,3 HAVING COUNT(*) > 1;

\echo '--- 17. duplicate active entity_attribute rows (same entity+attribute_name+as_of, >1 row) ---'
SELECT ea.entity_id, ea.attribute_name, ea.as_of, COUNT(*) AS n
FROM entity_attribute ea
WHERE ea.entity_id IN :mig_entities
GROUP BY 1,2,3 HAVING COUNT(*) > 1;

\echo ''
\echo '========== CONSISTENCY =========='

\echo '--- 18. entities with no active name at all ---'
SELECT me.entity_id FROM :mig_entities me
WHERE NOT EXISTS (SELECT 1 FROM entity_name en WHERE en.entity_id = me.entity_id AND en.valid_to IS NULL);

\echo '--- 19. entities with no active entity_type at all ---'
SELECT me.entity_id FROM :mig_entities me
WHERE NOT EXISTS (SELECT 1 FROM entity_type et WHERE et.entity_id = me.entity_id AND et.valid_to IS NULL);

\echo '--- 20. instruments with no active name ---'
SELECT mi.instrument_id FROM :mig_instruments mi
WHERE NOT EXISTS (SELECT 1 FROM instrument_name inm WHERE inm.instrument_id = mi.instrument_id AND inm.valid_to IS NULL);

\echo '--- 21. instruments with no active instrument_type ---'
SELECT mi.instrument_id FROM :mig_instruments mi
WHERE NOT EXISTS (SELECT 1 FROM instrument_type it WHERE it.instrument_id = mi.instrument_id AND it.valid_to IS NULL);

\echo '--- 22. entities typed fund_vehicle/co_investment/spv that are never a CHILD in any relationship ---'
SELECT me.entity_id, en.name, et.entity_type
FROM :mig_entities me
JOIN entity_type et ON et.entity_id = me.entity_id AND et.valid_to IS NULL
LEFT JOIN entity_name en ON en.entity_id = me.entity_id AND en.valid_to IS NULL
WHERE et.entity_type IN ('fund_vehicle','co_investment','spv')
  AND NOT EXISTS (SELECT 1 FROM entity_relationship er WHERE er.child_entity_id = me.entity_id);

\echo '--- 23. edges between two of our entities but recorded under a DIFFERENT source (informational) ---'
SELECT er.relationship_id, er.parent_entity_id, er.child_entity_id, er.relationship_type, s.source_type
FROM entity_relationship er
JOIN ingestion_source s ON s.ingestion_source_id = er.ingestion_source_id
WHERE er.parent_entity_id IN :mig_entities
  AND er.child_entity_id IN :mig_entities
  AND er.ingestion_source_id NOT IN :mig_sources;

\echo '--- 24. orphaned resolution_input_snapshot rows (per orphaned_ingestion_source_rows.sql pattern), scoped to our sources ---'
SELECT 'entity' AS anchor_type, COUNT(*) FROM resolution_input_snapshot s
WHERE s.target_type = 'ENTITY' AND s.origin_entity_id IS NOT NULL
  AND s.ingestion_source_id IN :mig_sources
  AND NOT EXISTS (
    SELECT 1 FROM entity_ingestion_source eis
    WHERE eis.entity_id = s.origin_entity_id AND eis.ingestion_source_id = s.ingestion_source_id AND eis.input_id = s.input_id
  )
UNION ALL
SELECT 'instrument', COUNT(*) FROM resolution_input_snapshot s
WHERE s.target_type = 'INSTRUMENT' AND s.origin_instrument_id IS NOT NULL
  AND s.ingestion_source_id IN :mig_sources
  AND NOT EXISTS (
    SELECT 1 FROM instrument_ingestion_source iis
    WHERE iis.instrument_id = s.origin_instrument_id AND iis.ingestion_source_id = s.ingestion_source_id AND iis.input_id = s.input_id
  );

\echo '--- 25. unreviewed ingestion_source rows still outstanding (reviewed_at IS NULL) ---'
SELECT count(*) AS unreviewed FROM ingestion_source s
WHERE s.ingestion_source_id IN :mig_sources AND s.reviewed_at IS NULL;

\echo '--- 26. name vs strategy mismatch sanity ---'
SELECT me.entity_id, en.name, es.strategy_tier, es.strategy_value
FROM :mig_entities me
JOIN entity_name en ON en.entity_id = me.entity_id AND en.valid_to IS NULL
JOIN entity_strategy es ON es.entity_id = me.entity_id
WHERE (en.name ILIKE '%credit%' AND es.strategy_value ILIKE '%equity%')
   OR (en.name ILIKE '%equity%' AND es.strategy_value ILIKE '%credit%')
   OR (en.name ILIKE '%venture%' AND es.strategy_value ILIKE '%buyout%')
   OR (en.name ILIKE '%buyout%' AND es.strategy_value ILIKE '%venture%');
