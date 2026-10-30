# Atlas Mapping Guide

## Purpose

How to take a source's data — in whatever shape it arrives — and route
every fact in it onto Atlas's fixed ontology
(`../docs/atlas_data_model.md`). The method below is
source-agnostic on purpose: Security Master is the first case study, but
nothing here should be read as "how SM maps" — only as "how anything
maps," with SM as the worked proof that it holds up on real data.

If this guide and `atlas_data_model.md` ever disagree, `atlas_data_model.md`
wins — it's the canonical model. Update this guide when that happens;
never the other way around.

But Atlas's actual live schema outranks both docs. Atlas keeps growing —
new tables get added between one session and the next, and neither this
guide nor `atlas_data_model.md` gets updated the moment that happens.
Checking the live schema (read-only, via `connect.sh` against Atlas
itself) before trusting either doc's inventory is part of the agent's
job every session, not a one-time read done once and assumed current.

---

## The one constant: Atlas's decision test

Straight from `atlas_data_model.md`, "Deciding Where Data Lives":

1. Is this fact about the legal person itself, independent of any
   financial claim it issued? → **Entity** (`ENTITY_ATTRIBUTE`,
   `ENTITY_NAME`, `ENTITY_RELATIONSHIP`, `ENTITY_TYPE`, ...)
2. Is this fact about the terms of a specific claim, shared by everyone
   who holds it? → **Instrument** (`INSTRUMENT` columns,
   `INSTRUMENT_ATTRIBUTE`, `INSTRUMENT_FEE`, ...)
3. Is this fact specific to one holder's economics on that claim? →
   **Position** (`POSITION_ATTRIBUTE`)

Apply this to every discrete fact in the source, regardless of what table,
object, or document it happens to live in. **The source's own organization
is not a signal about which Atlas level a fact belongs to — only the
content of the fact is.** A source can arrive as four relational tables,
one flat table, a JSON payload, or a PDF extraction; this test doesn't
change with it.

**The standing goal is to find a home for every mappable fact, not to
flag-and-stop at the first sign of friction.** A fact written in
narrative/free text (a rate described in prose, a schedule in a rich-text
description field) is just as real as the same fact in a structured
column, and deserves the same effort to place it correctly — reading
content and converting it to the target shape, not just noting that it
exists. The one hard limit: never invent a target slot that doesn't
exist in Atlas's real schema to force a fit (see `knowledge/failure_modes.md`'s
`narrative_rate_not_captured` entry for the confirmed case of a tiered
fee schedule that genuinely has no attribute-name home yet — that's a
real gap to flag for a schema change, not something to paper over with a
made-up enum value). The failure mode to avoid in the other direction:
firing a "found it in narrative" rule on a field that doesn't actually
have real content (a literal placeholder string like `'null'`/`'none'`
is not narrative content) — confirmed real incident, see that same
failure-mode entry's correction note.

---

## Red flags to actively check for, in any source

Don't wait to stumble on these — look for them while mapping:

- **Grouping-only construct** — a source table/object whose sole job is
  to bucket other records under a shared label, with no independent
  legal existence of its own. This collapses into an Atlas *attribute*
  on whatever it's grouping, never its own entity.
- **Level conflation** — a single source row blending facts from two
  different Atlas levels (e.g. entity-level facts and instrument-level
  facts in one row) because the source never needed to distinguish them.
- **Workflow/CRM leakage** — source columns describing internal process
  state (approval status, diligence status, deal-pipeline stage,
  relationship-manager narrative) rather than facts about the legal
  person, claim, or holding. These fail the decision test directly --
  not a fact about the entity, instrument, or position itself, just
  process around it -- so none of it belongs in Atlas. Don't lean on
  `atlas_data_model.md`'s "Out of Scope" section as the reason; that
  section isn't reliable right now, so this red flag stands on the
  decision test alone.
