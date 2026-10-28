-- Snapshot of pg_stat_activity: who's connected, what they're running, how long.
-- Run via ./connect.sh <env-file> -f queries/pg_stat_activity_snapshot.sql

SELECT
    pid,
    datname,
    usename,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS running_for,
    query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY running_for DESC;
