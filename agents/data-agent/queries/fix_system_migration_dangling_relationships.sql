-- Fix for the 2 dangling-parent MANAGES edges found in the SYSTEM_MIGRATION
-- review. Verified against live data before writing this: the correct edge
-- already exists on the surviving manager entity, with the SAME input_id as
-- the stale copy on the abandoned (ATTACH-merged-away) shell entity:
--
--   shell a2cccfec-4a19-4e74-bdea-1b3e2ea0c234 -> child 0ee2beee-...
--     duplicate of: 1af4bda5-26d8-4667-840f-6327e9bb8549 -> 0ee2beee-...
--     both rows carry input_id 55c592ba-b116-400b-9259-9e3a38b10e62
--
--   shell 9d0f112e-5cab-44a9-8e53-c9bf28ca5e9b -> child 9e52a052-...
--     duplicate of: 934d732b-92d9-40e0-804c-431e438f435c -> 9e52a052-...
--     both rows carry input_id 426a388b-6e22-44aa-a386-1de0b5a08e38
--
-- So this is NOT a "relationship never got moved" case -- it's a stale
-- leftover never cleaned up after the correct edge was independently
-- created on the surviving entity. The fix is a plain DELETE of the two
-- shell-side rows, no INSERT (an INSERT would have created an exact
-- duplicate on the surviving entity -- confirmed by comparing input_id).

BEGIN;

-- Pre-check: should show exactly these 2 rows, both parent = the shell.
SELECT relationship_id, parent_entity_id, child_entity_id, relationship_type, valid_from, input_id, ingestion_source_id
FROM entity_relationship
WHERE relationship_id IN (
  '43463f6d-c73a-40db-8ccd-0bdff269a979',  -- a2cccfec... -> 0ee2beee...
  'd7fe02ad-79e0-487d-b515-ebc020706508'   -- 9d0f112e...  -> 9e52a052...
);

-- Confirm the surviving-entity row we're keeping already exists and matches
-- (parent/child/type/input_id) before deleting the stale one.
SELECT relationship_id, parent_entity_id, child_entity_id, relationship_type, valid_from, input_id, ingestion_source_id
FROM entity_relationship
WHERE relationship_id IN (
  'ed111ea8-adfd-46f4-b648-35e2dbaabf65',  -- 1af4bda5... -> 0ee2beee...  (kept)
  '22130c33-6a26-4f25-ad9c-3bbe3c030df4'   -- 934d732b... -> 9e52a052...  (kept)
);

DELETE FROM entity_relationship
WHERE relationship_id IN (
  '43463f6d-c73a-40db-8ccd-0bdff269a979',
  'd7fe02ad-79e0-487d-b515-ebc020706508'
);

-- Post-check: both should now show 0 relationship rows at all for the shells.
SELECT
  (SELECT count(*) FROM entity_relationship WHERE parent_entity_id = 'a2cccfec-4a19-4e74-bdea-1b3e2ea0c234' OR child_entity_id = 'a2cccfec-4a19-4e74-bdea-1b3e2ea0c234') AS remaining_on_shell_1,
  (SELECT count(*) FROM entity_relationship WHERE parent_entity_id = '9d0f112e-5cab-44a9-8e53-c9bf28ca5e9b' OR child_entity_id = '9d0f112e-5cab-44a9-8e53-c9bf28ca5e9b') AS remaining_on_shell_2,
  -- and the surviving entities' edges to the same children are untouched / still exactly 1 each
  (SELECT count(*) FROM entity_relationship WHERE parent_entity_id = '1af4bda5-26d8-4667-840f-6327e9bb8549' AND child_entity_id = '0ee2beee-ef92-451f-9228-0b977820a14d' AND relationship_type = 'MANAGES') AS survivor_1_edge_count,
  (SELECT count(*) FROM entity_relationship WHERE parent_entity_id = '934d732b-92d9-40e0-804c-431e438f435c' AND child_entity_id = '9e52a052-16bc-4835-974c-0fd380f9c190' AND relationship_type = 'MANAGES') AS survivor_2_edge_count;

-- Both survivor_*_edge_count should read exactly 1 (not 0, not 2).
-- If that's what you see:      COMMIT;
-- If anything looks off:       ROLLBACK;