- **No slot yet** -- a fact that's clearly meaningful but doesn't match
  anything you can find. This guide's table names are a snapshot, not a
  ceiling -- a dedicated table for this exact fact may have been added to
  Atlas since this section was last touched (e.g. a `coupon` table
  appearing where there used to be none). So check the *live* schema,
  not this list: does a dedicated table for the fact exist now? If not,
  is there an EAV attribute table at the applicable level (`ENTITY_ATTRIBUTE`,
  `INSTRUMENT_ATTRIBUTE`, `INSTRUMENT_FEE_ATTRIBUTE`, `POSITION_ATTRIBUTE`
  as of this writing -- confirm the current set live, it will drift)?

  **Correction, learned the hard way**: Atlas's Postgres tables are EAV-shaped,
  but the `opto-atlas-service` SDK's create-payload attribute-name fields
  (`EntityAttributeName`, `ManagementFeeAttributeName`, `PerformanceFeeAttributeName`,
  `InstrumentAttributeName`) are **fixed, finite enums**, not freely extensible --
  confirmed by inspecting the installed package directly (see `atlas-ontology`
  skill). "Just add a new attribute name" is **not** something this agent can do
  unilaterally when the fact needs a name outside the enum -- that requires an
  actual PR to the SDK. So: if a dedicated table or an *existing* enum value
  covers the fact, map it, not a gap. If it needs a *new* enum value that
  doesn't exist yet, it **is** a real gap requiring engineering work -- log it,
  don't paper over it with an invented attribute name that will fail validation.
  (A running gap list is a separate, not-yet-started piece of this process
  -- see the README.)

Finding any of these while mapping is diagnostic on its own -- it surfaces
structural defects before a single row's *values* have been checked.

---

## Before proposing any correction

