BEGIN;

CREATE TEMP TABLE _correction_ids AS
SELECT '3e56b304-5a13-4302-9904-7cde96cf5000'::uuid AS old_id,
       'cf8bc531-069a-4ff3-a981-c1e05e0bb984'::uuid AS new_id;

-- Pre-check: should show N rows, all parent_entity_id = the old entity.
SELECT er.relationship_id, er.child_entity_id, er.relationship_type, er.valid_from, er.input_id
FROM entity_relationship er, _correction_ids c
WHERE er.parent_entity_id = c.old_id;

INSERT INTO entity_relationship
(parent_entity_id, child_entity_id, relationship_type, valid_from, valid_to,
 ingestion_source_id, ingestion_source_group_key, input_id)
SELECT
    c.new_id, er.child_entity_id, er.relationship_type,
    er.valid_from, er.valid_to, er.ingestion_source_id, er.ingestion_source_group_key, er.input_id
FROM entity_relationship er, _correction_ids c
WHERE er.parent_entity_id = c.old_id;

DELETE FROM entity_relationship er
USING _correction_ids c
WHERE er.parent_entity_id = c.old_id;

-- Post-check: old entity should have 0, new entity should have its
-- pre-existing edges + the moved ones.
SELECT
    (SELECT count(*) FROM entity_relationship er, _correction_ids c WHERE er.parent_entity_id = c.old_id) AS remaining_on_old,
    (SELECT count(*) FROM entity_relationship er, _correction_ids c WHERE er.parent_entity_id = c.new_id) AS total_on_new;

SELECT er.relationship_id, er.child_entity_id, er.relationship_type, er.valid_from, er.input_id
FROM entity_relationship er, _correction_ids c
WHERE er.parent_entity_id = c.new_id;

-- Review, then COMMIT; or ROLLBACK;

COMMIT;
