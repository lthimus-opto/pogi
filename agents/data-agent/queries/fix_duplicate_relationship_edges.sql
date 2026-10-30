-- Fixes the 4 confirmed same-source duplicate entity_relationship edges
-- found in queries/review_system_migration.sql's check #16. Unlike the
-- cross-source "duplicates" documented in knowledge/failure_modes.md's
-- `cross_source_eav_corroboration_is_not_a_duplicate` entry, these 4 were
-- individually verified: both rows in each pair share the SAME
-- ingestion_source_group_key ('security_master'), just asserted a few
-- days/months apart with a different input_id -- a genuine redundant
-- re-assertion by the same source, not independent corroboration.
--
-- Fix: for each (parent, child) pair, keep the row with the LATEST
-- valid_from (the most recent re-assertion), delete the earlier one.
-- No information is lost -- both rows carry an identical fact
-- (parent MANAGES child); only the earlier, superseded copy is removed.

BEGIN;

\echo '=== pre-check: all 8 rows across the 4 duplicate pairs ==='
SELECT relationship_id, parent_entity_id, child_entity_id, valid_from, input_id
FROM entity_relationship
WHERE relationship_id IN (
  '784dea63-9063-4a77-9837-e1408eb9861d', '01b55d43-1312-4baa-92f2-cd7a9f7087e5',
  '62d1c831-bba1-4888-9fec-ba6b4e3d6b55', '24f9013d-5a15-4f96-ad99-9c29d8369654',
  '58a9ce78-369e-4f3a-baa2-a7ac35c72bb2', 'c35be8f2-fd03-4b2f-800b-0f557d04798f',
  'e39eb26b-0edc-499d-92af-85308b901967', 'bfe81696-5736-492b-b85d-a73d538fce94'
)
ORDER BY parent_entity_id, child_entity_id, valid_from;

-- Delete the earlier (superseded) row from each pair.
DELETE FROM entity_relationship
WHERE relationship_id IN (
  '784dea63-9063-4a77-9837-e1408eb9861d',  -- 90c282a8... -> cbe4412e..., 2024-11-19 (superseded by 2025-04-17)
  '62d1c831-bba1-4888-9fec-ba6b4e3d6b55',  -- 90c282a8... -> d9d9ad26..., 2024-11-19 (superseded by 2025-04-17)
  '58a9ce78-369e-4f3a-baa2-a7ac35c72bb2',  -- e1204dcb... -> 09b6292c..., 2024-06-19 (superseded by 2024-06-21)
  'e39eb26b-0edc-499d-92af-85308b901967'   -- e39483db... -> 43c68a32..., 2023-04-10 (superseded by 2025-11-13)
);

\echo '=== post-check: each pair should now have exactly 1 row, the later valid_from ==='
SELECT parent_entity_id, child_entity_id, count(*) AS n_remaining, array_agg(valid_from) AS valid_froms
FROM entity_relationship
WHERE (parent_entity_id, child_entity_id) IN (
  ('90c282a8-6408-45a5-825e-b9e638803277','cbe4412e-e7e2-4ea1-9566-7b175b8eb206'),
  ('90c282a8-6408-45a5-825e-b9e638803277','d9d9ad26-297a-40dc-992a-e3d3da537a4a'),
  ('e1204dcb-70cb-43ec-a141-3063d15998ff','09b6292c-9e41-450c-b726-213478f9bdb6'),
  ('e39483db-523c-4534-b2c6-8e3eea9079c1','43c68a32-c0be-4fe9-9a76-106b18264510')
)
GROUP BY parent_entity_id, child_entity_id;

-- Each n_remaining must be exactly 1, with the later valid_from surviving
-- (2025-04-17 / 2025-04-17 / 2024-06-21 / 2025-11-13 respectively).
-- If that checks out:      COMMIT;
-- If anything looks off:   ROLLBACK;