Two rules learned from getting a real correction wrong on the first
try (Hayfin Maritime Yield Fund II's tiered management fee -- see
`knowledge/failure_modes.md`'s `narrative_rate_not_captured`):

**Name the exact chain first.** Don't propose a value until you can state
the full `entity_id` -> `instrument_id` -> `fee_id` (or equivalent) chain
it attaches to. "This field should be X" isn't a complete proposal if you
can't also say which record, which instrument, which fee, and which
attribute name X becomes. If you can't name the chain, you don't
understand the fix yet -- go back and map it properly instead of
proposing something plausible-sounding.

**Single value vs. schedule are different fixes.** When a structured
field is blank and a narrative field names the real answer, check whether
the narrative names *one* number or a *schedule* (multiple values tied to
a condition -- tiers, step structures, bands). One number is a normal
value correction (`rollup_detail_mismatch`'s shape) if the field already
exists in the SDK enum. A schedule (`narrative_rate_not_captured`'s shape)
is **not** a simple correction and, as of the real enum check above,
**needs an actual SDK PR** -- `tier_N_rate` does not exist in
`ManagementFeeAttributeName`/`PerformanceFeeAttributeName` today. Propose
it as a gap needing engineering work, with the exact tier values named
as evidence, not as an EAV attribute you can just write.

---

## Systematic table discovery -- don't infer scope from this doc's prose

**Confirmed gap** (Zero Prime, both orgs, a real run): extraction scope
was decided by copying the table names mentioned in this doc's SM worked
example below (`manager`/`fund_family`/`fund`/`security`, plus three more
recalled from other prose in this same doc -- `field_provenance`,
`strategy_weight_exposure`, `internal_note`). That produced an incomplete
extraction: `performance` (a dedicated table, FK'd to `security_id`, with
real `net_irr`/`net_tvpi`/`net_dpi`/`net_moic` track-record rows for the
manager in scope) and `fund_note` (quarterly manager-update letters,
workflow-shaped by table name but containing a full historical
TVPI/MOIC time series in narrative text) were both missed entirely --
neither happened to be named in this doc's prose, even though both had
real, extractable facts for the specific manager being investigated. This
doc is written from *other* managers' data in *prior* sessions; it is a
record of what mapped cleanly *there*, not an inventory of every table
that could matter for a *new* manager.

**The fix, now standing process (see `run_prompt.md` Task 1 and
`.pi/skills/tooling-pipeline`)**: every run, regardless of whether this
doc already has a worked example for the source, do a systematic pass
over the live schema before deciding extraction scope:

1. `information_schema.columns` for every column named like the source's
   own entity-id columns (`manager_id`/`fund_id`/`fund_family_id`/
   `security_id`/`org_id`/`performance_id`/`position_id`/`company_id` for
   Security Master).
2. For every table with one of those columns, `count(*)` scoped to the
   actual records in this run (not the whole table) -- and verify the
   column is a real FK, not a coincidentally-named unrelated column
   (`arch_fund_data_table.fund_id` is a `bigint` sequence, not a FK to
   `fund.id` -- checked by type/constraint, not assumed from the name).
3. Every table that comes back with rows gets an explicit decision --
   extract-and-map, or exclude-with-a-stated-reason. Never silently skip
   a table that has rows for the record in scope.

### Security Master's top critical tables

Across every SM investigation so far, these five carry the load and
should always be pulled first, before the systematic pass finds anything
else: **`manager`, `fund`, `fund_family`, `security`, `performance`**.
The first four are the core entity-defining chain (see the worked example
below); `performance` was the confirmed miss above and is now promoted to
this list -- it's a dedicated, FK'd fact table (not a derived/rollup
view), and fund-level track record (IRR/TVPI/DPI/MOIC) is exactly the
kind of content `atlas_data_model.md`'s `analytics[]` exists for. Treat
any future SM session that doesn't pull `performance` as incomplete by
default, not just optionally richer with it.

### What the systematic pass found on Security Master (Zero Prime), full inventory

Ran against both Zero Prime `manager_id`s. Tables with rows, and the
decision made on each -- kept here so the next SM session doesn't have to
redo this discovery from scratch:

- **`performance`** (3 rows) -- extract, map to fund-entity `analytics[]`
  (`observation_type='unverified'`, SM data is marketing/manager-reported,
  not audited).
- **`fund_note`** (9 rows) -- extract. Workflow-shaped by table name
  (quarterly manager-update letters, diligence call notes), but per
  "Workflow/CRM tables can still contain extractable facts" below, its
  narrative named a full quarterly TVPI/MOIC time series
  (`regexp_extract` on `body::VARCHAR` against `'TVPI[^0-9]*([0-9.]+)'`/
  `'MOIC[^0-9]*([0-9.]+)'` patterns) that the single `performance` snapshot
  doesn't cover -- also mapped into `analytics[]`, `as_of` = the note's
  `display_date` (fallback to `created_at::DATE` when null).
- **`fund_update`** (38 rows) -- checked, excluded. Pure column-change
  audit log (`column_changed`/`new_value`/`changed_by`/`time_of_change`);
  no fact beyond what's already in `fund`'s current row.
- **`diligence_document_fund`**/**`diligence_document`** (10 rows) --
  checked, excluded. File/S3-key registry plus diligence workflow status;
  textbook workflow/CRM leakage, no fact about the fund itself.
- **`fund_custom_label`**/**`fund_family_custom_label`** (5+1 rows) --
  checked, excluded. Opto-internal deal tags ("Opto Focus", "Opto AI
  Fund") for Opto's own portfolio categorization, not a fact the source
  is asserting about the entity.
- **`fund_opto_next_step`** (2 rows) -- checked, excluded. Opto's internal
  deal-pipeline next-step tracking, textbook workflow leakage.
- **`contact`** (1 row) -- checked, **logged as a gap, not mapped**. A
  real person (name/role/title/email) tied to the manager, but the
  current `EntityType` enum has no person/individual slot and
  `RelationshipType.employs` has nowhere to point without one -- this
  needs an actual SDK/ontology addition before it can be mapped, same
  category as the tiered-fee gaps below. Not a failure mode; a mapping gap.
- Everything else with an entity-id-shaped column (29 more tables --
  `artifact*`, `position`, `company_performance`, `net_cash_flow_event`,
  `label`, `module`, `grading_criteria`, `information_request`, etc.) --
  confirmed **zero rows** for this manager. Confirmed empty, not assumed
  empty -- the distinction matters for the next manager, which may have
  rows in tables that were empty here.

---

## Worked example: Security Master

Source shape: `MANAGER` → `FUND_FAMILY` → `FUND` → `SECURITY`, one row per
level, FK chained downward.

### Entities

- `MANAGER` rows → `ENTITY` (`entity_type = management_company`)
- `FUND` rows → `ENTITY` (`entity_type = fund_vehicle`) — **not** `FUND_FAMILY`
- `MANAGER_ID` on `FUND_FAMILY`/derived onto `FUND` → `ENTITY_RELATIONSHIP`
  (`manages`, manager entity → fund entity), replacing the FK chain

### Red flag hit #1 — grouping-only construct

`FUND_FAMILY` (e.g. "8VC Fund", "8VC Opportunity Funds", "SPVs") has no
independent legal existence — it's a label the source uses to bucket
several `FUND` rows. It collapses into:

```
ENTITY_ATTRIBUTE(entity_id=<fund>, attribute_name='fund_family_label',
                 attribute_value_text=<FUND_FAMILY_NAME>)
```

on every fund entity that rolls up to it. `FUND_FAMILY.INDUSTRY_WEIGHTS`
and `GEOGRAPHY_WEIGHTS` were wrongly flagged **no slot** earlier --
the category names map to `ENTITY_STRATEGY` (`strategy_system='INTERNAL'`,
`strategy_tier='industry'`/`'geo_focus'`, one row per named category on
the fund entity) -- the same table/tiers `atlas_data_model.md` documents
for a fund's stated industry/geo focus.

**On the weight/percentage -- correction, confirmed wrong on a real pull
(2026-10-29, 8VC migration run)**: this doc previously said `EntityStrategyCreate`
has no field to carry a weight at all, and that this was deliberate. Both
halves of that were wrong. `entity_strategy` has a real, live `weight`
numeric column, and it's actively populated: `fund_family.industry_weights`/
`geography_weights` (the JSON columns, e.g. `{"Information Technology": 0.75,
"Industrials": 0.15, "Health Care": 0.1}`) map directly, key-for-key and
value-for-value, onto `entity_strategy.weight` for every fund entity under
that family -- checked end to end via `silver_identifier` lineage on "8VC
Angel Fund I": source `fund_family.industry_weights` == destination
`entity_strategy` rows' `weight`, exactly, no transformation. Map the
weight whenever the source has one -- don't drop it. The dangling
`strategy_weight_exposure.strategy_id` (see below) is still a dead end and
still not worth resolving, but that's a different, narrower finding than
"there's nowhere for a weight to go at all."

### Red flag hit #2 — level conflation

`SECURITY` is keyed 1:1 on `FUND_ID` in this source (SM isn't actually
modeling distinct share classes) and blends two Atlas levels in one row:

- Entity-level facts (true of the fund regardless of share class):
  `VEHICLE` (→ `ENTITY_ATTRIBUTE.product_structure`), `INVESTMENT_PERIOD`
  (→ `investment_period_years`), `TERM_LENGTH` (→ `fund_term_years`),
  `GP_EXTENSIONS` (→ `gp_extension_years`)
- True instrument-level facts (would legitimately vary by share class):
  `MANAGEMENT_FEE*`, `PERFORMANCE_FEE*`, `PERFORMANCE_FEE_HURDLE*`,
  `WATERFALL_METHOD` → `INSTRUMENT_FEE` + `INSTRUMENT_FEE_ATTRIBUTE`;
  `SUITABILITY_STATUS` → `INSTRUMENT_ATTRIBUTE.eligible_investor_type`;
  `TAX_STATUS` → `INSTRUMENT_ATTRIBUTE.tax_status`

So one `SECURITY` row un-conflates into an `ENTITY_ATTRIBUTE` batch on
the fund entity, plus *conditionally* an `INSTRUMENT` -- whether the
instrument gets created at all depends on whether there's anything
instrument-level to attach to it, not on whether the source happened to
give the row a `SECURITY_ID`:

- **Zero true instrument-level facts** (no fee, no instrument attribute,
  nothing that would legitimately vary by share class) -> don't create
  an `INSTRUMENT`. There's nothing for it to anchor; the whole row is
  entity-level, full stop.
- **At least one true instrument-level fact**, but no name for the
  specific share class (SM doesn't model share classes, so this is the
  common case) -> create the `INSTRUMENT` anyway (issued by the fund
  entity, `instrument_type = lp_interest`), and name it `Default class`
  rather than leaving it unnamed or inventing a class name SM never gave.
  `INSTRUMENT_FEE`/`INSTRUMENT_FEE_ATTRIBUTE` rows attach to that
  instrument as before.

### Red flag hit #3 — workflow/CRM leakage

Roughly a third of `FUND`'s columns are Opto's internal deal-pipeline
state, not Atlas facts at all: `RISK_FACTOR_*`, `PASS_DESCRIPTION`,
`WHY_WE_LIKE_BLURB`, `DEAL_STATUS`, `OPTO_IM_OWNER_ID`, `AKSIA_STATUS`,
`*_STATUS_UPDATED_AT`, `INTERNAL_APPROVAL_STATUS`, `OPTO_DILIGENCE_STATUS`,
`IC_APPROVED`, `MANAGER_FUNDRAISING_STATUS`, `FAIL_REASONS`,
`EXPECTED_OPTO_ALLOCATION*`. These should never cross into Atlas — they
belong to whatever internal deal-tracking system, not the identity vault.

### No-slot-yet gaps found (candidates for the future gap list)

- `FUND.FINAL_CLOSE` — enum only has `expected_final_close_date`, not a
  realized one
- `SECURITY.GENERATES_INCOME`, `BLOCKERS_IN_PLACE`, `LPAC_EXTENSIONS`,
  `LP_EXTENSIONS`, `MAXIMUM_EXTENSIONS`, `PERPETUAL_TERM` — no matching
  attribute name
- `SECURITY.PERFORMANCE_FEE_2/3` / `HURDLE_2/3` (tiered/step-up carry) and
  the tiered `MANAGEMENT_FEE` schedule seen on Hayfin Maritime Yield Fund
  II — **confirmed real gaps**, not EAV extensions. `PerformanceFeeAttributeName`
  and `ManagementFeeAttributeName` are fixed 4-value enums in the real SDK
  (checked by introspecting the installed package) with no tier variants.
  Needs an actual PR to add `tier_N_rate`-shaped values before these can
  be mapped. (This reverses an earlier note in this doc that called it
  "not a declared gap" -- that was wrong, see "Before proposing any
  correction" above.)
- Performance catch-up provisions (e.g. Hayfin Maritime Yield Fund II's
  "82.5% catch-up") — no `catchup_rate` in `PerformanceFeeAttributeName`.
  Same category of gap as the tiered fees above.
- `SECURITY.MANAGEMENT_FEE_*` on undrawn/uncalled commitments as a
  distinct component from the investment-period rate -- e.g. Muzinich
  Aviation Opportunities II Strategy's narrative names "1.50% on drawn
  capital... additionally, a 0.12% management fee... on undrawn
  commitments," but `ManagementFeeAttributeName` only has
  `investment_rate`/`investment_basis`/`harvest_rate`/`harvest_basis` --
  none of which is "a second, smaller rate applied to the uncalled
  portion while the first rate applies to the called portion
  simultaneously." `harvest_rate` is a different concept (a *later
  period's* rate, not a *concurrent, smaller* rate on a different base).
  1 confirmed instance so far -- log as a gap if it recurs, with the exact
  drawn/undrawn split named as evidence.

**Not actually a gap, corrected**: `FUND.MOIC_TARGET` / `NET_MOIC_TARGET`
and the fund-level target/track-record IRR, TVPI, DPI, and cash-yield
figures narrated in pitch decks and call notes were originally listed as
"no matching attribute anywhere." Wrong -- these don't belong in
`ENTITY_ATTRIBUTE` at all, they belong in `analytics[]`
(`AnalyticsCreate{metric, observation_type, return_basis, value, as_of}`)
on the fund **entity** (not the instrument -- SM's performance data is
almost always fund-level marketing content). `AnalyticsMetric` covers
`irr`/`tvpi`/`moic`/`dpi`/`distribution_yield` directly. Use
`observation_type='target'` for a currently-fundraising fund's stated
targets, `'unverified'` for a track-record claim sourced from marketing
material rather than an audited financial statement. See `atlas-ontology`
for the full breakdown.

### What mapped cleanly

`MANAGER.AUM/YEAR_FOUNDED/HEADQUARTERS/EMPLOYEE_COUNT/REPUTATION` →
`ENTITY_ATTRIBUTE`; `MANAGER.PITCHBOOK_ID/CRUNCHBASE_ID` →
`ENTITY_IDENTIFIER`; `FUND.VINTAGE/TARGET_SIZE/CAP_SIZE/GP_COMMITMENT` →
`ENTITY_ATTRIBUTE`; the core fee terms on `SECURITY` → `INSTRUMENT_FEE` +
`INSTRUMENT_FEE_ATTRIBUTE`; `SECURITY`'s rich-text description →
`ENTITY_ATTRIBUTE.description` (fund-level narrative -- the same field
`knowledge/failure_modes.md`'s `rollup_detail_mismatch`/`narrative_rate_not_captured`
entries lean on to confirm what a structured field should actually say).

### `field_provenance` -- an untapped, already-computed trust signal

SM has a `field_provenance` table (FK'd to `manager_id`/`fund_family_id`/
`fund_id`/`security_id`) with `field_name`, `confidence` (0-1 float), and
`reasoning` (the exact source-document quote behind an AI-extracted
value) for every field SM's own extraction pipeline populated. This is a
real, per-field trust signal already computed upstream -- e.g. a fund's
`target_fund_size` might carry confidence 1.0 with the quote *"Target
fund size... $1.5 billion"*, while `reputation` on the manager might only
be 0.85 (inferred from AUM and fund count, not stated outright). Check
for this table on any new source and use it rather than re-deriving
confidence from scratch -- it's more precise than guessing from raw fill
rate, and it comes with a citation.

### `ai_generated_preview` -- a different, more important trust signal than `field_provenance`

`field_provenance.confidence` scores how much to trust one *field's*
value. `ai_generated_preview` (a boolean on `manager`/`fund_family`/
`fund`/`security` -- checked independently at each level, not inherited)
answers a different, prior question: has this *whole record* been
confirmed by SM's own review pipeline at all, or is it still a raw
AI-extraction preview nobody has looked at yet? A record can have
confidence-1.0 field_provenance on every field and still be
`ai_generated_preview = true` -- the extraction was confident, but no
human (or SM's own promotion step) has signed off on the record existing
as real data yet.

**Don't confuse this with `initially_ai_generated`** -- a separate column
that only records *how the record was originally produced* and stays
`true` forever, even for records that have since been fully reviewed and
promoted (e.g. Acorn Capital Management's manager/fund rows in a real
pull: `initially_ai_generated = true`, `ai_generated_preview = false` --
onboarded, trust it). Only `ai_generated_preview` gates whether a record
is ready to be looked at as data at all; see `knowledge/failure_modes.md`'s
`ai_generated_preview_not_onboarded` (confirmed on a real run: 6 of 10
managers in one pull, and every fund/security under each of them,
consistently -- `REJECT`, full stop, independent of completeness or any
other accuracy check).

### `strategy_weight_exposure` is a dead end -- use `fund_family`'s own JSON columns instead

An earlier version of this doc (see the "Red flag hit #1" worked example
below) pointed at a `strategy_weight_exposure` table (`fund_family_id`,
`strategy_id`, `percentage`) as the real numeric weight behind a fund
family's industry/geography category membership. Checked directly on a
real pull: `strategy_id` doesn't resolve to any table in SM's own schema
-- no FK constraint, no matching row in `grading_criteria` or any other
candidate lookup table. It's a dangling reference to what's presumably an
app-level enum/constant maintained outside the database, not something
this agent can resolve read-only via `connect.sh`. This doesn't actually
cost anything, though: `fund_family.industry_weights`/`geography_weights`
(JSON columns, e.g. `{"Industrials": 1.0}`, `{"North America": 1.0}`)
already carry the category *names* directly and map cleanly to
`ENTITY_STRATEGY` as this doc's worked example describes -- **and, corrected
above, `entity_strategy.weight` is real and should carry exactly these JSON
values**, not be left empty. So the unresolvable `strategy_id` was never
going to be used downstream regardless -- extract `strategy_weight_exposure`
for completeness-evidence purposes only if you like, but don't block
mapping on resolving it, and don't use its dead-endedness as a reason to
skip populating `weight` from `fund_family`'s own JSON columns, which work
fine on their own.

### `fund.atlas_entity_id` -- the source row sometimes already caches its own resolved Atlas entity

Found on a real pull: `fund` (not `manager`, not `security` -- checked,
neither has an equivalent column) carries its own `atlas_entity_id`
column, populated for some rows (4 of 42 funds in one pull) and `NULL`
for the rest. This is a stronger, more direct signal than a live
entity-name match against Atlas for deciding `gate_relationship`'s
`verdict` (see `knowledge/ingest_gate_schema.md`) -- when it's set, trust it over
re-deriving the same answer by fuzzy name matching. Still confirm the
manager side independently (no equivalent cache column on `manager`
as of this check) via a live `entity_name` lookup against
`connect.sh .env.atlas.prod`, same as before. Check for this column on
any new source's child-level table -- it may exist elsewhere Atlas's own
resolution writes back to the source, and skipping the check means doing
fuzzy name-matching work that's already been done for you.

### Workflow/CRM tables can still contain extractable facts

`internal_note` (deal-diligence call notes) is textbook workflow/CRM
leakage per the red flag above -- it never maps into Atlas as a table.
But the free text inside it can independently confirm or extend
structured facts: a real example cross-checked `manager.employee_count`
against a note's "260+ employees" (matched), and separately surfaced a
predecessor fund's track-record IRR/TVPI/DPI that had no structured home
at all (see the analytics correction above). Treat these notes as a
source of leads to verify against structured fields and the analytics
mapping -- not as something to map directly, and not as ground truth on
their own (it's still someone's call summary, not the fund's own document).

### New observation: vehicle/perpetual-term mismatch (1 instance, not yet catalogued)

Hayfin Maritime Yield Fund II: `security.vehicle = 'Drawdown'`, but
`security.perpetual_term = true` and the fund's own `overview_text` calls
it *"a perpetual fund with a vintage structure"* with lock-up +
biennial-liquidation-window redemption terms -- that's an `Evergreen`-shaped
fund mislabeled as `Drawdown`. One confirmed instance so far -- per
`knowledge/failure_modes.md`'s discipline, not enough to catalogue as a trusted
rule yet. Flag as `DEFER`/"to be verified" if it recurs, don't invent the
rule from a single case.

### Security Master is multi-tenant -- a fifth red flag, or at least a new dimension

Discovered while investigating "Zero Prime": `manager` alone has 66
distinct `org_id` values. The same real-world manager can exist as
separate rows under different orgs, sometimes explicitly cross-linked via
`universal_id` + `extraction_copy_manager_data_result='LINKED_MANAGER'`
(one org's copy populated by copying another's canonical record). Every
manager investigated before this (Hayfin, IVP, 8VC) happened to only exist
in one org (`2346b7f2-b69f-40bb-a53c-d8447008fe42`, the dominant one with
1,574 managers), which is why this never came up earlier -- but it means
every prior mapping decision was implicitly scoped to one tenant without
that assumption ever being stated.

**Real, confirmed example of why this matters**: both orgs have their own
"Zero Prime Ventures Fund II" (same vintage, same fee terms) but disagree
on `target_fund_size` (\$45M vs. \$48M). Two tenants, two numbers, same
real-world fund.

**Mapping rule, deliberately kept simple**: `silver_id` stays each org's
own record id (don't force two orgs onto one shared identity -- that's
Atlas's entity-resolution job, not this agent's). `org_id` on the Atlas
request should be that record's own `org_id`, per record. The **one**
adjustment that matters: when `universal_id` is set on a record, use the
linked/canonical record's **name** (not this org's own `name` field) when
building `EntityNameCreate` -- so a cosmetic naming difference ("Zero
Prime" vs. "Zero Prime Ventures") doesn't sabotage Atlas's own
name-based resolution. See `atlas-ontology` for the full rule and how
`org_id` flows into `IngestionSourceCreate`.

### Correction: SM's own lineage fields are not Atlas's concern -- don't let them block a clean record

**Confirmed real instance that got this wrong**: Silver Lake's manager
record (`manager_id=2083e844...`, org `2346b7f2...`) has
`extraction_copy_manager_data_result='LINKED_MANAGER'` but its own
`universal_id` is blank -- the field claims the record's data was copied
from a linked record, but there's no FK saying which one. Separately, a
*second* org's "Silver Lake Partners" copy (`dbc46096...`, org
`48c9e0a8...`) has `universal_id` pointing **at** Silver Lake's record --
the opposite direction from what the first record's own flag implies.
This got flagged `accuracy_passed=false` / `DEFER` in a real run, even
though Silver Lake's own facts were 100% mapped with confidence 1.0
across the board -- nothing about the manager's actual data was in
question.

**That was wrong. The rule, corrected**: `universal_id` and
`extraction_copy_manager_data_result` are **SM's own internal
copy-tracking bookkeeping** -- not a fact about the real-world manager,
fund, or instrument, and not something Atlas's own entity resolution
consumes or trusts (its resolution flow -- exact identifier -> exact
silver_id -> exact name -> fuzzy match -> LLM tiebreaker -- never reads
SM's copy-chain fields at all). **Don't flag/DEFER a record just because
its lineage metadata is internally inconsistent or disagrees with
another org's copy's lineage metadata.** That's noise, not an accuracy
issue.

When multiple org-copies of the same real-world manager/fund exist, the
actual job is: **pick whichever copy is cleanest/most complete and treat
that one as the source of truth** for mapping -- not trace who copied
from whom. Concretely:

1. Compare the copies **on substance** -- completeness, and whether their
   actual values agree -- never on SM's copy-tracking fields.
2. If one copy is clearly cleaner/more complete (as with Silver Lake
   above), map that one and don't let its own lineage-field oddities hold
   it back. This is the common case.
3. Reserve `DEFER`/`flag` for when the copies **substantively diverge**
   in a way you can't adjudicate -- e.g. the Zero Prime \$45M/\$48M
   `target_fund_size` disagreement above. That's a real, judgment-call
   case (pick the more complete/recent copy if one is clearly better;
   otherwise flag for a human) -- a *values* disagreement is the actual
   signal worth attention. A *lineage-field* disagreement alone is not.
4. `universal_id` still earns real weight for exactly one thing: when a
   record is clearly the lesser/duplicate copy of a cleaner canonical
   one, use the canonical copy's **name** for `EntityNameCreate`. That's
   a cosmetic naming aid, not a gate on whether to load.

See `knowledge/failure_modes.md`'s "Known non-issues" section for the catalogued
version of this correction.

### Naming convention: always `brand_name` for Security-Master-sourced records

`EntityNameType` (`legal_name`/`brand_name`/`short_name`, see `atlas-ontology`
for the enum itself) requires a per-source choice -- it's not something
Atlas's model dictates on its own. For Security Master: because its data
is almost entirely sourced from marketing material the manager produced
to make themselves look good (pitch decks, quarterly letters), use
**`brand_name`** for every name extracted from it -- manager, fund, and
instrument names alike. `legal_name` should come from public
filings/registries, not a pitch deck -- SM is never that. This was
violated live in a real session (fund/instrument names were built as
`legal_name`) despite already being documented here -- the fix is
stating the *why* explicitly, not just the rule, so it doesn't get
missed again.

---

### Financial-graph queries must check every relationship type and every source's identity for the same real name -- not just one root `entity_id`

**Confirmed incident** (8VC, org `2346b7f2...`, full-graph review session):
asked to show "the financial graph" for a manager, the first attempt
rooted the whole query on the Security-Master-sourced manager `entity_id`
and its `MANAGES` edges only. That query came back with zero live
performance data, which looked like a gap in the source -- it wasn't.
The manager's real financial graph (an Arch-sourced position, held by
another fund, into two of the manager's own SPVs) hung off `ADVISES`
relationships from a **second, separate Atlas entity** -- the same real
firm's SEC Form ADV registered-adviser identity ("EIGHT PARTNERS VC,
LLC"), never merged with the brand-name entity ("8VC") because the two
have no shared identifier (see `failure_modes.md` entry 7,
`unmerged_brand_vs_legal_adviser_entity`).

**The rule this sets**: before concluding a manager's graph is thin or a
source is missing data, check:

1. **Every name variant** for the manager across every source present
   (`entity_name` grouped by `ingestion_source_group_key`) -- a
   regulatory filing almost always uses a different legal name than a
   pitch deck or a commercial database.
2. **Every relationship type**, not just `manages` -- `advises` is just
   as real a parent-child edge for SEC-registered advisers, and Form ADV
   data consistently uses it instead of `manages`.
3. **Every entity_id that shares the manager's real-world identity**,
   not just the one the source you started from created -- the same
   firm can legitimately be multiple `entity_id`s in Atlas today if
   resolution hasn't merged them yet (see `atlas-ontology` skill's
   entity-resolution notes); a thin-looking graph from one entity_id is
   not proof the data doesn't exist elsewhere in Atlas under the same
   real name.

This generalizes beyond this one incident: any time a source-specific
query comes back surprisingly empty for a manager/fund that should have
live data (Arch is already loaded, performance exists per the business
context), check for a second un-merged identity before concluding the
data truly isn't there.

## Adding the next source

When a new source shows up, don't write a mapping doc keyed to its
specific tables. Instead: run the decision test on its facts, check for
the four red flags above, and append a new `## Worked example: <source>`
section here with what you found — especially any *new* red-flag
variants or no-slot-yet gaps that weren't visible in the SM pass.
