-- Full context deep-dive for a single entity_id, across every Atlas layer
-- (entity, instrument, position, and all three time-series tables), not
-- just the entity-level tables.
--
-- NOTE on scoped_to casing: `tag.scoped_to` and `silver_identifier.scoped_to`
-- use the AnchorScope/ResolutionTargetType enum (UPPERCASE: ENTITY,
-- INSTRUMENT, POSITION). `analytics`/`valuation`/`operating_cash_flow`
-- .scoped_to use a *different* enum, scoped_to_enum (lowercase: entity,
-- instrument, position). Do not mix these up.
--
-- Usage: psql ... -v entity_id="'<uuid>'" -f entity_full_context.sql

\echo '========== ENTITY LAYER =========='

\echo '=== entity (anchor) ==='
SELECT * FROM entity WHERE entity_id = :entity_id;

\echo '=== entity_name (all names, full history) ==='
SELECT name, name_type, valid_from, valid_to, ingestion_source_id, ingestion_source_group_key, recorded_at
FROM entity_name WHERE entity_id = :entity_id ORDER BY valid_from;

\echo '=== entity_type ==='
SELECT entity_type, valid_from, valid_to, ingestion_source_id, ingestion_source_group_key, recorded_at
FROM entity_type WHERE entity_id = :entity_id ORDER BY valid_from;

\echo '=== entity_identifier ==='
SELECT identifier_type, identifier, valid_from, valid_to, ingestion_source_id, ingestion_source_group_key
FROM entity_identifier WHERE entity_id = :entity_id ORDER BY valid_from;

\echo '=== entity_attribute (rich data / EAV) ==='
SELECT attribute_name, attribute_value_text, attribute_value_integer, attribute_value_numeric,
       attribute_value_date, attribute_value_boolean, as_of, ingestion_source_id, ingestion_source_group_key
FROM entity_attribute WHERE entity_id = :entity_id ORDER BY attribute_name, as_of;

\echo '=== entity_strategy ==='
SELECT strategy_system, strategy_tier, strategy_value, strategy_group_id, valid_from, valid_to, ingestion_source_id
FROM entity_strategy WHERE entity_id = :entity_id ORDER BY strategy_system, strategy_tier;

\echo '=== entity_operational_phase (fund lifecycle stage) ==='
SELECT operational_phase, valid_from, valid_to, ingestion_source_id, ingestion_source_group_key, recorded_at
FROM entity_operational_phase WHERE entity_id = :entity_id ORDER BY valid_from;

\echo '=== tag (scoped_to = ENTITY -- shared tag table, not a dedicated entity_tag table) ==='
SELECT tag_category, tag_value, status, as_of
FROM tag WHERE entity_id = :entity_id AND scoped_to = 'ENTITY' ORDER BY tag_category;

\echo '=== entity_relationship (as parent) ==='
SELECT relationship_id, child_entity_id, relationship_type, valid_from, valid_to, ingestion_source_id
FROM entity_relationship WHERE parent_entity_id = :entity_id ORDER BY valid_from;

\echo '=== entity_relationship (as child) ==='
SELECT relationship_id, parent_entity_id, relationship_type, valid_from, valid_to, ingestion_source_id
FROM entity_relationship WHERE child_entity_id = :entity_id ORDER BY valid_from;

\echo '=== silver_identifier (upstream pipe IDs mapped to this entity) ==='
SELECT silver_id, ingestion_source_group_key, scoped_to, ingestion_source_id, recorded_at
FROM silver_identifier WHERE entity_id = :entity_id;

\echo '=== which sources loaded ENTITY-level data (count by source_type/group_key/review status) ==='
SELECT s.source_type, s.group_key, s.entitlement_group,
       COUNT(*) AS link_count,
       COUNT(*) FILTER (WHERE s.reviewed_at IS NOT NULL) AS reviewed_count,
       MIN(s.ingested_at) AS earliest_ingest, MAX(s.ingested_at) AS latest_ingest
