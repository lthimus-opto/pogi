WITH safe_cluster AS (
  SELECT DISTINCT rc.input_id, rc.resolution_target_id AS correct_target_id,
         rc.original_target_id AS wrong_target_id, rc.reason_comment
  FROM resolution_correction rc
  JOIN resolution_staging rs ON rs.input_id = rc.input_id
  WHERE (rc.reason_comment ILIKE '%safe%' OR rc.reason_comment ILIKE '%agreement for future equity%')
    AND rs.resolution_method = 'LLM_TIEBREAKER'
),
candidate_targets AS (
  SELECT rs.input_id, rs.candidate_match_target_id AS target_id,
         MAX(rs.candidate_match_name) AS display_name,
         MAX(rs.candidate_match_confidence_score) AS best_confidence,
         MAX(rs.resolution_operation::text) AS old_resolution_operation,
         (array_agg(rs.llm_reasoning ORDER BY rs.llm_confidence DESC NULLS LAST))[1] AS a_llm_reasoning,
         (array_agg(rs.llm_confidence ORDER BY rs.llm_confidence DESC NULLS LAST))[1] AS a_llm_confidence
  FROM resolution_staging rs
  JOIN safe_cluster sc ON sc.input_id = rs.input_id
  WHERE rs.candidate_match_target_id IS NOT NULL
  GROUP BY rs.input_id, rs.candidate_match_target_id
  HAVING MAX(rs.candidate_match_confidence_score) >= 20
),
candidate_attrs AS (
  SELECT ct.input_id, ct.target_id, ct.display_name,
         jsonb_agg(jsonb_build_object('attribute_name', ia.attribute_name,
              'value', COALESCE(ia.attribute_value_text, ia.attribute_value_integer::text,
                                 ia.attribute_value_numeric::text, ia.attribute_value_date::text,
                                 ia.attribute_value_boolean::text)
         )) FILTER (WHERE ia.attribute_name IS NOT NULL) AS attributes
  FROM candidate_targets ct
  LEFT JOIN instrument_attribute ia ON ia.instrument_id = ct.target_id
  GROUP BY ct.input_id, ct.target_id, ct.display_name
),
candidates_json AS (
  SELECT input_id, jsonb_agg(jsonb_build_object(
      'target_id', target_id, 'display_name', display_name, 'attributes', COALESCE(attributes, '[]'::jsonb)
  )) AS candidates
  FROM candidate_attrs
  GROUP BY input_id
),
source_info AS (
  SELECT sc.input_id, sc.correct_target_id, sc.wrong_target_id, sc.reason_comment,
         s.payload->>'name' AS source_name,
         s.payload->'attributes' AS source_attributes_raw
  FROM safe_cluster sc
  JOIN LATERAL (
    SELECT payload FROM resolution_input_snapshot WHERE input_id = sc.input_id ORDER BY recorded_at DESC LIMIT 1
  ) s ON true
),
old_summary AS (
  SELECT ct.input_id,
    jsonb_agg(jsonb_build_object(
      'target_id', ct.target_id, 'old_resolution_operation', ct.old_resolution_operation,
      'old_llm_confidence', ct.a_llm_confidence, 'old_llm_reasoning', ct.a_llm_reasoning
    )) AS old_per_candidate
  FROM candidate_targets ct
  GROUP BY ct.input_id
)
SELECT jsonb_pretty(jsonb_agg(jsonb_build_object(
  'input_id', si.input_id,
  'source_name', si.source_name,
  'source_attributes_raw', si.source_attributes_raw,
  'correct_target_id', si.correct_target_id,
  'wrong_target_id', si.wrong_target_id,
  'reason_comment', si.reason_comment,
  'candidates', cj.candidates,
  'old_summary', os.old_per_candidate
)))
FROM source_info si
JOIN candidates_json cj ON cj.input_id = si.input_id
JOIN old_summary os ON os.input_id = si.input_id;
