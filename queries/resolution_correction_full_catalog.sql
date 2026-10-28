-- Full catalog of all 94 corrections, oldest to newest, with source context.
SELECT rc.corrected_at, rc.target_type, rc.correction_operation, rc.reason,
       s.source_type, s.group_key,
       rc.reason_comment
FROM resolution_correction rc
LEFT JOIN ingestion_source s ON s.ingestion_source_id = rc.ingestion_source_id
ORDER BY rc.corrected_at ASC;
