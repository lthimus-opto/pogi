# Data Agent — Vision & Context

**What "the agent" means here:** the target is a single autonomous
invocation -- no chat, no turn-by-turn human steering -- that, given one
source, runs the task spec (`../TASK_SPEC.md`) end to end and writes rows
to the `gate_verdict` table in MotherDuck. The interactive sessions
described below are not that target; they're the current, temporary way
the mapping and failure-mode rules get discovered and refined, until an
invocation can run them unattended. See "Where This Is Headed" below for
exactly where the automation boundary sits today.

## Context

We want to create a data agent that takes data from a source — a SQL
database, a CSV file, a parquet export, an API response, whatever shape
it arrives in — and turns it into something Atlas can consume.
Concretely, the agent:

1. Reads the data at the source.
2. Understands it and maps it onto Atlas's ontology (entity / instrument
   / position — see `../../docs/atlas_data_model.md`).
3. QCs it: finds what's wrong, cleans what it can.
4. Writes the result directly into a `gate_verdict` table in MotherDuck,
   one row per entity/instrument, shaped as the full Atlas SDK payload
   plus a verdict. A separate pipe — not the agent — is what actually
   loads it into Atlas.

The agent never loads anything itself, and never calls an Atlas
ingestion endpoint directly. Its output is a table, not an action —
loading is a downstream pipe's job, reading from that table, same as
every other source Atlas already ingests.

Not every record the agent looks at will be equally certain, and that's
fine — the agent doesn't need to force a single yes/no call on
everything. Instead, every record gets sorted into one of a small number
of confidence buckets. The exact count and names aren't settled yet, but
the shape is:

- **To be loaded** — the record is clean, or the fix is clear. Written
  to the output table in loadable shape; the downstream pipe picks it
  up from there — the agent's job stops at writing the row.
- **To be verified** — the record is usable, but something about it the
  agent can't resolve with confidence. Not clean, not bad either — held
  back from the loadable set until a human looks at it.
- **To be rejected** — the record is clearly bad. Nothing salvageable;
  not worth spending more time on, and never becomes loadable.

This is a change from an earlier, stricter version of this doc, which
only let the agent act on unambiguous problems and implicitly left
everything else alone. Ambiguity isn't out of scope anymore — it's a
bucket ("to be verified"), not a dead end.

## Use Case

Security Master — first case study, data is bad at scale, top priority to
clean. It's an Opto-owned service on PostgreSQL (same Aurora cluster as
Atlas); the agent has read-only DB access via `connect.sh`.

## Approach

We don't yet trust an automated process to clean data unsupervised, so
this is the manual version of the process — a human, working through a
session with the agent, runs it by hand on real data until it's proven
solid enough to hand to an actual autonomous agent.

How we'll actually do it:

- A session starts by referencing `../TASK_SPEC.md`, with a prompt like
  *"Let's dive into the data in <source>."* — the whole source/database,
  not one table; the task spec's mapping step works across all of it.
- The task spec's steps get executed.
- The output gets shared with you.
- You give feedback.
- That feedback gets folded back into `../knowledge/` to strengthen the
  process.
- Once the process is solid, you'll say so, and we move to producing real,
  concrete correction examples.

## Where This Is Headed

This manual process produces two things: the raw material
(`../knowledge/mapping_guide.md`, `../knowledge/failure_modes.md`) and,
once that material holds up, the actual context an unattended run needs
to do the same job itself.

The immediate next step is **not** the always-on runner -- it's a single
**non-interactive agent invocation**: given one source, run the task spec
end to end with no turn-by-turn human steering, writing `gate_verdict`
rows to MotherDuck (per `.pi/skills/tooling-pipeline` and
`../knowledge/ingest_gate_schema.md`) rather than a proposal file. That
invocation is the thing this manual process is training. Every session
here either confirms the process already works unattended for a case, or
surfaces a gap -- a missing failure mode, an ambiguous mapping call --
that still needs a human before it can be automated.

Only once a single source runs reliably unattended does wrapping it in a
multi-source, scheduled runner make sense (see `./roadmap.md`) -- that
document's Loop A is the later, bigger system: the same `run_prompt.md`
invocation per source, triggered on a schedule (cron/launchd) instead of
by hand, with a nudge policy layered on top of `gate_verdict` in
MotherDuck rather than a separate ledger. This doc's scope stops at one
source, one invocation, one MotherDuck write.
