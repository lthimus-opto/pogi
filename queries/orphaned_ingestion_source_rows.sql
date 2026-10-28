-- Finds resolution_input_snapshot rows that never got a matching *_ingestion_source
-- link row for the same (anchor, ingestion_source_id, input_id) triple.
--
-- Background: entity/instrument/position_ingestion_source originally had a 2-column
-- PK (anchor_id, ingestion_source_id), so a second input_id landing on the same anchor
-- via the same source would silently overwrite (not add to) the first via
-- ON CONFLICT DO UPDATE -- one of the two input_ids never got its own link row, even
-- though both got their own resolution_input_snapshot row (keyed by snapshot_id, so
-- unaffected). Migration e6f7a8b9c0d1 (2026-09-03) widened the PK to 4 columns
-- (+input_id, +valid_from) and backfilled from resolution_input_snapshot, but a
-- backfill can't invent a link row when the collision already destroyed one side of
-- it in the live table before the backfill ran -- those rows stay orphaned forever
-- unless manually recovered from the snapshot payload.
--
-- Usage: psql ... -f orphaned_ingestion_source_rows.sql

\echo '=== scope: orphaned snapshots per anchor type ==='
SELECT 'instrument' AS anchor_type, COUNT(*) FROM resolution_input_snapshot s
WHERE s.target_type = 'INSTRUMENT' AND s.origin_instrument_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM instrument_ingestion_source iis
    WHERE iis.instrument_id = s.origin_instrument_id
      AND iis.ingestion_source_id = s.ingestion_source_id AND iis.input_id = s.input_id
  )
UNION ALL
SELECT 'entity', COUNT(*) FROM resolution_input_snapshot s
WHERE s.target_type = 'ENTITY' AND s.origin_entity_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM entity_ingestion_source eis
    WHERE eis.entity_id = s.origin_entity_id
      AND eis.ingestion_source_id = s.ingestion_source_id AND eis.input_id = s.input_id
  )
UNION ALL
SELECT 'position', COUNT(*) FROM resolution_input_snapshot s
WHERE s.target_type = 'POSITION' AND s.origin_position_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM position_ingestion_source pis
    WHERE pis.position_id = s.origin_position_id
      AND pis.ingestion_source_id = s.ingestion_source_id AND pis.input_id = s.input_id
  );

\echo '=== timeline: orphaned INSTRUMENT snapshots by day (confirms whether this is still happening) ==='
SELECT date_trunc('day', s.recorded_at) AS day, COUNT(*) AS total_snapshots,
       COUNT(*) FILTER (
         WHERE NOT EXISTS (
           SELECT 1 FROM instrument_ingestion_source iis
           WHERE iis.instrument_id = s.origin_instrument_id
             AND iis.ingestion_source_id = s.ingestion_source_id AND iis.input_id = s.input_id
         )
       ) AS orphaned
FROM resolution_input_snapshot s
WHERE s.target_type = 'INSTRUMENT' AND s.origin_instrument_id IS NOT NULL
GROUP BY 1 ORDER BY 1 DESC;

\echo '=== detail: each orphaned INSTRUMENT snapshot, with sibling collision counts for the same (instrument, source) pair ==='
WITH orphans AS (
  SELECT s.snapshot_id, s.input_id, s.origin_instrument_id, s.ingestion_source_id, s.recorded_at, s.payload
  FROM resolution_input_snapshot s
  WHERE s.target_type = 'INSTRUMENT' AND s.origin_instrument_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM instrument_ingestion_source iis
      WHERE iis.instrument_id = s.origin_instrument_id
        AND iis.ingestion_source_id = s.ingestion_source_id AND iis.input_id = s.input_id
    )
)
SELECT o.snapshot_id, o.input_id, o.origin_instrument_id, o.ingestion_source_id, o.recorded_at,
       (SELECT COUNT(*) FROM instrument_ingestion_source iis
        WHERE iis.instrument_id = o.origin_instrument_id AND iis.ingestion_source_id = o.ingestion_source_id
       ) AS surviving_link_rows_for_pair,
       (SELECT COUNT(*) FROM resolution_input_snapshot s2
        WHERE s2.origin_instrument_id = o.origin_instrument_id AND s2.ingestion_source_id = o.ingestion_source_id
       ) AS sibling_snapshots_for_pair
FROM orphans o
ORDER BY o.recorded_at;
