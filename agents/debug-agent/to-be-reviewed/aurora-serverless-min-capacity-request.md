# Request — raise Aurora Serverless v2 MinCapacity for the atlas-service DB cluster

## Problem

`/internal/entities` has intermittently timed out (ALB 504) during entity-resolution
batches — most recently twice 10/26 (`00:34 UTC`, release `1.82.0`, 191.6s;
`02:20 UTC`, release `1.83.0`, 184.9s), both succeeding server-side (`201`) well
after the ALB gave up waiting.

## Root cause

Using opto-cloud-skill, the intern did some research:

The database is Aurora Serverless v2, which continuously scales its compute
capacity (measured in ACUs — Aurora Capacity Units) up and down based on
recent load, to avoid paying for idle capacity. That scaling is reactive, not
instant: if demand jumps while the engine is sitting at a low ACU level, the
new work has to wait while the engine provisions more capacity.

That's what happened here. A single `/internal/entities` request resolves a
batch of entities, and each entity independently runs several DB-bound match
strategies concurrently (trigram similarity, soundex, embedding lookup, exact
match) — for this batch, ~10 entities × up to 6 strategies each. All of that
work lands on the database at once. It arrived right after the engine had
scaled down for a quiet period, so for a few minutes the batch had to wait
for ACU capacity to catch up before the backlog could clear.

Confirmed via CloudWatch metrics on `rds-vkxyxdfairzjj036djhg1fzm2-cdserr5ywmhn`
(cluster `rds-o7bwv4afco7kvnombvc3djgjq-twgfxdjpd18u`):

| Metric | What it measures | Just before (19:15–19:16 PDT) | During incident (19:17–19:20 PDT) |
|---|---|---|---|
| `ServerlessDatabaseCapacity` (ACU) | Compute capacity currently provisioned by Aurora Serverless v2 | scaled down to 2.0–2.1 | spiked to 4.5, i.e. the engine scaling up mid-request |
| `CPUUtilization` | % of the *currently provisioned* capacity in use | ~7% (near idle) | ~35–40% — real, heavy compute demand hitting right as capacity was low |
| `DatabaseConnections` | Open connections to the database | ~100 | ~120, a jump of ~20 — matches ~10 entities each opening several short-lived connections for their own match strategies |
| `DiskQueueDepth` | I/O operations waiting on storage | 0 | 0 — rules out disk/storage as the bottleneck |

Read together: CPU and connections rising while disk stays flat, in lockstep
with the ACU level itself rising, is the specific signature of a compute
capacity problem — not a slow query, not a lock, not storage I/O. If it were
a slow query or lock wait, we'd expect individual records to finish on their
own staggered schedule; instead all ~10 records in the batch were released
within the same couple of seconds (02:19:59–02:20:01), consistent with
everyone waiting on the same shared resource (capacity) and getting it back
at the same time once the engine finished scaling up.

The cluster's current `ServerlessV2ScalingConfiguration` is `MinCapacity=0.5,
MaxCapacity=8.0` — low enough that the engine can scale all the way down to
0.5 ACU during quiet periods, well below what even one burst like this one
needs (peaked at 4.5 ACU). That gap between "idle floor" and "normal burst
size" is what causes the scaling-lag.

## Ask

Raise `MinCapacity` from `0.5` to **2.0–4.0 ACU** so the floor never drops below
what a normal burst needs. This is a config-only change — no application code
involved, no change to matching/business logic. Trade-off is a modest increase
in baseline Aurora compute cost during idle periods.

## Why this matters now — recent related work on our end

- `#96 "Time for a boost for entity resolution"` (Oct 23) — already mitigated an
  earlier round of this same 504 symptom (capped LLM candidates, parallelized
  attribute fetches, made each record resolve independently instead of
  batch-staged). Despite that fix, the ACU-floor gap above still causes it under
  the right burst pattern.
- `#104 "Deadlock + anthropic issue"` / `#105 "Bump helpers to latest"` (today) —
  separate issue, fixed a Bedrock API-version mismatch and a Postgres deadlock
  on bulk inserts. Unrelated to this latency issue, but same subsystem, same
  night.
- Not yet adopted: `opto-python-helpers 0.0.347+` added a `Haiku 5.5` model
  option. Atlas-service still uses Haiku 4.5 for LLM candidate assessment. Not
  confirmed to be faster, and more importantly it wouldn't fix *this* incident —
  our evidence places the delay entirely in the DB-bound matching phase, before
  the Bedrock/LLM call ever starts. Worth evaluating separately, not a
  substitute for the ACU fix.

## Secondary ask (optional)

We currently have no `pg_stat_statements` and no PI (`pi:GetResourceMetrics`)
access for engineers debugging this class of issue — enabling one or both would
make future incidents much faster to diagnose.
