# Runbook: investigating an atlas-service / Aurora latency or timeout incident

Command-line reference for diagnosing a slow or timed-out request against
atlas-service's Aurora Postgres cluster. No conclusions below — run the
commands, read the output, decide what it means. Each section is a separate
question; you don't have to run them in order, but 1-3 before 4+ usually
saves time (don't guess at a mechanism before you've located the actual
request and its duration).

## Prerequisites

```bash
# Postgres access (read-only, IAM auth, hits the reader endpoint)
cd /Users/lucieoptoinvest/workspace/code/worktrees/pi-getting-started/data-agent
./connect.sh .env.atlas.prod -c "SOME SQL;"

# AWS CLI, prod account
aws --profile prod --region us-east-2 <command>

# Cluster / instance identifiers (atlas-service prod)
CLUSTER=rds-o7bwv4afco7kvnombvc3djgjq-twgfxdjpd18u
WRITER=rds-vkxyxdfairzjj036djhg1fzm2-cdserr5ywmhn

# Relevant log groups
#   /aws/service-events/atlas-service        — per-request incident snapshots, latency/error triggers
#   /eks/prod/atlas-service                  — app logs, all pods (uvicorn access, httpx/Bedrock calls, app warnings)
#   /aws/rds/cluster/$CLUSTER/postgresql     — Postgres server log (only useful if logging GUCs below are on)
#   aws/spans                                — CloudWatch Application Signals / Transaction Search span data (only has data if the trace was sampled)
```

**Gotcha — epoch math.** `aws logs start-query` takes Unix epoch seconds, and
it's very easy to get UTC-vs-local or wrong-day wrong. Always compute both
ends explicitly and echo them back in human-readable form before trusting
them:

```bash
START=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "2026-10-28T13:50:00" "+%s")   # macOS
END=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "2026-10-28T13:58:00" "+%s")
echo "start: $(date -u -r $START)   end: $(date -u -r $END)"             # sanity check
```

## 1. Find the incident in the request-latency log

```bash
aws logs start-query --profile prod --region us-east-2 \
  --log-group-name /aws/service-events/atlas-service \
  --start-time $START --end-time $END \
  --query-string 'fields @timestamp, @message
    | filter @message like /internal\/entities/
    | sort @timestamp asc | limit 200'

# poll for results (queries are async)
aws logs get-query-results --profile prod --region us-east-2 --query-id <id>
```

Parse each matching log line as JSON. Two different message shapes appear in
this log group — don't confuse them:

- `"Incident snapshot triggered: <route> (status=<code>, trigger=<type>)"` —
  fired **at the moment the request actually completes**. This is the one
  with the real timestamp you want.
- `"Exported N incident snapshots"` — a periodic batch flush (observed every
  ~3 minutes), unrelated to any single request's timing. Don't use its
  timestamp as if it were when a request finished.

The full JSON payload of a triggered snapshot carries the real numbers:

```json
"attributes": {
  "aws.service_events.duration_ms": 189826.86,
  "aws.service_events.trigger_type": "latency",
  "http.response.status_code": 201,
  "aws.service_events.operation": "POST /internal/entities"
}
```

**Gotcha — computing the request's start time.** `duration_ms` is measured
back from when the response was sent, i.e. from the `"Incident snapshot
triggered"` log line's own timestamp (or the `request_context.timestamp`
field inside the payload, in epoch ms) — not from the "Exported N incident
snapshots" flush timestamp, which can be several seconds to minutes later.

```python
response_time = ...   # the "Incident snapshot triggered" log's own timestamp, or request_context.timestamp
start_time = response_time - duration_ms / 1000
```

## 2. Pull Aurora capacity metrics for that window

