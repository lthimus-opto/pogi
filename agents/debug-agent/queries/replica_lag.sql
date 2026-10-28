-- Replica lag, read-replica side. Run via ./connect.sh <env-file> -f queries/replica_lag.sql
-- against the REPLICA, not the writer -- pg_stat_replication (below) is run
-- on the writer instead and shows lag per connected replica.

-- On a replica:
SELECT now() - pg_last_xact_replay_timestamp() AS replica_lag;

-- On the writer, per connected replica:
-- SELECT application_name, client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
--        pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
-- FROM pg_stat_replication;
