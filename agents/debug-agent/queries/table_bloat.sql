-- Approximate table bloat (dead tuples vs. live, and table size).
-- Run via ./connect.sh <env-file> -f queries/table_bloat.sql
-- Compare against knowledge/capacity_baselines.md for this cluster's
-- known-good range -- some bloat is normal, this flags outliers.

SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / greatest(n_live_tup + n_dead_tup, 1), 1) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 30;