```bash
aws cloudwatch get-metric-data --profile prod --region us-east-2 \
  --start-time 2026-10-28T13:40:00Z --end-time 2026-10-28T14:00:00Z \
  --cli-input-json '{
    "StartTime":"2026-10-28T13:40:00Z","EndTime":"2026-10-28T14:00:00Z",
    "MetricDataQueries":[
      {"Id":"acu","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"ServerlessDatabaseCapacity","Dimensions":[{"Name":"DBClusterIdentifier","Value":"'$CLUSTER'"}]},"Period":60,"Stat":"Average"}},
      {"Id":"cpu","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"CPUUtilization","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'$WRITER'"}]},"Period":60,"Stat":"Average"}},
      {"Id":"conns","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"DatabaseConnections","Dimensions":[{"Name":"DBClusterIdentifier","Value":"'$CLUSTER'"}]},"Period":60,"Stat":"Average"}},
      {"Id":"dqd","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"DiskQueueDepth","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'$WRITER'"}]},"Period":60,"Stat":"Average"}},
      {"Id":"deadlocks","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"Deadlocks","Dimensions":[{"Name":"DBClusterIdentifier","Value":"'$CLUSTER'"}]},"Period":60,"Stat":"Sum"}}
    ]
  }' --query 'MetricDataResults[].{id:Id,ts:Timestamps,vals:Values}'
```

What each tells you:
- `ServerlessDatabaseCapacity` — current ACU. Compare against the configured
  `MinCapacity`/`MaxCapacity` (below) to see if it was near a floor, climbing,
  or already pinned at max.
- `CPUUtilization` — near-idle CPU alongside slowness points away from a
  compute-bound cause; high CPU points toward one.
- `DatabaseConnections` — a jump here around the incident suggests concurrent
  requests piling on, not a single slow session.
