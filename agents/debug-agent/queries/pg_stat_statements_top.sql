-- Top queries by total time and by call count (requires pg_stat_statements
-- extension enabled on this DB). Run via ./connect.sh <env-file> -f queries/pg_stat_statements_top.sql

SELECT
    userid::regrole AS role,
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
