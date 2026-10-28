-- Held-instruments summary for a holder entity, aggregated by ISSUER
-- entity_id (not by name string, to avoid join fanout when an issuer has
-- multiple simultaneously-open entity_name rows).
-- Usage: psql ... -v entity_id="'<uuid>'" -f held_instruments_summary.sql

\echo '=== positions per issuer entity_id (dedup on entity_id, not name) ==='
SELECT i.entity_id AS issuer_entity_id, COUNT(*) AS position_count,
       COUNT(DISTINCT i.instrument_id) AS distinct_instruments
FROM position p
JOIN instrument i ON i.instrument_id = p.held_instrument_id
WHERE p.holder_entity_id = :entity_id
GROUP BY i.entity_id
ORDER BY position_count DESC;

\echo '=== issuers with more than one currently-open entity_name row (the fanout risk) ==='
SELECT en.entity_id, COUNT(*) AS open_name_count, array_agg(en.name ORDER BY en.name) AS names
FROM position p
JOIN instrument i ON i.instrument_id = p.held_instrument_id
JOIN entity_name en ON en.entity_id = i.entity_id AND en.valid_to IS NULL
WHERE p.holder_entity_id = :entity_id
GROUP BY en.entity_id
HAVING COUNT(*) > 1
ORDER BY open_name_count DESC;
