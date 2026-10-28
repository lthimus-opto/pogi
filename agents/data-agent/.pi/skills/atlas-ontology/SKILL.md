---
name: atlas-ontology
description: >
  Atlas's data model, decision test, and attribute vocabulary.
  Use when determining where a source fact belongs: Entity, Instrument, or Position.
  Contains the canonical "Deciding Where Data Lives" test and the full table/column inventory.
---

# Atlas Ontology

## Authority: SDK > live schema > this doc

Three things describe Atlas, in order of what actually governs a payload:

1. **The `opto_atlas_service` SDK (via AWS CodeArtifact) is reality.** It's
   what actually validates or rejects a payload at submission time. If the
   SDK's enums/field shapes disagree with anything below, the SDK wins,
   full stop — see "Key principle" below for a confirmed case (fixed,
   finite attribute-name enums vs. the doc's EAV framing). Introspect the
   installed package directly whenever a shape or enum value is in doubt
   (see "When in doubt" below) — never guess from this doc or the live
   schema.
2. **The live Atlas Postgres schema** (`connect.sh .env.atlas.prod`,
   read-only) is what tables/columns currently exist — Atlas keeps
   growing, and this is the only way to know what's actually there right
   now. It tells you the shape of the data model, but not what the SDK
   will accept as a create-payload — those are two different questions
   (again, see "Key principle").
3. **`../docs/atlas_data_model.md`** is a best-effort, human-maintained
   description of both of the above — genuinely useful for the
   conceptual decision test below (Entity/Instrument/Position) and as a
   starting orientation, but it can lag either the live schema or the
   SDK, and it is never where a disagreement gets resolved. Read it for
   orientation; verify anything load-bearing against #1 or #2.

## The decision test (summary — see `../docs/atlas_data_model.md` for the full version)

For every discrete fact in any source:

1. Is this about the **legal person itself**, independent of any claim it issued?
   → **Entity** (`ENTITY_ATTRIBUTE`, `ENTITY_NAME`, `ENTITY_RELATIONSHIP`, `ENTITY_TYPE`, …)
2. Is this about the **terms of a specific claim**, shared by everyone who holds it?
   → **Instrument** (`INSTRUMENT` columns, `INSTRUMENT_ATTRIBUTE`, `INSTRUMENT_FEE`, …)
3. Is this **specific to one holder's economics** on that claim?
   → **Position** (`POSITION_ATTRIBUTE`)

## Key principle

EAV tables (`*_ATTRIBUTE`, `*_FEE_ATTRIBUTE`) are **not** freely extensible in the SDK,
despite the underlying Atlas Postgres schema being EAV-shaped. The SDK's attribute
name fields are typed enums (`EntityAttributeName`, `ManagementFeeAttributeName`,
`PerformanceFeeAttributeName`, `InstrumentAttributeName`, ...) with a fixed, finite
value set plus a generic `unknown_default_open_api` fallback. **A source fact that
needs a name not already in the enum requires an actual PR to the SDK to add that
enum value** — you cannot just invent a new attribute name and expect it to be a
valid payload. This corrects earlier guidance in `knowledge/mapping_guide.md` that treated
fee attributes as freely extensible (the tiered-carry "just add `tier_N_rate`"
convention) — confirmed wrong by inspecting the real enums: `ManagementFeeAttributeName`
and `PerformanceFeeAttributeName` each have only 4 real values, no tier variants.

Do not rely on any hardcoded table list — read `../docs/atlas_data_model.md` for the
canonical inventory, then verify against the live schema. Tables get added between
sessions and neither this skill nor the doc is guaranteed current.

When in doubt about a payload shape or enum, **don't guess — introspect the installed
package directly**:
```python
from opto_atlas_service.models.entity_attribute_name import EntityAttributeName

print([v.value for v in EntityAttributeName])
from opto_atlas_service.models.entity_create_input_record import EntityCreateInputRecord

print(EntityCreateInputRecord.model_fields)  # real field names + types, not assumptions
```
Every guessed enum/field-shape in earlier sessions turned out to have at least one
wrong detail once actually checked this way. Always verify before proposing a payload.

## Atlas SDK payload shapes

The actual target for the data agent is not Atlas tables directly — it's the
`opto-atlas-service` Python SDK payloads. The SDK is published as the
`opto_atlas_service` package on the AWS CodeArtifact package repository —
that is also where its documentation (endpoint and model reference) lives.

### Getting access

The package is `opto-atlas-service` (hyphenated on PyPI/CodeArtifact,
imported as `opto_atlas_service`). It's published on Opto's private AWS
CodeArtifact registry, not public PyPI.

```bash
clopto login --profile dev   # saves AWS creds as uv credentials for CodeArtifact

uv pip install opto-atlas-service \
  --index-url https://opto-193622925024.d.codeartifact.us-east-2.amazonaws.com/pypi/python/simple/
```

Once installed, the model definitions are importable directly
(`from opto_atlas_service.models import ...`) and the package's own docs/
docstrings are the reference for the SDK's payload shapes and endpoints.

### Three endpoints

1. **`create_entities`** — `EntityCreateRequest` containing `EntityCreateInputRecord`s
   - Real fields (verified against installed package, not guessed):
     `as_of` (**date, not datetime** — top-level record `as_of` is a plain date, same
     as the per-attribute `as_of` below; corrected after being documented wrong here
     once already), `silver_id` (plain string — just the source's own
     UUID, no prefix scheme), `name`/`name_type`/`identifier`/`identifier_type`
     (singular convenience fields) plus `names[]`/`identifiers[]` (lists of
     `EntityNameCreate`/`EntityIdentifierCreate`, each with their own `valid_from`/
     `valid_to`), `types[]` (list of `EntityTypeCreate{entity_type, valid_from, valid_to}`),
     `attributes[]` (list of `EntityAttributeCreate`), `relationships[]`
     (list of `EntityRelationshipCreate`), `strategies[]` (list of `EntityStrategyCreate`),
     `analytics[]` (list of `AnalyticsCreate`), `tags[]`, `operational_phases[]`, `valuations[]`.
   - `EntityAttributeCreate` fields: `as_of` (date, required, per-attribute — not
     just the record-level one), `attribute_name` (enum), and exactly one typed
     value field: `attribute_value_text` / `attribute_value_numeric` /
     `attribute_value_integer` / `attribute_value_boolean` / `attribute_value_date`.
     There is no generic `"value"` key — pick the field matching the fact's type.
   - `EntityRelationshipCreate.target_entity_id` is a **resolved Atlas UUID**, not a
     silver_id. If both entities in a relationship are new, the relationship can't
     be embedded in the same batch — it's a follow-up write once the target entity's
     real `entity_id` exists. The data agent tracks this as its own
     dedicated row in `output.gate_relationship` (not inside `gate_verdict`,
     and never with a placeholder in `target_entity_id`) — see
     `knowledge/ingest_gate_schema.md`'s `gate_relationship` section. A fund/instrument's
     own verdict never waits on its parent's — only the relationship itself
     does.
   - `EntityStrategyCreate` fields: `strategy_group_id` (**required** — a UUID;
     when there's no natural grouping id from the source, generate a fresh one
     per logically-related set of strategy rows, e.g. all tiers assigned from
     the same classification pass), `strategy_system` (enum:
     `INTERNAL`/`MSCI`/`SEC_ADV`), `strategy_tier` (free text, e.g. `'industry'`),
     `strategy_value` (free text, e.g. `'Industrials'`), `valid_from` (**required**),
     `valid_to` (**required as a key, but accepts `null`** — confirmed via live
     Swagger validation: all three of `strategy_group_id`/`valid_from`/`valid_to`
     throw "Field required" if the key is missing entirely, not just if null).
     **There is no weight/percentage field, and this is deliberate, not a gap** —
     a static weight baked in at ingest time is a malformed model: allocation
     weights drift over time and must be derived/computed, not hardcoded from a
     single marketing snapshot (worse, the old convention derived them from a
     "best guess" off category names). Don't propose adding a weight field here.
   - Entity types: see `EntityType` enum — ~20 values including
     `management_company`, `fund_vehicle`, `spv`, `co_investment`,
     `registered_advisor`, `general_partner`, `limited_partner`, `family_office`, etc.

2. **`create_instruments`** — `InstrumentCreateRequest` containing `InstrumentCreateInputRecord`s
   - Real fields: `as_of` (date, top-level, same correction as `create_entities` above), `entity_id` (the issuing entity's resolved Atlas ID),
     `silver_id`, `name`/`name_type` + `names[]`, `types[]` (list of
     `InstrumentTypeCreate{instrument_type, valid_from, valid_to}`), `attributes[]`
     (list of `InstrumentAttributeCreate`, same typed-value-field shape as entity
     attributes), `fees[]` (list of `InstrumentFeeCreate{fee_type, valid_from,
     valid_to, attributes[]}` — the fee wrapper itself has no `as_of`, only its
     nested `FeeAttributeCreate`s do), `analytics[]`, `identifiers[]`, `coupons[]`,
     `lifecycle_status`, `valuations[]`.
   - Instrument types (`InstrumentType` enum): `debt`, `lp_interest`, `gp_interest`,
     `jv_interest`, `co_investment`, `carry_interest`, `preferred_stock`,
     `common_stock`, `safe`, `convertible_note`, `warrant`, `undisclosed`.
   - Fee types (`FeeType` enum): `management`, `performance`, `administration`,
     `transaction`, `incentive`.
   - `ManagementFeeAttributeName` — **only 4 real values**: `investment_rate`,
     `investment_basis`, `harvest_rate`, `harvest_basis` (+ `unknown_default_open_api`).
   - `PerformanceFeeAttributeName` — **only 4 real values**: `performance_rate`,
     `hurdle_rate`, `hurdle_type`, `waterfall_method` (+ `unknown_default_open_api`).
     No catch-up-rate value exists either.
   - `InstrumentAttributeName` — 16 values, several debt-specific
     (`maturity_date`, `seniority`, `facility_type`, `covenant_lite`) and not
     applicable to `lp_interest`; the relevant subset for LP interests is roughly
     `currency`, `issue_date`, `eligible_investor_type`, `tax_status`,
     `min_initial_investment`, `avg_lp_investment_min`, `avg_lp_investment_max`.

3. **`create_positions`** — not yet used by the data agent.

### The request wrapper — `IngestionSource` lineage, and where `org_id` actually goes

Everything above (`attributes[]`, `fees[]`, etc.) lives on the *record*
(`EntityCreateInputRecord`/`InstrumentCreateInputRecord`). But those records
don't get submitted alone — they're wrapped in `EntityCreateRequest`/
`InstrumentCreateRequest`, and **that wrapper is where lineage and tenant
identity actually live**:

```
EntityCreateRequest / InstrumentCreateRequest fields:
  group_key (str, required), org_id, pipe_run_id, pipe_type,
  records[], source_external_key, source_type, uploaded_by
```

This matches `IngestionSourceCreate` almost exactly (same fields), because
submitting a batch **is** how an `IngestionSource` row gets created (or
matched to an existing one) — there's also a standalone
`create_ingestion_source` call (`InternalIngestionSourcesApi`) if you want
an `ingestion_source_id` back before submitting any records, but for this
agent's purposes the inline path is simpler.

Per `atlas_data_model.md`'s "Ingestion Source: The Critical Foundation":
every fact in Atlas is stamped with exactly one `ingestion_source_id` — it's
the single FK behind entitlement (access control is a join against
`entitlement_group`), correction/replay (close one source's link, replay
its snapshotted payload against the right anchor, without touching any
other source's claim), and cascade-delete ordering. **"One row = one
source's claim, never blended"** — if two sources agree or disagree about a
fact, that's always two independent, separately-traceable rows.

- `IngestionSourceType` enum — **only 6 real values**: `arch`, `manual`,
  `msci`, `pitch_deck`, `sec_adv`, `sec_edgar` (+ `unknown_default_open_api`).
  No `security_master` value exists. **Decided: Security-Master-sourced
  data uses `manual`.** Not a placeholder pending a future PR — this is
  the settled choice; it only changes if that decision changes.
- `org_id` on the request — "organization that owns or uploaded this
  source," used downstream by the (not-yet-implemented)
  `SOURCE_RECORD_OWNERSHIP`/`ORG_SOURCE_ENTITLEMENTS` tables for
  proprietary-source access control. **For any multi-tenant source, this
  is the source record's own `org_id`, per record — never a run-wide
  constant.** See `knowledge/mapping_guide.md`'s "Security Master is multi-tenant"
  section for the confirmed source-specific case and the full reasoning;
  this is the general Atlas-side rule only.
- `group_key` (required, no default) — "the type of source we group
  individual ingestion runs by" (e.g. `form_adv_monthly`). For this agent:
  the constant `'data-agent'`.
- `pipe_type`/`pipe_run_id`/`uploaded_by`/`source_external_key` — not this
  agent's concern; the downstream Dagster pipe that actually calls these
  endpoints fills these in automatically. Don't populate or guess a
  convention for any of these.

### Multi-tenant sources — general rule

Some sources are multi-tenant (the same real-world legal person can exist
as separate rows under different `org_id`s). When that's true: `silver_id`
stays each record's own id, per org/tenant — never force two tenants'
records to share an identity value, that's Atlas's own entity-resolution
job, not the agent's. `org_id` on the request is that record's own
`org_id`. **See `knowledge/mapping_guide.md`'s "Security Master is multi-tenant"
section for the confirmed, worked case** (Zero Prime's 66 `org_id`s, the
Silver Lake lineage-field correction, the `universal_id`-to-canonical-name
naming adjustment) — that source-specific reasoning belongs there, not
here; this skill only states the Atlas-side mechanic above.

### Analytics — where performance/target figures actually go

`AnalyticsCreate` fields: `as_of` (date), `metric` (`AnalyticsMetric` enum),
`observation_type` (`ObservationType` enum), `period` (`AnalyticsPeriod` enum,
optional), `return_basis` (`ReportingBasis` enum, optional), `value` (string).
This lives in `analytics[]` on **both** `EntityCreateInputRecord` and
`InstrumentCreateInputRecord` — which one a given fact belongs on, and which
`observation_type` applies, depends on the source (see `knowledge/mapping_guide.md`'s
analytics correction for the Security-Master-specific answer: almost always
the fund **entity**, not the instrument).

- `AnalyticsMetric`: `irr`, `tvpi`, `moic`, `dpi`, `rvpi`, `distribution_yield`,
  `return_annualized`, `return_cumulative`, `max_drawdown`, `sharpe_ratio`, `volatility`.
- `ReportingBasis`: `net`, `gross`.
- `ObservationType`: `target` (forward-looking, stated by the source for
  something not yet realized), `unverified` (a track-record claim from a
  source that can't be independently confirmed), `reported` (attestable —
  audited financial statement, administrator NAV), `projected` (modeled/
  derived rather than source-stated; not yet used by this agent). Which of
  these applies to a given source's figures is a source-specific judgment
  call — see `knowledge/mapping_guide.md` for the Security-Master case.

### Naming — `EntityNameType` enum

`EntityNameType`: `legal_name`, `brand_name`, `short_name`. Which one applies
to a name extracted from a given source depends on the source's own
provenance (a public filing vs. marketing material, for instance) — see
`knowledge/mapping_guide.md`'s "Naming convention" note for the confirmed
Security-Master rule and why it was picked.

### Other enums

- `RelationshipType`: `has_subsidiary`, `manages`, `advises`, `feeds_into`,
  `successor_to`, `merged_into`, `employs`, `owns_equity_in`, `guarantees`.
- `RelationshipRole` (for `target_entity_role`): `parent`, `child`.
- `EntityIdentifierType`: `crd`, `cik`, `ticker`, `cusip`, `isin`, `sedol`, `lei`,
  `pitchbook_id`, `crunchbase_id`, `figi`, `sec_file_number`, `form_d_file_number`.
- `InstrumentIdentifierType`: `cusip`, `isin`, `sedol`, `figi`, `ticker`, `lx_id`,
  `bloomberg_id`, `refinitiv_id`.

The full model definitions and endpoint documentation are published with the
`opto_atlas_service` package on AWS CodeArtifact — that is the source of
truth, not a local `site-packages` install, and not this list either once
Atlas adds new enum values. Re-verify by introspection per the "Key principle" section above.
