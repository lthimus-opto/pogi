-- Overview of resolution_correction: what corrections have been made, on what,
-- and why. Read-only exploration to inform resolution-system enhancements.

\echo '=== total corrections ==='
SELECT COUNT(*) FROM resolution_correction;

\echo '=== breakdown by target_type + operation ==='
SELECT target_type, correction_operation, COUNT(*) AS n
FROM resolution_correction
GROUP BY target_type, correction_operation
ORDER BY n DESC;

\echo '=== breakdown by reason ==='
SELECT reason, COUNT(*) AS n
FROM resolution_correction
GROUP BY reason
ORDER BY n DESC;

\echo '=== breakdown by reason x operation ==='
SELECT correction_operation, reason, COUNT(*) AS n
FROM resolution_correction
GROUP BY correction_operation, reason
ORDER BY correction_operation, n DESC;

\echo '=== corrected_by (who/what is issuing corrections) ==='
SELECT corrected_by, COUNT(*) AS n
FROM resolution_correction
GROUP BY corrected_by
ORDER BY n DESC;

\echo '=== corrections over time (by day) ==='
SELECT date_trunc('day', corrected_at) AS day, COUNT(*) AS n
FROM resolution_correction
GROUP BY 1 ORDER BY 1 DESC
LIMIT 30;

\echo '=== which ingestion sources get corrected most (source_type/group_key) ==='
SELECT s.source_type, s.group_key, COUNT(*) AS n
FROM resolution_correction rc
JOIN ingestion_source s ON s.ingestion_source_id = rc.ingestion_source_id
GROUP BY s.source_type, s.group_key
ORDER BY n DESC
LIMIT 30;

\echo '=== sample of most recent corrections with comments ==='
SELECT correction_id, target_type, correction_operation, reason, reason_comment,
       corrected_by, corrected_at, original_target_id, resolution_target_id, ingestion_source_id, input_id
FROM resolution_correction
WHERE reason_comment IS NOT NULL AND reason_comment <> ''
ORDER BY corrected_at DESC
LIMIT 40;

\echo '=== sample of most recent corrections overall ==='
SELECT correction_id, target_type, correction_operation, reason, reason_comment,
       corrected_by, corrected_at
FROM resolution_correction
ORDER BY corrected_at DESC
LIMIT 40;

\echo '=== anchors corrected more than once (repeat offenders) ==='
SELECT target_type, original_target_id, COUNT(*) AS correction_count,
       array_agg(DISTINCT correction_operation) AS operations,
       array_agg(DISTINCT reason) AS reasons
FROM resolution_correction
GROUP BY target_type, original_target_id
HAVING COUNT(*) > 1
ORDER BY correction_count DESC
LIMIT 30;
