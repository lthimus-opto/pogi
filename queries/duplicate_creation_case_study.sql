-- Concrete look at the "written at the same time" duplicate-creation correction:
-- correction_id 55517ac4-0b72-4bb8-9d8b-2b93f1f0eb82
-- original (duplicate, now merged away) instrument_id 7b0d2236-c960-4c91-9a8e-b58f3511127a
-- surviving instrument_id ce059ba2-3c05-4050-809e-32b58b743b5f
-- input_id af099715-0f69-4e5f-a291-a330b9d03132
-- ingestion_source_id b821724c-3f58-43e4-ba0c-1bb656e942ed

\echo '=== does instrument have a created/recorded timestamp column? ==='
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'instrument' ORDER BY ordinal_position;

\echo '=== the snapshot for the duplicate-causing input_id ==='
SELECT snapshot_id, input_id, recorded_at, payload->>'name' AS name, payload->>'silver_id' AS silver_id
FROM resolution_input_snapshot
WHERE input_id = 'af099715-0f69-4e5f-a291-a330b9d03132';

\echo '=== ALL snapshots that ever resolved to either of the two instrument_ids (dup + survivor), ordered by time ==='
SELECT s.snapshot_id, s.input_id, s.recorded_at, s.payload->>'name' AS extracted_name, s.payload->>'silver_id' AS silver_id
FROM resolution_input_snapshot s
WHERE s.target_type = 'INSTRUMENT'
  AND (s.origin_instrument_id IN ('7b0d2236-c960-4c91-9a8e-b58f3511127a', 'ce059ba2-3c05-4050-809e-32b58b743b5f'))
ORDER BY s.recorded_at;

\echo '=== instrument_ingestion_source link rows for both instrument_ids, ordered by valid_from ==='
SELECT instrument_id, ingestion_source_id, input_id, valid_from
FROM instrument_ingestion_source
WHERE instrument_id IN ('7b0d2236-c960-4c91-9a8e-b58f3511127a', 'ce059ba2-3c05-4050-809e-32b58b743b5f')
ORDER BY valid_from;

\echo '=== instrument_name rows for both, to see the raw extracted names that collided ==='
SELECT instrument_id, name, name_type, valid_from, valid_to, input_id
FROM instrument_name
WHERE instrument_id IN ('7b0d2236-c960-4c91-9a8e-b58f3511127a', 'ce059ba2-3c05-4050-809e-32b58b743b5f')
ORDER BY valid_from;
