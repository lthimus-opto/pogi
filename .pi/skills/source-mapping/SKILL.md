---
name: source-mapping
description: >
  How to map any source's data onto Atlas's ontology. Contains the general method,
  red flags to check for (grouping-only constructs, level conflation, workflow leakage,
  no-slot-yet), and the Security Master worked example. Use during Task 2.
---

# Source Mapping

The living mapping guide is at `./knowledge/mapping_guide.md` — that is the knowledge base,
where the general mapping method, red flags, and worked examples get discovered,
tested against real data, and refined by a human across sessions. Read it completely
before mapping any source. This skill only explains how the agent should use it.

## How to use the mapping guide

- Start by checking whether the guide already has a worked example for this source.
  If yes, follow it. If no, derive the mapping using the decision test and the
  red flags documented in the guide.
- **A worked example is not a table checklist.** Before extraction (Task 1,
  before you get here), the run should already have done a systematic
  FK-column pass over the live schema -- see `knowledge/mapping_guide.md`'s
  "Systematic table discovery" section and `tooling-pipeline`'s Stage 1.
  A real session skipped that and copied Security Master's table scope
  straight from this guide's SM worked example prose, missing `performance`
  and `fund_note` entirely -- both had real facts for the manager in scope
  that the prose just never happened to mention. For Security Master, the
  five tables that matter most across every investigation so far are
  `manager`/`fund`/`fund_family`/`security`/`performance` -- treat a run
  that skips `performance` as incomplete by default.
- The guide references `../docs/atlas_data_model.md` for the underlying ontology —
  read that too when the guide points you there.
- The guide's "Before proposing any correction" section has two rules learned from
  getting a real correction wrong. Read them before proposing any value fix.

## Non-interactive rule

If a mapping call is ambiguous — reasonable people could disagree on which Atlas
level a fact belongs to — don't force a decision. Note the ambiguity in the
output (verdict = `DEFER`, reasoning captured) and move on. The mapping guide
gets updated by humans between sessions, not by the agent mid-run.

## Verify the SDK, don't guess it

Every enum value, field name, and payload shape referenced in this skill and in
`atlas-ontology` should be treated as *probably* right, not *definitely* right —
several guessed enum values and field shapes turned out wrong once actually
checked in a real session (invented attribute names that don't exist, wrong
field types, a missing per-attribute `as_of`, a `legal_name`/`brand_name` slip).
Before building any real payload, introspect the installed package directly:

```python
from opto_atlas_service.models.entity_attribute_name import EntityAttributeName

print([v.value for v in EntityAttributeName])
from opto_atlas_service.models.entity_create_input_record import EntityCreateInputRecord

print(EntityCreateInputRecord.model_fields)
```

This is cheap and removes an entire class of mistake. Do it before proposing a
payload, not after getting corrected on one.
