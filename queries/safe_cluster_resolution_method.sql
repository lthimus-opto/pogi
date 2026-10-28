-- For every SAFE/Simple-Agreement-For-Future-Equity correction, check what
-- resolution_method actually produced the wrong result. If it's THRESHOLD_INSERT
-- (below min_confidence_threshold, no LLM call), the new prompt can't have helped --
-- the LLM was never consulted. If it's LLM_TIEBREAKER, we can replay it.

\echo '=== resolution_method distribution for the SAFE-cluster corrections ==='
SELECT rs.resolution_method, rs.candidate_match_strategy, COUNT(DISTINCT rs.input_id) AS n_inputs
FROM resolution_correction rc
JOIN resolution_staging rs ON rs.input_id = rc.input_id
WHERE rc.reason_comment ILIKE '%safe%' OR rc.reason_comment ILIKE '%agreement for future equity%'
GROUP BY rs.resolution_method, rs.candidate_match_strategy
ORDER BY n_inputs DESC;

\echo '=== detail: one row per (input_id, candidate) for the SAFE-cluster, most recent first ==='
SELECT rc.corrected_at, rs.input_id, rs.input_name, rs.candidate_match_name,
       rs.candidate_match_confidence_score, rs.candidate_match_strategy,
       rs.llm_confidence, rs.llm_reasoning, rs.resolution_operation, rs.resolution_method
FROM resolution_correction rc
JOIN resolution_staging rs ON rs.input_id = rc.input_id
WHERE rc.reason_comment ILIKE '%safe%' OR rc.reason_comment ILIKE '%agreement for future equity%'
ORDER BY rc.corrected_at DESC, rs.candidate_match_confidence_score DESC
LIMIT 100;
