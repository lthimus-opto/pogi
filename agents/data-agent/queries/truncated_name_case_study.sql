-- Concrete look at the two "truncated name" corrections: what name was actually
-- extracted (from the snapshot payload), and what it got wrongly force-matched to
-- vs. what it should have matched (or been inserted as).

\echo '=== the two truncated-name corrections themselves ==='
SELECT correction_id, target_type, original_target_id, resolution_target_id, input_id, ingestion_source_id, reason_comment
FROM resolution_correction
WHERE reason_comment ILIKE '%truncated%';

\echo '=== ENTITY case: snapshot payload for the input that got force-matched ==='
SELECT s.snapshot_id, s.input_id, s.target_type, s.payload
FROM resolution_input_snapshot s
WHERE s.input_id = '9afeac5b-bbc9-467e-a8ea-f3bc40293640';

\echo '=== ENTITY case: what name(s) does the WRONG target (original_target_id) actually have? ==='
SELECT name, name_type, valid_from, valid_to FROM entity_name WHERE entity_id = '04ea26b4-51aa-49f5-9c90-14102e502e98' ORDER BY valid_from;

\echo '=== ENTITY case: what name(s) does the CORRECT target (resolution_target_id) actually have? ==='
SELECT name, name_type, valid_from, valid_to FROM entity_name WHERE entity_id = '30957ce8-52c3-4e37-8edf-187345b45043' ORDER BY valid_from;

\echo '=== INSTRUMENT case: snapshot payload for the input that got force-matched ==='
SELECT s.snapshot_id, s.input_id, s.target_type, s.payload
FROM resolution_input_snapshot s
WHERE s.input_id = '8af335b8-04df-45b0-85cd-87abbc2d5388';

\echo '=== INSTRUMENT case: what name(s) does the WRONG target (original_target_id) actually have? ==='
SELECT name, name_type, valid_from, valid_to FROM instrument_name WHERE instrument_id = '5103f512-b19b-4006-8052-1ec7bbe6221d' ORDER BY valid_from;

\echo '=== INSTRUMENT case: what name(s) does the CORRECT target (resolution_target_id) actually have? ==='
SELECT name, name_type, valid_from, valid_to FROM instrument_name WHERE instrument_id = 'b614f439-e0fe-47d6-9885-5de217b80a08' ORDER BY valid_from;
