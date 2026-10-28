-- Connection counts by database vs. max_connections.
-- Run via ./connect.sh <env-file> -f queries/connection_counts_by_db.sql

SELECT datname, count(*) AS connections
FROM pg_stat_activity
GROUP BY datname
ORDER BY connections DESC;

SHOW max_connections;
