# Debug Agent — Vision & Context

**What "the agent" means here:** a tool for digging into infra/data
questions fast — CloudWatch logs/metrics plus live DB introspection
(connections, locks, query stats, replica lag, capacity headroom) against
the shared Aurora cluster. Unlike `data-agent`, this is primarily an
**interactive** tool (a human asks a question, the agent digs and
reports back) — the non-interactive "general sweep" mode exists for
scheduled health checks, but the main use case is ad-hoc debugging.

## Context

The same Aurora cluster backs Security Master, Atlas, and Invest
(`data-agent`'s sources). When something's slow, erroring, or the DB
looks unhealthy, the debugging loop today is manual: separately check
CloudWatch, separately run `psql` queries, mentally cross-reference. This
agent automates that cross-referencing — given a question or symptom, it
pulls the relevant CloudWatch signal and the relevant live DB state for
the same time window, and reports a root cause with evidence (or says
plainly what it couldn't confirm).

It is **read-only** against everything — CloudWatch by nature, the DB via
the same `connect.sh` read-only reader-role pattern `data-agent` uses.
This agent diagnoses; it never fixes.

## Use Case

Same Aurora cluster, same three databases as `data-agent`
(`security_master`, `atlas`, `invest`). First real use cases:
- "Why did connections spike / queries get slow at time X?"
- "Is this table/index bloated beyond what's normal for it?"
- "Are we close to a capacity ceiling (connections, IOPS, CPU) that would
  explain intermittent slowness?"

## Approach

Same bootstrapping discipline as `data-agent`: start by just answering
real questions by hand (via this agent) as they come up, and feed what's
learned back into `knowledge/capacity_baselines.md` (known-good ranges
per metric) and `knowledge/failure_modes.md` (catalogued incident
signatures) as real investigations confirm them. Nothing in those files
should be hypothetical — same rule as `data-agent`.

## Where This Is Headed

Once `knowledge/failure_modes.md` has enough catalogued incidents that
most new questions match something already seen, the non-interactive
"general sweep" mode becomes useful as a scheduled health check (cron) —
flagging anything outside baseline before a human asks about it, the same
relationship `data-agent`'s `project/roadmap.md` Loop A describes for its
own domain. That's explicitly not where this starts — it starts as a
faster way to answer the question a human is already asking.