FROM entity_ingestion_source eis
JOIN ingestion_source s ON s.ingestion_source_id = eis.ingestion_source_id
WHERE eis.entity_id = :entity_id
GROUP BY s.source_type, s.group_key, s.entitlement_group;

\echo ''
\echo '========== INSTRUMENT LAYER (things this entity ISSUED) =========='

\echo '=== instrument (issued by this entity) -- count ==='
SELECT COUNT(*) AS instruments_issued FROM instrument WHERE entity_id = :entity_id;

\echo ''
\echo '========== POSITION LAYER (things this entity HOLDS) =========='

\echo '=== position count ==='
SELECT COUNT(*) AS position_count FROM position WHERE holder_entity_id = :entity_id;

\echo '=== held instruments summary -- issuer, instrument type, name (one row per position) ==='
SELECT issuer_name.name AS issuer_name, it.instrument_type, inm.name AS instrument_name
FROM position p
JOIN instrument i ON i.instrument_id = p.held_instrument_id
LEFT JOIN entity_name issuer_name ON issuer_name.entity_id = i.entity_id AND issuer_name.valid_to IS NULL
LEFT JOIN instrument_type it ON it.instrument_id = i.instrument_id AND it.valid_to IS NULL
LEFT JOIN instrument_name inm ON inm.instrument_id = i.instrument_id AND inm.valid_to IS NULL
WHERE p.holder_entity_id = :entity_id
ORDER BY issuer_name.name;

\echo '=== position_attribute summary (which attribute_names appear, and how often) ==='
SELECT pa.attribute_name, COUNT(*) AS row_count
FROM position p
JOIN position_attribute pa ON pa.position_id = p.position_id
WHERE p.holder_entity_id = :entity_id
GROUP BY pa.attribute_name;

\echo '=== which sources loaded POSITION-level data (count by source_type/group_key/review status) ==='
SELECT s.source_type, s.group_key, s.entitlement_group,
       COUNT(*) AS link_count,
       COUNT(*) FILTER (WHERE s.reviewed_at IS NOT NULL) AS reviewed_count
FROM position p
JOIN position_ingestion_source pis ON pis.position_id = p.position_id
JOIN ingestion_source s ON s.ingestion_source_id = pis.ingestion_source_id
WHERE p.holder_entity_id = :entity_id
GROUP BY s.source_type, s.group_key, s.entitlement_group;

\echo ''
\echo '========== TIME-SERIES LAYER (entity scope + position scope) =========='
\echo '(scoped_to uses the anchorscope enum -- UPPERCASE: ENTITY, INSTRUMENT, POSITION -- everywhere in this schema, no exceptions)'

\echo '=== analytics row counts, entity scope vs. position scope ==='
SELECT 'entity' AS level, COUNT(*) FROM analytics WHERE entity_id = :entity_id AND scoped_to = 'ENTITY'
UNION ALL
SELECT 'position' AS level, COUNT(*) FROM analytics a
JOIN position p ON p.position_id = a.position_id
WHERE p.holder_entity_id = :entity_id AND a.scoped_to = 'POSITION';

\echo '=== valuation row counts, entity scope vs. position scope ==='
SELECT 'entity' AS level, COUNT(*) FROM valuation WHERE entity_id = :entity_id AND scoped_to = 'ENTITY'
UNION ALL
SELECT 'position' AS level, COUNT(*) FROM valuation v
JOIN position p ON p.position_id = v.position_id
WHERE p.holder_entity_id = :entity_id AND v.scoped_to = 'POSITION';

\echo '=== operating_cash_flow row counts, entity scope vs. position scope ==='
SELECT 'entity' AS level, COUNT(*) FROM operating_cash_flow WHERE entity_id = :entity_id AND scoped_to = 'ENTITY'
UNION ALL
SELECT 'position' AS level, COUNT(*) FROM operating_cash_flow ocf
JOIN position p ON p.position_id = ocf.position_id
WHERE p.holder_entity_id = :entity_id AND ocf.scoped_to = 'POSITION';
