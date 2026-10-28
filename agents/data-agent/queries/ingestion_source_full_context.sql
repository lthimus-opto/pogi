-- Full context deep-dive for a single ingestion_source_id: what it is, and everything
-- it loaded into Atlas across entity/instrument/position layers.
--
-- Usage: psql ... -v ingestion_source_id="'<uuid>'" -f ingestion_source_full_context.sql

\echo '=== ingestion_source row itself ==='
SELECT * FROM ingestion_source WHERE ingestion_source_id = :ingestion_source_id;

\echo '=== counts: entities / instruments / positions linked ==='
SELECT 'entity' AS layer, COUNT(*) FROM entity_ingestion_source WHERE ingestion_source_id = :ingestion_source_id
UNION ALL
SELECT 'instrument', COUNT(*) FROM instrument_ingestion_source WHERE ingestion_source_id = :ingestion_source_id
UNION ALL
SELECT 'position', COUNT(*) FROM position_ingestion_source WHERE ingestion_source_id = :ingestion_source_id;

\echo '=== entity_type rows written by this source ==='
SELECT entity_type, COUNT(*) FROM entity_type WHERE ingestion_source_id = :ingestion_source_id GROUP BY 1;

\echo '=== entity_attribute / entity_strategy rows written by this source (usually 0 for SOI unless real-estate/GICS data present) ==='
SELECT 'entity_attribute' AS tbl, attribute_name AS dimension, COUNT(*)
FROM entity_attribute WHERE ingestion_source_id = :ingestion_source_id GROUP BY 1, 2
UNION ALL
SELECT 'entity_strategy', strategy_system || '/' || strategy_tier, COUNT(*)
FROM entity_strategy WHERE ingestion_source_id = :ingestion_source_id GROUP BY 1, 2;

\echo '=== instrument_type / instrument_attribute coverage from this source ==='
SELECT 'instrument_type' AS tbl, instrument_type::text AS dimension, COUNT(*)
FROM instrument_type WHERE ingestion_source_id = :ingestion_source_id GROUP BY 1, 2
UNION ALL
SELECT 'instrument_attribute', attribute_name, COUNT(*)
FROM instrument_attribute WHERE ingestion_source_id = :ingestion_source_id GROUP BY 1, 2;

\echo '=== distinct instruments loaded, with issuer + resolved instrument_type ==='
SELECT DISTINCT i.instrument_id, e.entity_id AS issuer_entity_id, en.name AS issuer_current_name, it.instrument_type
FROM instrument_ingestion_source iis
JOIN instrument i ON i.instrument_id = iis.instrument_id
JOIN entity e ON e.entity_id = i.entity_id
LEFT JOIN entity_name en ON en.entity_id = e.entity_id AND en.valid_to IS NULL
LEFT JOIN instrument_type it ON it.instrument_id = i.instrument_id AND it.valid_to IS NULL
WHERE iis.ingestion_source_id = :ingestion_source_id
ORDER BY issuer_current_name, it.instrument_type;

\echo '=== distinct positions loaded, with instrument + FAIR_VALUE/COST_BASIS from this source ==='
SELECT p.position_id, p.held_instrument_id, en.name AS issuer_current_name,
  MAX(CASE WHEN v.valuation_method = 'FAIR_VALUE' THEN v.value END) AS fair_value,
  MAX(CASE WHEN v.valuation_method = 'COST_BASIS' THEN v.value END) AS cost_basis,
  MAX(v.as_of) AS valuation_as_of
FROM position_ingestion_source pis
JOIN position p ON p.position_id = pis.position_id
JOIN instrument i ON i.instrument_id = p.held_instrument_id
JOIN entity e ON e.entity_id = i.entity_id
LEFT JOIN entity_name en ON en.entity_id = e.entity_id AND en.valid_to IS NULL
LEFT JOIN valuation v ON v.position_id = p.position_id AND v.ingestion_source_id = pis.ingestion_source_id
WHERE pis.ingestion_source_id = :ingestion_source_id
GROUP BY p.position_id, p.held_instrument_id, en.name
ORDER BY en.name;

\echo '=== entities from this source whose entity_id also carries OTHER entity_types from OTHER sources (cross-source merge signal) ==='
SELECT DISTINCT e.entity_id, en.name AS current_name, et.entity_type,
  (et.ingestion_source_id = :ingestion_source_id) AS from_this_source
FROM entity_ingestion_source eis
JOIN entity e ON e.entity_id = eis.entity_id
LEFT JOIN entity_name en ON en.entity_id = e.entity_id AND en.valid_to IS NULL
JOIN entity_type et ON et.entity_id = e.entity_id AND et.valid_to IS NULL
WHERE eis.ingestion_source_id = :ingestion_source_id
ORDER BY current_name, from_this_source DESC;
