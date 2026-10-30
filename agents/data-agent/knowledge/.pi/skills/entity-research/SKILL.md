---
name: entity-research
description: >
  How to do ad-hoc, read-only investigation of a real-world firm/manager/fund
  family in Atlas ("what can you tell me about X"). Use whenever asked to
  research, summarize, or report on an entity, manager, or fund family by
  name — as opposed to mapping a source onto Atlas's ontology for ingestion.
  Contains the full query playbook for walking entity_relationship in both
  directions, finding unlinked duplicate manager identities, checking
  holdings in both directions, and pivoting valuation history correctly.
---

# Entity Research

The living guide is at `../../knowledge/entity_research_guide.md` — read it
completely before answering any "tell me about X" / "what do we know about
X" question against Atlas. This skill only flags when to use it and the
non-negotiable minimum steps.

## When to use this

Any question that asks for a research summary of a real-world firm,
manager, GP, fund family, or portfolio by name — not a question about how
to map a new source's data onto Atlas's ontology (that's `atlas-ontology`/
`source-mapping`), and not the ingestion pipeline (`tooling-pipeline`).

## Non-negotiable minimum before answering

1. Name search (`entity_name ILIKE '%X%'`) is a **starting point**, never
   the full scope. Do not conclude anything about "the firm" from a single
   entity_id's footprint.
2. For every entity_id found, query `entity_relationship` as **both**
   `parent_entity_id` and `child_entity_id`, across **all**
   `relationship_type` values (`manages`, `advises`, etc. — don't filter to
   one). A second manager/adviser identity for the same real firm, carrying
   a *different* legal name and a much larger `ADVISES` universe, is a
   confirmed real failure mode here (see the guide's "confirmed incident").
3. Check for a direct `entity_relationship` link between any two
   candidate entity_ids that look like the same real firm. Report its
   absence explicitly if there isn't one — that's a data-quality finding,
   not something to silently assume away.
4. Re-run the instrument/position footprint against the **union** of every
   confirmed entity_id for the firm, not just the first one found, before
   reporting any "no instruments/no positions" conclusion.
5. Check **both directions** of holding: what the family's vehicles hold
   (issuer side) and who holds a position *into* the family's vehicles
   (investor side, including whether a known client fund has a position
   there). A one-directional answer is incomplete by default.
6. If reporting valuation figures, pivot `valuation_method` /
   `reporting_state` explicitly rather than taking one arbitrary
   latest row per position — see the guide for the exact pattern and why
   `DISTINCT ON (position_id) ORDER BY as_of DESC` alone is wrong.

See the guide for the concrete, copy-pasteable SQL for every step above.
