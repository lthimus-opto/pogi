# Atlas Entity Research Guide

## Purpose

This is the playbook for **ad-hoc, read-only investigation** of a
real-world firm/manager/fund family inside Atlas — "what can you tell me
about X" style questions — as distinct from `mapping_guide.md` (which is
about writing new facts onto Atlas's ontology from a source). Both share
the same underlying schema and the same "authority: SDK > live schema >
docs" discipline from `atlas-ontology`, but the failure modes are
different: here the risk is **silently under-covering the real-world
entity** because Atlas represents it as more than one row, and because
`entity_relationship` is directional and has to be walked in both
directions and from more than one starting point.

**Confirmed incident behind this doc:** a real investigation of "8VC"
started from a single entity found by `entity_name ILIKE '%8VC%'`,
concluded "no instruments issued, no positions held, two sources only" —
and every part of that was wrong. The real SEC-registered legal entity
for the same firm was a second, unlinked `entity_id`
(`EIGHT PARTNERS VC, LLC`) advising 76 vehicles (vs. 20 found under the
brand-name entity), including an entire legacy pre-rebrand lineage
(`FORMATION8 PARTNERS FUND I/II`, `KODIAK FUND I`, `OFFSET FUND I`, `F8 *
SPV`) that shares zero substring overlap with "8VC" and was therefore
invisible to the name search that anchored the whole investigation. A
client fund also turned out to hold **active LP positions** in two 8VC
vehicles — missed because the query never checked position holdership
*into* the family, only load/instrument counts *out of* one entity.

**Second confirmed incident, same investigation, round two:** having fixed
the entity-resolution and "who holds a claim on the family's issued
instruments" gaps above, a follow-up report still claimed two small LP
positions (~$3M combined cost basis) were "the" 8VC exposure. They were
not. A third position direction was never checked: `position.holder_
entity_id` set to one of the family's **own vehicle entity_ids** —
i.e. the fund itself acting as the investor into portfolio companies
(a look-through schedule of investments). `8VC Fund VI, L.P.` alone
turned out to hold **133 ACTIVE positions in 99 distinct portfolio
companies**, worth ~$725M cost basis / ~$1.46B fair value — two orders
of magnitude larger than the LP-side exposure that had just been
reported as definitive. The mistake: "who holds a claim on an
instrument the family issued" and "what does the family hold as an
investor in its own right" are different questions with different join
directions on the *same* `position` table, and checking one is not
evidence about the other.

## The core risk: one real-world firm, N Atlas entity rows

Atlas does **not** guarantee a single canonical entity per real-world
legal person. The same firm can appear as:

- A brand-name entity from one source (e.g. Security Master's manager
  row, or a diligence-deck extraction) — often `MANAGEMENT_COMPANY`.
- A separately-ingested SEC-registered legal entity from Form ADV data
  (`SEC_ADV` source type) — often typed `EXEMPT_REPORTING_ADVISER`/
  `VENTURE_CAPITAL_ADVISER`/`PRIVATE_FUND_ADVISER` — under its *official*
  legal name, which can differ completely from the brand name (rebrands,
  "doing business as," predecessor-firm names before a rename).
- A legacy/predecessor entity for an older brand (pre-rebrand fund
  vehicles keep their original names forever — Atlas doesn't rename
  history).

**These rows are frequently not linked to each other by any
`entity_relationship` row.** Checking for a direct link is necessary, not
optional — and its absence is itself a finding worth reporting (an
entity-resolution gap), not something to paper over by assuming the
brand-name entity is the whole picture.

## Starting-point checklist — never stop at the first entity found

