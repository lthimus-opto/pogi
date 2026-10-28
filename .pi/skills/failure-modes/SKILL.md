---
name: failure-modes
description: >
  Catalog of confirmed data-quality failure modes with trigger predicates, evidence
  requirements, and instance counts. Use during Task 3 (find what's wrong) to check
  every record against every catalogued predicate. Never invent new failure modes
  mid-run — flag uncatalogued anomalies as "to be verified" instead.
---

# Failure Modes

The living catalog is at `./knowledge/failure_modes.md` — that is the knowledge base,
where failure modes get discovered, debated, refined, and catalogued by a human
across sessions. Read it completely before scoring any records. This skill only
explains how the agent should use it.

## How to use the catalog

- Every entry has: a name, a kind (whole-record or field-level), a trigger
  predicate, evidence to capture, a verdict, and a status with instance counts.
- Apply every catalogued predicate to every record. Don't skip predicates
  that "probably won't fire" — run them all.
- The `status` field on each entry tells you how much to trust it. An entry
  with 1 confirmed instance is weaker than one with 14.

## Non-interactive rule

Only apply failure modes already in the catalog. If you see something new
that isn't catalogued, write it as `DEFER` with `failure_mode = NULL` and
your reasoning in the `reason` field — a human will decide whether to
catalogue it later. Never promote an incident to a failure mode mid-run.

## Verdict basis: mapped payload, not raw source

The old approach computed fill rates from raw source columns (e.g. "how many
SM fund columns are non-null") and used source-specific fields like
`manager_fundraising_status` to drive verdicts. This was wrong:

- A fund with 1 raw column filled but that column maps to a rich overview_text
  is more useful than a fund with 5 columns filled that are all workflow/CRM fields.
- `fundraising_status` is Security Master's internal deal-tracking state, not an
  Atlas fact. It should not drive gate decisions.

Verdicts are now based on the **mapped Atlas payload**, weighted by whether
a field is core (defines what the thing is) or supplementary (adds detail),
expressed as a completeness ratio against the expected-fields list — see
`ingest-schemas` for the full Accept/Quarantine/Reject rule:
- REJECT (bad): no resolvable identity, or zero fields mapped at all
- DEFER (ugly/quarantine): identity fine, but no core field mapped, or
  completeness ratio <40%
- LOAD (good): a core field mapped and completeness ≥40% (or core field +
  strategies compensate)

A raw attribute *count* is not the basis — a fund with only `vintage_year`
mapped (a core, defining fact) is more useful than one with five
supplementary fields and no core fact.
