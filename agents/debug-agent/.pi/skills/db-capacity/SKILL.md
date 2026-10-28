# DB Capacity

<!-- TODO: fill in real baseline numbers (max_connections, known-good IOPS
range, instance class headroom) once confirmed per cluster. Queries below
are standard Postgres/Aurora introspection — safe to run as-is (read-only). -->

## When to load this skill

Any question about connections, locks, slow queries, replica lag, or
sizing/capacity headroom.

## Connections

```sql
SELECT datname, count(*) AS connections, max(now() - query_start) AS longest_running
FROM pg_stat_activity
GROUP BY datname
ORDER BY connections DESC;
```

Compare against `max_connections`:

```sql
SHOW max_connections;
```

## Locks / blocking queries

```sql
SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query,
       blocking.pid AS blocking_pid, blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks kl ON kl.locktype = bl.locktype AND kl.database IS NOT DISTINCT FROM bl.database
  AND kl.relation IS NOT DISTINCT FROM bl.relation AND kl.pid != bl.pid AND kl.granted
JOIN pg_stat_activity blocking ON blocking.pid = kl.pid;
```

## Top queries by time/calls (requires `pg_stat_statements`)

See `./queries/pg_stat_statements_top.sql`.

## Replica lag

See `./queries/replica_lag.sql`.

## Table/index bloat

See `./queries/table_bloat.sql`. Compare against
`../../knowledge/capacity_baselines.md` for this cluster's known-good range.