1. **Name search is a starting point, never the full scope.** `entity_name
   ILIKE '%<brand>%'` only finds entities whose *current or historical
   name string* contains that brand. It will never find a legally
   distinct name for the same real firm (legacy brand, SEC legal name,
   "doing business as," a typo'd/abbreviated variant). Follow every hit's
   `entity_relationship` edges (both directions — see below) before
   treating the name-search result set as complete.
2. **Check `entity_identifier` and `entity_type` for a second anchor.**
   A `PITCHBOOK_ID`/`CRUNCHBASE_ID`/`CRD`/`CIK` on one row is a strong
   signal to search Atlas again by that identifier type, independent of
   name, in case a different-sourced row for the same firm carries the
   same external ID (confirms a merge candidate even without a
   relationship row).
3. **Always query `entity_relationship` in both directions** for every
   candidate entity — as `parent_entity_id` (what it manages/advises/
   owns) **and** as `child_entity_id` (who manages/advises/owns it, and
   crucially, whether some *other* entity_id also claims to manage the
   same children — that's the tell that you have two unlinked manager
   identities for one firm, as in the 8VC/Eight Partners case).
4. **`relationship_type` matters** — `MANAGES` and `ADVISES` are
   distinct edges in the live enum (`RelationshipType`: `has_subsidiary`,
   `manages`, `advises`, `feeds_into`, `successor_to`, `merged_into`,
   `employs`, `owns_equity_in`, `guarantees`) and different sources tend
   to populate different ones for the same real relationship (internal/
   security_master data tends to use `MANAGES`; SEC Form ADV data tends
   to use `ADVISES`). **Query for all relationship types, not just the
   one the first source happened to use** — restricting to `MANAGES`
   alone is exactly how the 76-vehicle `ADVISES` universe got missed.
5. **Once you have every candidate entity_id for the real firm, re-run
   the entity/instrument/position footprint query against the union of
   all of them, not just the first one found.** Reporting "no
   instruments/positions" based on one entity_id when a second,
   unlinked entity_id for the same firm has the real footprint is the
   exact mistake this doc exists to prevent.

## Walking the fund family — concrete query pattern

Starting from one or more manager/adviser entity_ids, get every vehicle
they touch and what each vehicle actually holds/has issued in one pass
(adapt entity_ids as needed):

```sql
select
    m.entity_id as manager_entity_id, men.name as manager_name,
    er.relationship_type,
    v.entity_id as vehicle_entity_id, ven.name as vehicle_name,
    vet.entity_type as vehicle_type,
    i.instrument_id, inm.name as instrument_name, it.instrument_type,
    p.position_id, p.status as position_status,
    p.holder_entity_id, hen.name as holder_name
from entity_relationship er
    join entity m on m.entity_id = er.parent_entity_id
    join entity v on v.entity_id = er.child_entity_id
    left join lateral (select name from entity_name where entity_id = m.entity_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) men on true
    left join lateral (select name from entity_name where entity_id = v.entity_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) ven on true
    left join lateral (select entity_type from entity_type where entity_id = v.entity_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) vet on true
    left join instrument i on i.entity_id = v.entity_id
    left join lateral (select name from instrument_name where instrument_id = i.instrument_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) inm on true
    left join lateral (select instrument_type from instrument_type where instrument_id = i.instrument_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) it on true
    left join position p on p.held_instrument_id = i.instrument_id and p.status = 'ACTIVE'
    left join lateral (select name from entity_name where entity_id = p.holder_entity_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) hen on true
where er.parent_entity_id in (/* every manager/adviser entity_id found above */)
order by holder_name nulls last, vehicle_name, instrument_name;
```

Notes on why it's shaped this way:
- `left join instrument`/`position` (not inner) — most vehicles in a
  real fund family are name/identifier stubs with nothing loaded yet;
  an inner join silently drops them from view and makes the family look
  smaller than it is.
- The lateral `order by (valid_to is null) desc, valid_from desc,
  recorded_at desc limit 1` pattern is the standard "current-preferred,
  else most-recent-historical" pick for any `*_name`/`*_type` table —
  use it instead of a plain `valid_to IS NULL` filter, which silently
  returns nothing for a row whose current record hasn't been
  re-asserted by a recent source even though a historical one exists.
- `p.status = 'ACTIVE'` on the position join — always filter position
  status explicitly; don't assume an unfiltered position table reflects
  only current holdings (closed/`LOGICALLY_DELETED` positions stay in
  the table — see the 8VC case where one of the client's own positions,
  into an unrelated manager, was `LOGICALLY_DELETED` and would have
  overstated the client's live book if counted).

## Checking whether anyone holds a position *into* the family (not just what it holds)

The footprint query above only looks at what a vehicle *issued* and who
holds *that*. Separately check the reverse direction — does any entity
(especially a known client fund) hold an LP/GP interest in one of this
family's vehicles:

```sql
select en.name as holder, inm.name as lp_interest,
       i.entity_id as fund_entity_id, p.position_id, p.status
from position p
    join instrument i on i.instrument_id = p.held_instrument_id
    left join instrument_name inm on inm.instrument_id = i.instrument_id and inm.valid_to is null
    left join entity_name en on en.entity_id = p.holder_entity_id and en.valid_to is null and en.name_type = 'LEGAL_NAME'
where i.entity_id in (/* every vehicle entity_id in the family */);
```

Or, if you already know the holder (a specific client fund entity_id),
flip it — `where p.holder_entity_id = '<known holder>'` and look for the
family's vehicle names in the result. Both directions matter: "what does
X hold" and "who holds a claim on X" are different questions with
different query shapes, and a research answer that only covers one
direction is incomplete by default.

## Checking what the family's own vehicles hold as an investor (look-through SOI)

**This is a third, distinct direction from the two above — don't stop
at two.** The footprint query checks what a vehicle *issued* (who holds
a claim on it). The reverse-direction query above checks whether some
outer entity (e.g. a client fund) holds a claim *into* the family. Both
of those treat every family vehicle purely as an *issuer*. But a fund
vehicle is also routinely a **holder** in its own right — a VC fund's
own look-through schedule of investments, where the fund invests into
portfolio companies that are themselves entities elsewhere in Atlas.
Query `position.holder_entity_id` against the family's vehicle
entity_ids directly:

```sql
select p.holder_entity_id, hen.name as holder_vehicle_name,
       count(distinct p.position_id) as n_positions,
       count(distinct i.entity_id) as n_portfolio_companies
from position p
    join instrument i on i.instrument_id = p.held_instrument_id
    left join lateral (select name from entity_name where entity_id = p.holder_entity_id
        order by (valid_to is null) desc, valid_from desc, recorded_at desc limit 1) hen on true
where p.holder_entity_id in (/* every vehicle entity_id in the family, not just the manager/adviser ids */)
group by p.holder_entity_id, hen.name
order by n_positions desc;
```

**Confirmed finding this catches:** in the 8VC investigation, this
exact query surfaced that `8VC Fund VI, L.P.` alone holds 133 ACTIVE
positions across 99 distinct portfolio companies (~$725M cost basis /
~$1.46B fair value) — a look-through SOI dataset that dwarfed the ~$3M
of LP-side exposure found by the other two directions combined. A
report that only covers "who holds the family's issued LP interests"
is answering a narrow question (client exposure into the family) and
must not be presented as "the" position picture for the family — state
explicitly which of the three directions (issued-and-held-by-others,
held-by-a-known-party, held-by-the-family-itself) a given number comes
from. All three use the same `position` table but opposite join sides,
so checking one is never evidence about another.

## Valuation — don't collapse to "latest row" when a time series exists

`valuation` is scoped (`ENTITY`/`INSTRUMENT`/`POSITION` via `scoped_to`)
and carries `valuation_method` (`COST_BASIS`/`FAIR_VALUE`/`FACE_VALUE`)
and `reporting_state` (`AUDITED`/`UNAUDITED`) as **separate rows for the
same `position_id`/`as_of`**, not columns. A naive `DISTINCT ON
(position_id) ... ORDER BY as_of DESC` grabs one arbitrary method/state
combination per position and silently drops the others. Pivot explicitly
when the real question is "what's the cost basis vs. fair value history
for this holding":

```sql
with pivoted_valuation as (
    select
        position_id, as_of, investment_date, reporting_currency,
        max(case when valuation_method = 'COST_BASIS' then value end) as cost_basis,
        max(case when valuation_method = 'FAIR_VALUE' then value end) as fair_value,
        max(case when valuation_method = 'FACE_VALUE' then value end) as face_value,
        max(case when valuation_method = 'FAIR_VALUE' then per_unit_value end) as fmv_per_unit,
        max(units_outstanding) as units_outstanding,
        case when bool_or(reporting_state = 'AUDITED') then 'AUDITED' else 'UNAUDITED' end as reporting_state
    from valuation
    where scoped_to = 'POSITION' and position_id in (/* positions of interest */)
    group by position_id, as_of, investment_date, reporting_currency
)
select * from pivoted_valuation order by position_id, as_of;
```

A fund's reported performance at a given `as_of` is frequently
`AUDITED` once a year (fiscal year-end) and `UNAUDITED` the other
quarters — report that distinction when asked about current marks; don't
imply every data point carries the same confidence.

Also prefer filtering to the source that actually owns the valuation
series you care about (`ingestion_source_group_key = 'arch_soi'` for
look-through schedule-of-investments data, for instance) and to
`observation_type = 'REPORTED'` when the question is about attested
figures specifically, rather than blending `REPORTED`/`UNVERIFIED`/
`TARGET` rows that happen to share a `position_id`.

## Position lineage — checking review/entitlement coverage

To see which ingestion source(s) actually back a given position (useful
for "how trustworthy is this row" or "has this been reviewed yet"):

```sql
select p.position_id, p.holder_entity_id, p.status,
       pis.ingestion_source_id, pis.input_id, pis.valid_from, pis.valid_to, pis.recorded_at
from position p
    join position_ingestion_source pis using (position_id)
where p.held_instrument_id = '<instrument_id>' and pis.valid_to is null
order by pis.recorded_at;
```

Join to `ingestion_source` for `source_type`/`group_key`/`entitlement_group`/
`reviewed_at` when the question is about data-quality coverage (what
fraction of this fund's positions are still unreviewed, which was a real
finding worth surfacing in the 8VC Fund VI case — ~75% of its ARCH-sourced
position links were unreviewed).

## Reporting discipline for this kind of question

- **State which entity_ids you investigated and why**, including any
  second/legacy identity found and whether it's linked to the first. A
  reader needs to know the scope was the *real firm*, not one row that
  happens to carry its most recognizable name.
- **Don't report an absence (no instruments/positions/relationship) as a
  property of the firm** when it might just be a property of the one
  entity_id you happened to check. Phrase it as scoped to the entity_id
  until the broader search comes back empty too.
- **Report all three position directions** (who holds the family's
  issued instruments / whether a known holder has a claim into the
  family / what the family's own vehicles hold as investors
  themselves) even if the user's question only implies one — leaving
  out the "fund as holder" look-through direction is how a ~$3M
  LP-side number got reported as definitive while a ~$725M/$1.46B
  look-through SOI sat unexamined one query away.
- **Never call one direction's number "the" exposure/position/
  footprint for the family.** Label it explicitly by direction (e.g.
  "client LP positions into the family," "family's own look-through
  SOI holdings") so a reader can't mistake a partial number for the
  whole picture.
- Flag unlinked-but-clearly-same-firm entity pairs explicitly as a
  data-quality observation, the same way `failure_modes.md` entries get
  flagged — this agent's broader mandate is data quality, and an
  unmerged manager identity is squarely that, even outside a formal
  `gate_verdict` run.