- `DiskQueueDepth` — nonzero means storage I/O is actually queuing;
  consistently zero rules out raw disk contention as the bottleneck (doesn't
  rule out buffer-cache eviction — that's a different signal, see §4).
- `Deadlocks` — nonzero is a definitive deadlock; zero across the whole window
  rules deadlocks out completely, regardless of how "lock-like" the symptom
  looks otherwise.

## 3. Check the cluster's current capacity configuration

```bash
aws rds describe-db-clusters --profile prod --region us-east-2 \
  --db-cluster-identifier $CLUSTER \
  --query 'DBClusters[0].{ServerlessV2ScalingConfiguration:ServerlessV2ScalingConfiguration,EngineVersion:EngineVersion}'
```

## 4. Check Postgres-side memory/logging configuration right now

```bash
cd /Users/lucieoptoinvest/workspace/code/worktrees/pi-getting-started/data-agent
for setting in shared_buffers max_connections log_lock_waits log_min_duration_statement log_autovacuum_min_duration deadlock_timeout; do
  echo "=== $setting ==="
  ./connect.sh .env.atlas.prod -c "SHOW $setting;"
done
```

- `shared_buffers` is reported in 8KB pages. Multiply by 8192 for bytes. On
  Aurora Serverless v2 this value is set dynamically by Aurora based on
  *current* ACU — if it looks low, check current ACU (§2/§3), don't assume
  something's misconfigured.
- If `log_min_duration_statement = -1` and `log_lock_waits = off`, the
  Postgres server log will **not** capture slow queries or lock waits even if
  they're happening — a silent log in `/aws/rds/cluster/.../postgresql`
  during an incident means "not logged," not "nothing happened."

## 5. Rule out (or confirm) locks directly

```bash
# Historical: only the Deadlocks CloudWatch metric (§2) is retroactive.
# Live: this only shows what's happening right now, not during a past incident.
./connect.sh .env.atlas.prod -c "
SELECT pid, usename, state, wait_event_type, wait_event, query_start,
       now()-query_start AS running_for, left(query,120) AS query
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY query_start ASC LIMIT 30;
"
```

## 6. Cross-reference application logs for the same window, across all pods

```bash
aws logs start-query --profile prod --region us-east-2 \
  --log-group-name /eks/prod/atlas-service \
  --start-time $START --end-time $END \
  --query-string 'fields @timestamp, @message
    | filter @message like /WARN/ or @message like /ERROR/ or @message like /pool/
      or @message like /timeout/ or @message like /retry/ or @message like /throttl/
    | sort @timestamp asc | limit 200'
```

Also worth a broad, unfiltered pull of the same window/pod to see what *was*
happening (outbound Bedrock calls via the `httpx`/`httpx2` loggers, uvicorn
access lines, etc.) even if nothing matched the filter above — absence of
WARN/ERROR doesn't mean absence of a problem if the relevant Postgres logging
GUCs are off (§4).

## 7. Size the tables/indexes behind the slow endpoint

```bash
./connect.sh .env.atlas.prod -c "
SELECT pg_relation_size('<index_name>') AS index_bytes;
SELECT pg_relation_size('<table_name>') AS heap_bytes;
SELECT pg_total_relation_size('<table_name>') AS total_bytes;  -- heap + TOAST + all indexes
SELECT c.reltoastrelid::regclass AS toast_table, pg_relation_size(c.reltoastrelid) AS toast_bytes
FROM pg_class c WHERE c.relname = '<table_name>';
"
```

Rule of thumb: for any column storing values over ~2KB (vectors, large text),
assume there's a second, often similarly-sized, copy of that data in TOAST —
`pg_relation_size` on the table alone will look deceptively small.

## 8. Check the actual query plan, not just row counts

```bash
./connect.sh .env.atlas.prod -c "
EXPLAIN (ANALYZE, BUFFERS) <the real query, with a real parameter value>;
"
```

Read the `Buffers:` line — `shared hit=` is served from cache, `shared
read=` had to come from storage. `I/O Timings: shared read=...` tells you how
much of total execution time was disk wait vs compute. A plan using the index
you expect (`Index Scan`/`Bitmap Index Scan` on the index you expect) but
still slow and read-heavy points at a cache-fit problem. A plan that *skips*
the index you expect (`Seq Scan` where you expected an index) is a planning
problem, not a capacity problem — check whether the query uses a bind
parameter for `LIMIT` or has a join/subquery that could make the planner
under/over-estimate selectivity, especially if it runs through a prepared
statement — Postgres (via asyncpg and similar drivers) switches from a
per-call "custom plan" to a reused "generic plan" after the 5th execution of
the same prepared statement on a connection, and a generic plan can lose
information the custom plan had. Reproduce this specifically with:

```sql
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE, BUFFERS) <same query>;
```

If the plan changes for the worse under `force_generic_plan`, you've found a
prepared-statement-plan regression, independent of data size or cache state.

## 9. Performance Insights (if the IAM role has `pi:GetResourceMetrics`)

Check first — it may not be granted. If it is: open the instance in the RDS
console → Performance Insights → Top SQL, for the incident time window. Look
at the wait-event breakdown, not just CPU:
- `IPC:BufferIo` / similar — waiting on another session's in-flight page read
  from storage. CPU low + this wait dominant = cache/memory-bound, not
  compute-bound.
- High CPU, low I/O wait = compute-bound (expensive query logic, not memory).
PI also gives per-query average buffer touches — compare against what the
query *should* need (an index-based lookup should touch a small, roughly
constant number of pages regardless of table size; a number that scales with
table size, or that's wildly higher than the query's own `EXPLAIN` buffer
count, suggests the live traffic isn't taking the plan you tested manually).

## 10. Correlate against what the request actually contained

If the slow endpoint writes an audit/staging table (check for one — e.g. a
`*_staging` table recording every candidate considered during matching),
query it for rows at the exact timestamp from §1. Rows sharing an identical
microsecond timestamp were committed in the same transaction — useful for
telling "one big request" apart from "several unrelated things that happened
to finish close together."

```sql
SELECT *
FROM <staging_table>
WHERE recorded_at = '<exact timestamp from the trigger event>';
```

## 11. Verifying a fix (before/after)

Re-run the same three checks before and after any change (capacity, index,
query), against the same real query/data where possible:
1. `SHOW shared_buffers;` — did available memory actually change?
2. The `EXPLAIN (ANALYZE, BUFFERS)` from §8 — did the hit/read ratio and plan
   actually change, not just the config?
3. Real traffic — pull §1's log query again for the same endpoint over the
   following hours/days: did `trigger_type=latency` events for it stop or
   shrink in duration?

Don't treat (1) alone as proof — a setting can change without the underlying
query behavior changing (e.g. if the real problem was a plan bug, not a
memory ceiling).
