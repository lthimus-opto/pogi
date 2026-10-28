# Investigation — entity-embedding HNSW index, Aurora Serverless v2 memory, and `/internal/entities` 504s

Companion to `aurora-serverless-min-capacity-request.md`. That doc covers an earlier
10/26 incident attributed to compute/ACU scaling lag. This doc covers a separate
10/27 incident traced in detail, which points to a different (though related)
mechanism: the vector-embedding HNSW index not fitting in the Aurora Serverless v2
buffer cache. See "Open discrepancy" at the end — the two docs may describe two
distinct contributing failure modes, not fully reconciled yet.

## The incident traced

Request on pod `atlas-service-785557fb95-dxz9m`, trace
`6ae0f190efc06f741431bb1a46f7154e`:

- Started: `2026-10-27 18:46:40 UTC` (approx, from `duration_ms` back-calculated from
  the trigger log)
- ALB returned 504 to caller: `18:47:40 UTC` (per HTTP response `date` header) — 60s
  in, matching ALB idle timeout
- Backend finished: `18:49:52.985 UTC`, **status 201** — the write succeeded, ~2.5
  minutes after the caller had already seen a failure
- `duration_ms = 189826.86` (189.8s total)

The request was a batch create: a "Tacora Capital" parent entity
(`bc38be5a-b25e-4536-8577-82d5163de15d`) plus 4 child fund vehicles (Fund I, Fund II,
"Tacora Project Wasatch Co-Investment", "Tacora Capital Residential RE Financing
Opportunities (TACREIT)"). All 4 children ran all 6 match strategies concurrently
(`asyncio.gather`, confirmed in code and in `resolution_staging` data):
`EXACT_IDENTIFIER_MATCH`, `EXACT_SILVER_IDENTIFIER_MATCH`, `EXACT_NAME_MATCH`,
`TRIGRAM_SIMILARITY_MATCH` (10 candidates each), `SOUNDEX_MATCH` (10 each),
`EMBEDDING` (10 each).

Timeline within the request:
- `18:46:40.5–40.68` — 4 Bedrock embedding calls complete fast (~180ms total)
- `18:46:41 → 18:49:37.8` — **~176s, nothing logged anywhere** (no DB query logs, no
  app WARN/ERROR, no Bedrock calls) — this is the embedding/candidate-search phase
- `18:49:37.8–39.48` — 4 Claude Haiku tiebreaker calls, back-to-back, ~1.65s total
- `18:49:46.23` — one transaction commits all 4 resolutions + 132 candidate-comparison
  audit rows (`resolution_staging`), confirmed via identical microsecond timestamp
- `18:49:49.9` — response sent, 201

## What was ruled out

- **Deadlock**: `Deadlocks` CloudWatch metric = 0 for the entire window. Definitively
  not a deadlock.
- **Connection exhaustion**: `max_connections = 1710`; observed connections peaked
  ~118. Nowhere close.
- **App-level error/retry/throttle**: grepped all pods, all log levels, zero matches
  for WARN/ERROR/pool/timeout/retry/throttle during the stall window.
- **LLM latency**: the actual Bedrock/Claude calls took 1.65s combined and only ran
  in the last ~15s of a 190s request.
- **Trigram query as primary cause**: initially suspected (an existing unmerged
  branch, `lucie/trigram-latency`, documents a real trigram/GIN-index pathology for
  short/generic names). Directly reproduced it ("Tacora Capital Fund II" → 68,307 GIN
  candidates, 54ms solo/warm-cache) — real, but minor. A colleague's Performance
  Insights analysis across 7 known slow requests found the trigram query accounts for
  only **~2%** of DB time; the embedding query accounts for **~95%**.
- **Postgres log visibility**: both `log_lock_waits` and `log_min_duration_statement`
  are disabled on this cluster, so slow queries/lock waits produce zero log evidence
  even when they occur — this is a blind spot in the current setup, not evidence of
  "nothing happening."

## Root cause: HNSW index + TOAST working set doesn't fit in the Serverless v2 buffer cache

Performance Insights (PI) access, newly granted to the eng IAM role, showed the
dominant wait across these incidents is `IPC:BufferIo` — sessions waiting on another
session's in-flight page read from storage — with CPU near idle. Each call to the
embedding-match query (`query_entities_by_embedding`,
`app/app/resolution/strategies/embedding_match/embedding_match_store.py`) was
observed averaging ~1.5M buffer touches to return 10 rows; an HNSW index should only
need a few thousand.

Measured directly against the database:

| Item | Size |
|---|---|
| `entity_embedding_embedding_hnsw_idx` (HNSW index) | 2,013,093,888 bytes = 1.875 GiB |
| TOAST table for `entity_embedding` (`pg_toast_440323`) | 2,039,971,840 bytes = 1.90 GiB |
| `entity_embedding` heap (excl. TOAST/index) | 42,041,344 bytes |
| `pg_total_relation_size('entity_embedding')` | 4,172,709,888 bytes = 3.89 GiB |
| Row count | 247,603 (100% `is_active`, 100% `embedding_type='NAME'`) |

The index alone is "one page per vector" — 245,747 pages for 247,603 rows, no bloat.
But the **working set relevant to these queries is the index plus the TOAST copy of
the same vector data** (Postgres TOASTs any value over ~2KB; these 1536-dim float32
vectors are ~6KB each), because the query joins back to the base table for
`entity_id`/`source_text`. That's **~3.9 GiB**, not the ~1.9 GiB figure the index size
alone suggests.

Against that, `shared_buffers` (Aurora's buffer cache, dynamically resized by Aurora
based on *current* ACU, confirmed in AWS docs — see references) was observed at
**128 MB** (16,384 × 8KB pages) while the cluster sat at 0.5–3 ACU, which is this
cluster's normal operating range (`MinCapacity=0.5, MaxCapacity=8.0`). ~3.9 GiB needed
vs. ~128 MB available is the mismatch. Every query that can't get what it needs from
cache has to round-trip to Aurora's network-attached storage; under concurrent load
(this request ran the embedding strategy 4x simultaneously), those round trips queue
behind each other — that's the `IPC:BufferIo` wait, and plausibly how a sub-second
query (confirmed via `EXPLAIN ANALYZE` in prod: 888ms, 93% of which was I/O wait, even
running solo) compounds into a 176s stall under concurrency and a colder cache.

## Why 10/23 specifically

Incident frequency jumped from 1–3/day to 16 on 10/23, correlating with entity-
creation volume (1–2/day → 18, then 20, then 12 through 10/26–27) — not with table
size (`entity_embedding` only grew by 42 rows that day, 0.017% of the table). This is
a concurrency/volume story, not a "table hit some ceiling" story. Likely tied to
ramp-up of the pending data migration, not yet confirmed directly with Platform/the
onboarding team.

## Fixes

**1. Raise `MinCapacity`.** Original ask (`aurora-serverless-min-capacity-request.md`)
proposed 2.0–4.0 ACU based on a different incident's profile. Given the working set
is actually ~3.9 GiB (not ~1.9 GiB), and AWS's own worked example shows
`shared_buffers` reaching only ~10.9 GiB at 8 ACU (no published data point at 4 ACU),
**4 ACU minimum, 8 for headroom** is the better-supported target — needs to be
updated in the pending request before it goes to Platform.

**2. `halfvec` migration.** Code drafted, not yet run or committed — in worktree
`/Users/lucieoptoinvest/workspace/code/worktrees/halfvec-embeddings`, branch
`lucie/halfvec-embeddings`:
- `app/db_schema/entity_embedding_db_schema.py`, `instrument_embedding_db_schema.py`:
  `Vector(1536)` → `HALFVEC(1536)`, index ops → `halfvec_cosine_ops`
- `app/app/resolution/strategies/embedding_match/embedding_match_store.py`: both
  query-side casts updated to match
- New migration `2221a237e355` (alembic head, revises `821f14ffb798`): `ALTER COLUMN
  ... TYPE halfvec(1536) USING embedding::halfvec(1536)`, drop/recreate the HNSW
  index with `halfvec_cosine_ops`, symmetric downgrade. Verified the `vector →
  halfvec` cast works against real prod data; confirmed prod pgvector is `0.8.0`
  (halfvec supported since `0.7.0`); ruff/type-check clean; no other `Vector(1536)`
  usages found in the app beyond what was changed.
- Expected effect: roughly halves both the index and the TOAST copy (~3.9 GiB → ~2
  GiB working set). Negligible recall impact (float16 precision loss doesn't affect
  nearest-neighbor ranking at this use case's resolution).
- Not yet run anywhere, including dev. `ALTER COLUMN TYPE` rewrites the whole table
  and the index rebuild takes real time/locks — needs a deliberate window, and
  `maintenance_work_mem` should be raised for the rebuild step specifically.

**3. `trigram-latency` branch** (`9a16dca`, already written, not merged): adds a 5s
`statement_timeout` to the trigram query (falls back to "no match" instead of
blocking) and `logger.warning` for any match-strategy call ≥1s. Worth merging
regardless — minor contributor to this specific incident class, but it's the only
thing in the whole resolution path that currently has any timeout/visibility at all,
and it directly closes the "174s of total silence in the logs" blind spot for next
time.

## Considered and rejected: moving off pgvector/Aurora to a dedicated vector store

Platform raised whether a 250K-row / ~4GB-of-index workload is simply the wrong fit
for Postgres, suggesting S3 Vectors or a DynamoDB-based vector store instead.
Conclusion: not warranted given current evidence.

- pgvector's own docs frame capacity entirely in terms of memory fit, never row
  count — "No, but like other index types, you'll likely see better performance if
  [indexes] fit in memory" (pgvector README FAQ). No documented ceiling this
  workload is near.
- The "doesn't scale up fast enough" symptom has a specific documented cause: Aurora
  Serverless v2 ACU adjustment itself is fast, but refilling an *evicted* cache from
  storage is slow — AWS's own docs: "If the amount of I/O to bring the data back into
  the buffer cache is substantial, it might be more effective to choose a higher
  minimum ACU value." Setting MinCapacity above the working-set threshold prevents
  eviction in the first place, which eliminates the "catching up" dynamic entirely —
  this isn't a workaround, it's AWS's stated design intent for this exact scenario.
- Splitting embeddings into a separate vector store (S3 Vectors/DynamoDB) trades a
  single transactionally-consistent system for a dual-write consistency problem
  (entity create/update/delete now has to succeed in two systems), with no confirmed
  latency win for this specific access pattern (small, frequent, synchronous top-10
  lookups inside a user-facing request) — S3-backed vector search is optimized for
  cost-efficient storage at scale, not sub-request latency.
- AWS's own Bedrock Knowledge Bases "quick create" blog post officially packages
  Aurora Serverless + pgvector + HNSW as a first-party-recommended vector store
  pattern — reinforcing it's not an unsupported combination. (That post is a
  getting-started tutorial and is silent on capacity planning — it doesn't
  contradict the MinCapacity guidance, it just doesn't address that question at all.)

## Open discrepancy — not yet reconciled

`aurora-serverless-min-capacity-request.md` attributes its 10/26 incident to a
CPU-bound compute-scaling-lag mechanism (CPU 35–40%, `DatabaseConnections` +20,
written without PI access). This investigation's 10/27 incident, and the PI-based
breakdown for "7 slow requests" generally, point to an I/O/memory-bound mechanism
(CPU near idle, `IPC:BufferIo` dominant wait). These may be two distinct failure
modes that both happen to be mitigated by the same fix (raise MinCapacity), or the
original doc's CPU read may need re-examination now that PI access exists. Worth
running the original doc's incident timestamps through PI before finalizing the
MinCapacity ask number.

## Reference documentation (verified by reading, not recalled)

1. [Aurora Serverless v2 — How it works](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.how-it-works.html)
   — "Aurora serverless capacity": ACU ≈ 2 GiB memory each.
2. [Aurora Serverless v2 — Performance and scaling](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.setting-capacity.html)
   — `shared_buffers` is dynamically resized by Aurora based on current ACU
   (confirmed: "Aurora serverless resizes the following parameter dynamically during
   scaling... `shared_buffers`"); worked example shows 16,384 pages (128MB) at 0.5
   ACU idle, matching this cluster exactly; "Choosing the minimum Aurora serverless
   capacity setting" section is the direct playbook for this symptom.
3. [pgvector README](https://github.com/pgvector/pgvector) — the project's only
   documentation; frames all capacity guidance around memory fit, not row count;
   recommends `halfvec`, binary quantization, and "scale vertically" as the standard
   levers.
4. [PostgreSQL docs — Storage: TOAST](https://www.postgresql.org/docs/current/storage-toast.html)
   — values over ~2KB (`TOAST_TUPLE_THRESHOLD`) get moved to a separate TOAST table;
   explains the second ~1.9 GiB copy of the vector data.
5. [AWS blog — Bedrock Knowledge Bases quick create with Aurora Serverless](https://aws.amazon.com/blogs/database/accelerate-your-generative-ai-application-development-with-amazon-bedrock-knowledge-bases-quick-create-and-amazon-aurora-serverless/)
   — confirms Aurora Serverless + pgvector + HNSW is an AWS-endorsed pattern; silent
   on capacity planning (different scope, not a contradiction).
