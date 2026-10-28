\echo '=== does instrument_name/identifier/type/attribute/valuation data exist for input_id a760fac9 (the orphaned one)? ==='
SELECT 'instrument_name' AS tbl, COUNT(*) FROM instrument_name WHERE input_id = 'a760fac9-e844-4014-9205-36923ab93f29'
UNION ALL
SELECT 'instrument_identifier', COUNT(*) FROM instrument_identifier WHERE input_id = 'a760fac9-e844-4014-9205-36923ab93f29'
UNION ALL
SELECT 'instrument_type', COUNT(*) FROM instrument_type WHERE input_id = 'a760fac9-e844-4014-9205-36923ab93f29'
UNION ALL
SELECT 'instrument_attribute', COUNT(*) FROM instrument_attribute WHERE input_id = 'a760fac9-e844-4014-9205-36923ab93f29'
UNION ALL
SELECT 'valuation', COUNT(*) FROM valuation WHERE input_id = 'a760fac9-e844-4014-9205-36923ab93f29'
UNION ALL
SELECT 'analytics', COUNT(*) FROM analytics WHERE input_id = 'a760fac9-e844-4014-9205-36923ab93f29';

\echo '=== same, for the sibling input_id 0ce6bb9e that DID get its ingestion_source row ==='
SELECT 'instrument_name' AS tbl, COUNT(*) FROM instrument_name WHERE input_id = '0ce6bb9e-9295-4754-b5d8-a4439a902ef7'
UNION ALL
SELECT 'instrument_identifier', COUNT(*) FROM instrument_identifier WHERE input_id = '0ce6bb9e-9295-4754-b5d8-a4439a902ef7'
UNION ALL
SELECT 'instrument_type', COUNT(*) FROM instrument_type WHERE input_id = '0ce6bb9e-9295-4754-b5d8-a4439a902ef7'
UNION ALL
SELECT 'instrument_attribute', COUNT(*) FROM instrument_attribute WHERE input_id = '0ce6bb9e-9295-4754-b5d8-a4439a902ef7'
UNION ALL
SELECT 'valuation', COUNT(*) FROM valuation WHERE input_id = '0ce6bb9e-9295-4754-b5d8-a4439a902ef7'
UNION ALL
SELECT 'analytics', COUNT(*) FROM analytics WHERE input_id = '0ce6bb9e-9295-4754-b5d8-a4439a902ef7';

\echo '=== re-confirm exact triple is still missing right now (pre-flight) ==='
SELECT * FROM instrument_ingestion_source
WHERE instrument_id = '05960b31-9968-44f4-9972-b3d7e7a9b539'
  AND ingestion_source_id = '493cbac1-4f40-4945-b810-67c250e8b36a'
  AND input_id = 'a760fac9-e844-4014-9205-36923ab93f29';
