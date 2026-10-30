-- Categorizes every "duplicate" found in the SYSTEM_MIGRATION scope into:
--   A) safe to auto-close: >1 currently-open (valid_to IS NULL) row for the
--      same (anchor, key) where the SAME value is just being re-asserted on
--      a later valid_from -- closing all but the latest is a pure no-op on
--      meaning, just collapses redundant rows.
--   B) needs a human decision: >1 currently-open row for the same (anchor,
--      key) where the VALUES actually differ -- closing the older one by
--      date is not obviously correct, could be erasing a disagreement that
--      needs adjudication rather than a mechanical fix.

-- CORRECTED after a real near-miss: see knowledge/failure_modes.md's
-- `cross_source_eav_corroboration_is_not_a_duplicate` entry. The original
-- version of this script called every one of these groups a "duplicate"
-- without checking `ingestion_source_group_key` -- re-checked exhaustively,
-- 0 of 1,205 flagged groups across 5 tables were same-source; all were
-- different sources independently corroborating the same fact, exactly the
-- documented "one row = one source's claim, never blended" design. There is
-- NO category A here -- closing/collapsing any of these would delete another
-- source's independent, still-valid claim. The only queries below worth
-- still running are the true same-source checks and the real value-conflict
-- checks (category B); the rest is kept only as a worked example of how to
-- tell the two apart -- always group by ingestion_source_group_key before
-- calling anything a duplicate in this schema.

\set mig_sources     '(SELECT ingestion_source_id FROM ingestion_source WHERE source_type = ''SYSTEM_MIGRATION'')'
\set mig_entities    '(SELECT DISTINCT entity_id FROM entity_ingestion_source WHERE ingestion_source_id IN :mig_sources)'
\set mig_instruments '(SELECT DISTINCT instrument_id FROM instrument_ingestion_source WHERE ingestion_source_id IN :mig_sources)'

\echo '========== ENTITY_TYPE =========='
\echo '--- A) same type value re-asserted on multiple open rows (safe to collapse) ---'
SELECT count(*) FROM (
  SELECT entity_id, entity_type FROM entity_type
  WHERE entity_id IN :mig_entities AND valid_to IS NULL
  GROUP BY entity_id, entity_type HAVING count(*) > 1
) x;

\echo '--- B) entity with >1 DISTINCT type value open at once that are genuinely mutually exclusive (same type enum, different value is impossible here since entity_type is additive -- so B is structurally empty for this table; multi-type is by design) ---'
SELECT entity_id, array_agg(DISTINCT entity_type) FROM entity_type
WHERE entity_id IN :mig_entities AND valid_to IS NULL
GROUP BY entity_id
HAVING count(DISTINCT entity_type) > 1
LIMIT 5;

\echo ''
\echo '========== ENTITY_NAME =========='
\echo '--- A) same (entity, name_type) with >1 open row -- list with the actual text to eyeball casing-only vs real differences ---'
SELECT entity_id, name_type, count(*) AS n_open, array_agg(name ORDER BY valid_from) AS names, array_agg(valid_from ORDER BY valid_from) AS valid_froms
FROM entity_name
WHERE entity_id IN :mig_entities AND valid_to IS NULL
GROUP BY entity_id, name_type
HAVING count(*) > 1
ORDER BY n_open DESC
LIMIT 20;

\echo '--- total count of (entity, name_type) groups with >1 open row ---'
SELECT count(*) FROM (
  SELECT entity_id, name_type FROM entity_name
  WHERE entity_id IN :mig_entities AND valid_to IS NULL
  GROUP BY entity_id, name_type HAVING count(*) > 1
) x;

\echo ''
\echo '========== ENTITY_ATTRIBUTE (value-bearing, so the real A/B split matters most here) =========='
\echo '--- A) same (entity, attribute_name, as_of) with identical value repeated (safe/no-op) ---'
SELECT count(*) FROM (
  SELECT entity_id, attribute_name, as_of FROM entity_attribute
  WHERE entity_id IN :mig_entities
  GROUP BY entity_id, attribute_name, as_of, attribute_value_numeric, attribute_value_text, attribute_value_date, attribute_value_boolean, attribute_value_integer
  HAVING count(*) > 1
) x;

\echo '--- B) same (entity, attribute_name, as_of) with DIFFERENT values -- true conflicts, needs a human call ---'
SELECT entity_id, attribute_name, as_of, count(DISTINCT attribute_value_numeric) AS n_distinct, array_agg(DISTINCT attribute_value_numeric) AS values
FROM entity_attribute
WHERE entity_id IN :mig_entities
GROUP BY entity_id, attribute_name, as_of
HAVING count(DISTINCT attribute_value_numeric) > 1
ORDER BY entity_id, as_of;

\echo ''
\echo '========== INSTRUMENT_NAME =========='
SELECT instrument_id, name_type, count(*) AS n_open, array_agg(name ORDER BY valid_from) AS names
FROM instrument_name
WHERE instrument_id IN :mig_instruments AND valid_to IS NULL
GROUP BY instrument_id, name_type
HAVING count(*) > 1;

\echo ''
\echo '========== INSTRUMENT_FEE + FEE_ATTRIBUTE =========='
\echo '--- wrapper-level duplicates (>1 instrument_fee row of the same fee_type for an instrument) ---'
SELECT instrument_id, fee_type, count(*) AS n
FROM instrument_fee
WHERE instrument_id IN :mig_instruments
GROUP BY instrument_id, fee_type
HAVING count(*) > 1;

\echo '--- do the duplicate fee wrappers actually carry conflicting rates, or just redundant re-assertion? ---'
SELECT f.instrument_id, f.fee_type, fa.attribute_name, fa.valid_from,
       count(DISTINCT COALESCE(fa.attribute_value_numeric::text, fa.attribute_value_text)) AS n_distinct_values,
       array_agg(DISTINCT COALESCE(fa.attribute_value_numeric::text, fa.attribute_value_text)) AS values
FROM instrument_fee f
JOIN instrument_fee_attribute fa ON fa.fee_id = f.fee_id
WHERE f.instrument_id IN :mig_instruments
GROUP BY f.instrument_id, f.fee_type, fa.attribute_name, fa.valid_from
HAVING count(DISTINCT COALESCE(fa.attribute_value_numeric::text, fa.attribute_value_text)) > 1;
