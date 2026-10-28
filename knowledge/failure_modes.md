# Failure Mode Catalog

## Purpose

A living catalog of confirmed data-quality failure modes found while mapping
and scoring Security Master against Atlas. Entries here are the vocabulary
the `accuracy_failure_mode` field in `knowledge/ingest_gate_schema.md`'s `gate_verdict`
table points to — this doc is where the meaning lives, that table just
references it by name.

Every entry needs a real, confirmed instance before it's added. We don't
catalog hypothetical failure modes — see `knowledge/mapping_guide.md`'s note on
incidents vs. failure modes: an incident is one bad row you found; a
failure mode is the generalized, falsifiable predicate that would catch it
again, checked against more than the one case that revealed it.

---

## Two QC dimensions, not one blended verdict

`gate_verdict` scores every record on two independent things (see
`knowledge/ingest_gate_schema.md`):

- **Completeness** — is there enough mapped data (weighted core vs.
  supplementary fields) to be useful at all? This is a generic,
  computed ratio-based rule — it doesn't need a catalog entry per source,
  and most records' completeness result needs no special-casing.
- **Accuracy** — does the content contradict itself, or otherwise look
  confidently wrong, regardless of how complete it is? **This catalog is
  almost entirely about accuracy.** A record can be fully filled in and
  still be wrong — e.g. a fund's name contains "Credit" but its mapped
  strategy says "Private Equity" — and no amount of field-counting
  catches that; only checking content against itself does.

A few entries below are genuinely about completeness rather than accuracy
(see entry 2) — those exist as named, confirmed instances that corroborate
the generic completeness rule's default behavior, not as overrides of it.
Entries flagged **accuracy** can override an otherwise-passing completeness
result — see the verdict truth table in `knowledge/ingest_gate_schema.md`.

**Removed entry**: `incomplete_for_lifecycle_stage` (previously #3) was
removed after review on Silver Lake — see `knowledge/mapping_guide.md`. It treated a
lifecycle/status field (`manager_fundraising_status='Closed'`) plus a low
fill rate as a self-contradiction forcing `REJECT`. On review this was
wrong on two counts: (1) fill rate is the completeness metric, not an
accuracy signal — using it to drive an accuracy `block` blended the two
dimensions the schema exists to keep separate; (2) a status field being
"Closed" makes no claim about how thoroughly SM's own extraction
pipeline documented that specific fund — a thin-but-Closed record means
"not enough information to conclude anything" (`DEFER`), not "confirmed
wrong" (`REJECT`). The entry's own "Status" note had already flagged this
risk as unresolved (no counter-example yet separating a real defect from
"this whole pull is light on closed deals") before Silver Lake supplied
exactly that counter-example (Partners VII rich, Partners I–VI thin, same
manager, same pull, same status). A lifecycle/status field should be
checked for self-consistency like any other field, not given a special
catalog rule of its own — a low fill rate on such a record now falls
straight through to the generic completeness rule as it does for any
other record.

Each catalog entry below states its **Dimension**, and if `accuracy`, its
**Severity**:

- **`block`** — confidently wrong; forces `verdict = REJECT` regardless of
  completeness.
- **`correct`** — confidently wrong, with a proposed fix; sets
  `accuracy_proposed_value` on the `gate_verdict` row, forces `DEFER`
  pending a human confirming the fix (never applied automatically).
- **`flag`** — looks off but not confidently wrong or fixable; forces
  `DEFER` with the anomaly described in `accuracy_reason`.

There is no separate correction table anymore (`ingest_correction_schema.md`
was dropped) — every `correct`-severity entry below writes its proposed
fix directly into `gate_verdict.accuracy_proposed_value` on the same row.

---

## How an entry is written

Every entry has:

1. **Name** — short, generalized (not tied to the one instance that found it)
2. **Dimension** — `completeness` or `accuracy`
3. **Severity** (accuracy entries only) — `block`, `correct`, or `flag`
4. **Trigger predicate** — the actual condition, in terms of columns
   available at check time
5. **Evidence** — what to capture so a human reviewing later doesn't have
   to re-run the investigation
6. **Effect on `gate_verdict`** — which columns this entry sets, and what
   that does to the final `verdict`
7. **Status** — how many confirmed instances, and whether the predicate
   has been checked against a wider population yet (not just the
   instance(s) that revealed it). This field exists specifically so we
   don't quietly promote an under-tested rule to "trusted."

---

## Catalog

### 1. `mislabeled_grouping_construct`

- **Dimension**: accuracy
- **Severity**: `correct` — the fix is confident and narrow (null out one
  attribute), not a whole-record block
- **Trigger predicate**: A source's grouping-only construct (fund family,
  or equivalent) is named after a vehicle *type* or generic bucket
  ("SPVs", "Other", "Miscellaneous") rather than a specific branded
  series.
- **Evidence**: The label text itself, plus the fill rate of the grouping
  row relative to its peers (in our case: 50% vs. ~81% for real families —
  the mislabeling and the emptiness co-occurred).
- **Effect on `gate_verdict`**: Doesn't block the record. Sets
  `accuracy_proposed_value = NULL` for `fund_family_label` — funds under
  the mislabeled group should be treated as ungrouped rather than
  inheriting the bad label. This is a mapping-time correction applied
  before completeness is even scored, so it typically doesn't change
  `verdict` on its own — it corrects one field, then the rest of the
  pipeline proceeds normally.
- **Status**: 1 confirmed instance (`SPVs`, 8VC dataset). Checked against
  a second, ten-manager dataset -- all 10 fund families there were properly
  branded and well-described, so the pattern didn't recur there. That
  absence is itself useful signal: it suggests this failure mode is
  genuinely uncommon rather than something the first pass was just bad at
  finding. Still only one instance total; needs more before it's a
  trusted rule rather than a manual flag.

### 2. `expected_incompleteness`

- **Dimension**: completeness (not accuracy — nothing contradicts itself
  here; the record is just genuinely thin, and the status field says so
  consistently)
- **Trigger predicate**: `fill_rate(record)` below threshold AND a
  lifecycle/status field indicates the record hasn't been worked yet
  (e.g. `MANAGER_FUNDRAISING_STATUS = 'Unknown'`).
- **Evidence**: fill rate, status value, list of missing fields.
- **Effect on `gate_verdict`**: Corroborates `completeness_passed = false`
  → `DEFER` (not a defect; hold, don't load, retry automatically the next
  time this record is re-pulled). This doesn't override anything — it's
  the same outcome the generic completeness rule would already produce;
  cataloguing it just gives `completeness_reason` a named, confirmed
  explanation ("Unknown status, pre-diligence, not a data defect") instead
  of a bare percentage.
- **Status**: **14 confirmed instances** across two independent sources
  (1 from the first, single-manager dataset; 13 from a second,
  ten-manager dataset). Every one was `MANAGER_FUNDRAISING_STATUS = 'Unknown'`
  with fill rate 31-44%. Strong enough now to treat as trusted rather than
  a candidate -- though it's still worth periodically checking that
  `Unknown` keeps meaning "not yet worked" as new sources are added, since
  the whole rule leans on that one status value.

### 3. `rollup_detail_mismatch`

- **Dimension**: accuracy — the textbook case: two mapped fields
  contradict each other
- **Severity**: `correct`
- **Trigger predicate**: A summary/rollup column's value contradicts the
  value implied by its own detail columns (or narrative text) on the same
  record, by a large, systematic factor.
- **Evidence**: rollup value, detail values, narrative/rich-text value if
  present.
- **Effect on `gate_verdict`**: `accuracy_proposed_value` = the
  detail-column value (or the narrative-implied one); `accuracy_reason`
  cites both conflicting values. Forces `DEFER` until a human confirms
  the correction — the record is otherwise fine, so completeness alone
  would likely say `LOAD`, but the contradiction downgrades it.
- **Status**: **3 confirmed instances** (Fund VI, Fund VII, Fund III all
  show top-level `MANAGEMENT_FEE = 0.2` vs. `MANAGEMENT_FEE_INVEST = 0.02`,
  with rich-text descriptions confirming 2% is correct). Checked against a
  second, unrelated ten-manager dataset -- zero rows there had both fields
  populated at all, so the pattern neither recurred nor was contradicted.
  Recurring across independent rows within the first dataset is still
  higher confidence than the single-instance entries above, but the
  absence in dataset 2 means it hasn't yet been seen to generalize beyond
  one manager's data.

---

## New entries added this session (with corrections folded in)

### 4. `narrative_rate_not_captured`

- **Dimension**: accuracy, borderline completeness — the structured field
  being empty looks like a completeness gap, but the fix requires reading
  narrative *content* to derive the value (the same mechanic as
  `rollup_detail_mismatch`), so it's catalogued here rather than left to
  the generic completeness rule. Not a simple correction, though: it
  requires extending the target EAV attribute vocabulary, not swapping
  one value for another.
- **Severity**: `correct`, but multi-value — one `gate_verdict` row still
  gets one `accuracy_proposed_value`, so a full tiered schedule needs a
  structured summary there (e.g. a short JSON-in-text or delimited
  description of every tier), with the exact attribute-chain detail
  spelled out in `accuracy_reason`, not spread across multiple rows or a
  separate table.
- **Trigger predicate**: A structured fee/term field (or its whole family
  of related fields) is empty, AND the paired narrative/rich-text field,
  after trimming whitespace and case-folding, is **not** empty/`NULL`,
  not a placeholder string (`'null'`, `'none'`, `'n/a'`, `'na'`, `'-'`,
  `'tbd'`), AND actually names a specific, extractable number or set of
  numbers for that same fact (contains a `%`/numeric rate token tied to a
  fee/rate keyword -- not just any non-empty text). **Confirmed real
  false-positive, do not repeat**: a full-source run fired this predicate
  on `management_fee_description_rich_text`/
  `performance_fee_description_rich_text` values that were the literal
  4-character string `'null'` (not SQL `NULL`, actual text written by a
  prior AI-extraction pass) on ~2,000 of 2,181 triggered instrument rows
  -- there was no narrative content to read at all, so the predicate
  should never have fired, and the resulting `accuracy_proposed_value`
  was the nonsensical literal `"null|null"` (the two placeholder strings
  concatenated, not a real parsed value). Checking for non-empty/non-NULL
  alone is not enough -- check for a placeholder string explicitly, and
  only fire once real numeric/rate content is confirmed present. A
  record whose narrative is genuinely empty/placeholder with no
  structured field either is a plain **completeness** gap, not an
  accuracy finding -- let the completeness rule handle it, don't route
  it through this failure mode just because the field exists.
- **The point of this failure mode -- always try to give the data a real
  home**: the broader goal across every failure mode in this catalog is
  to map any source fact that has a real home in Atlas's ontology, not to
  flag-and-stop at the first sign of friction. When this predicate
  legitimately fires (real rate content in narrative, structured field
  empty), `accuracy_proposed_value` must carry the **actual converted
  target value** -- e.g. narrative "2% of committed capital" converts to
  `management.investment_rate=0.02`, not the raw narrative sentence
  restated or concatenated. If the value genuinely can't be converted to
  an existing attribute (the tiered-schedule case below), say exactly why
  in `accuracy_reason` (missing enum, ambiguous basis, etc.) rather than
  leaving a placeholder in `accuracy_proposed_value`.
- **The distinction that matters**: if the narrative names one number,
  this is `rollup_detail_mismatch`'s shape -- a normal value correction.
  If it names a schedule (multiple values tied to a condition -- a tier
  table, a step structure), no single value fixes it, **and it needs a
  real SDK enum change before it can be mapped at all** -- correcting an
  earlier version of this entry, which assumed EAV attribute tables are
  freely extensible. Confirmed false by inspecting the installed
  `opto_atlas_service` package directly: `ManagementFeeAttributeName` and
  `PerformanceFeeAttributeName` are fixed 4-value enums, no `tier_N_rate`
  variant exists. Don't propose writing a new attribute name as if it
  were already valid -- propose the gap, with the exact schedule as
  evidence for the PR.
- **Evidence**: the narrative text, the full extracted schedule, and the
  exact `entity_id`/`instrument_id`/`fee_id` chain each new attribute
  would attach to *once the enum exists* -- a proposal isn't complete
  until that chain is named.
- **Effect on `gate_verdict`**: `accuracy_proposed_value` still carries
  the full extracted schedule (it's real, confidently-read content) but
  `accuracy_reason` must say this is **blocked on an SDK change**, not
  just "pending human review of a value." Forces `DEFER` either way --
  never applied automatically, and here it structurally *can't* be until
  the enum ships.
- **Status**: 4 confirmed instances now, across **two independent managers**.
  Originally 2 at the same manager (Hayfin) -- Hayfin Maritime Yield Fund
  II's 6-tier management fee by commitment size (17 attribute rows under
  one `fee_type=MANAGEMENT` fee), and a second Hayfin Maritime Yield Fund
  II finding: an 82.5% performance-fee catch-up provision with no
  `catchup_rate` attribute either. First attempt at the original instance
  got it wrong (see `knowledge/mapping_guide.md`'s "before proposing any
  correction") -- worth remembering this is an easy one to get wrong even
  once you know it's here.

  **3rd and 4th instances, different manager** (Security Master, org
  `2346b7f2...`, last-10-managers run): L+M Housing Fund VI's
  `performance_fee_description_rich_text` names a GP catch-up where the
  GP receives 60% of distributions until the GP has received 20% of total
  cumulative LP+GP distributions, then an 80/20 LP/GP split -- a more
  complex shape than Hayfin's flat 82.5% catch-up (this one has its own
  embedded hurdle, not just a rate), but the same underlying gap: no
  `catchup_rate` slot exists in `PerformanceFeeAttributeName` either way.
  Reinova Partners Energy Transition Fund I names a flat 50% catch-up the
  same way. Both funds' structured `performance_rate`/`hurdle_rate`
  values independently cross-checked clean against their own narratives
  (1.5%/1.75% management, 20%/20% carry, 7%/8% hurdle all matched) --
  the catch-up gap is the only thing uncaptured on either record. This is
  the third-instance-at-a-different-manager this entry was explicitly
  waiting for -- strong enough now to say the gap generalizes beyond
  Hayfin's documents, not just a quirk of one manager's drafting style.

  **Correction, confirmed false-positive at scale**: a full-source
  Security Master run (org `2346b7f2...`) fired this predicate 2,181
  times across instrument rows; manual spot-check of a sample (e.g. 8VC
  Fund IV) found the narrative fields held the literal placeholder string
  `'null'`, not real content -- an estimated ~2,000 of the 2,181 were
  false positives from the missing placeholder-string guard, not
  genuine narrative-rate instances. The 4 confirmed real instances above
  (Hayfin x2, L+M Housing, Reinova) remain the only verified cases this
  entry is based on; the trigger predicate above was tightened
  accordingly (placeholder-string exclusion + require actual numeric/
  rate content) specifically to stop this recurring. Any future run
  should expect this predicate to fire far less often than 2,181/4,738
  once the guard is applied -- a similarly high hit rate on a future run
  is itself a signal the guard regressed, not that the source got worse.

---

### 5. `possible_misattributed_manager`

- **Dimension**: accuracy — the fund's own name contradicts its claimed
  manager relationship
- **Severity**: `block` — not because it's confirmed wrong, but because it
  can't self-resolve and needs a human ruling (per the README's "when a
  change needs Jake's ruling" note)
- **Trigger predicate**: A fund's own name shares no meaningful word
  (excluding generic corporate suffixes -- "Partners," "Capital," "Fund,"
  etc.) with its linked manager's name, and that mismatch is a one-off
  within its fund family rather than consistent across every fund in it.
- **The discriminator**: consistency across siblings. If every fund in
  the family mismatches the manager name the same way (Tourmalet
  Advisors / "Matawin" funds, 0-for-3), that reads as a legitimate trade
  name -- flag it as a missing `brand_name` `ENTITY_NAME`, not an error.
  If most of the family matches and one fund doesn't (Peakline Partners /
  "Cresset Partners Private Credit Fund," 1-for-2), that's the actual
  anomaly -- either the `FUND_FAMILY_ID`/`MANAGER_ID` link is wrong, or
  the real relationship is a feeder/introduction rather than `manages`,
  and loading an `ENTITY_RELATIONSHIP` from it without checking risks
  writing a wrong fact.
- **Evidence**: the name-overlap check result for every fund in the
  family, not just the flagged one -- the single-fund result alone can't
  tell benign from wrong.
- **Effect on `gate_verdict`**: Forces `verdict = REJECT` on the specific
  fund's relationship, regardless of completeness.
- **Status**: 1 confirmed instance (Cresset Partners Private Credit Fund
  under the Peakline family). The name-overlap check has a known
  false-positive mode: acronyms ("FCM Cat Fund, Ltd." under Fermat
  Capital Management) look like mismatches but aren't -- the check has no
  way to recognize an initialism. Needs more instances before the
  threshold for "how much of the family must mismatch before it's
  suspicious" is anything but a judgment call.

  **2nd confirmed instance**: "MLoan SICAV, S.A." under Muzinich & Co's
  "Muzinich Parallel Lending" family -- shares no word with the manager
  name, and its 4 siblings split into two consistent sub-brands
  ("Diversified Enterprises Credit*", 3 funds; "Muzinich Parallel Lending
  US", 1 fund matching the manager directly) that MLoan SICAV matches
  neither of -- the exact one-off-within-an-otherwise-consistent-family
  shape this entry describes. (This fund's manager also independently
  carries `ai_generated_preview = true` -- entry 6 below -- so in practice
  this specific record is `REJECT`'d by both rules; the misattribution
  finding stands on its own regardless and is kept as the second
  confirmed instance.) 2 confirmed instances total now -- still worth a
  third from an unrelated manager before fully trusting the
  family-consistency discriminator in general, but two independent
  managers is meaningfully stronger than one.

  **Discriminator refinement, confirmed real near-miss**: the consistency
  discriminator above ("one-off within the family" = anomaly, "every
  fund mismatches the same way" = legitimate trade name) is necessary but
  **not sufficient** once the mismatch spans *multiple whole fund
  families* under one manager, not one fund in one family. CVC Capital
  Partners' `MANAGES` edges include eight "Marathon"-branded funds across
  three separate fund families (Marathon CMBS Dislocation Fund, Marathon
  Distressed Credit, Marathon Secured Private Strategies) -- by the
  consistency discriminator alone this reads as a clean, legitimate
  trade-name pattern (every Marathon fund mismatches CVC's name the same
  way). It was flagged as a likely misattribution in a real session
  anyway, because the scale (three whole families, not one fund) looked
  like a stronger version of this same failure mode. It wasn't: CVC
  Capital Partners acquired Marathon Asset Management, a real, public
  acquisition -- the acquired firm's funds keeping their own established
  brand post-acquisition is exactly this shape. This agent has no way to
  independently verify an acquisition happened, so the rule going
  forward: **once a mismatch spans multiple whole fund families under
  one manager (not a single fund in one family), surface it as "here's
  what the data shows, does this match a known corporate event?" rather
  than asserting misattribution** -- don't let the consistency
  discriminator alone clear it, and don't let the larger scale alone
  condemn it either. 1 confirmed instance of this shape (CVC / Marathon,
  org `2346b7f2...`).

---

### 6. `ai_generated_preview_not_onboarded`

- **Dimension**: accuracy
- **Severity**: `block` — the record was never confirmed by SM's own review
  pipeline; nothing about its content can be trusted as final, no matter how
  complete or internally consistent it looks.
- **Trigger predicate**: `ai_generated_preview = true` on the record's own
  row -- checked independently at **every** level (`manager`, `fund_family`,
  `fund`, `security`), not inherited from a parent. `initially_ai_generated`
  is a different, weaker signal ("was this originally produced by AI" --
  true for plenty of now-fully-reviewed records, e.g. Acorn Capital
  Management's manager/fund rows) and must not be confused with
  `ai_generated_preview` ("is this *still* an unreviewed preview, right
  now"). Only `ai_generated_preview` drives this rule.
- **Evidence**: `ai_generated_preview`/`initially_ai_generated` values on the
  flagged row, plus whether the flag is consistent across the record's own
  parent/children (in the confirmed instances so far, it always has been --
  a manager's `ai_generated_preview` and every fund/security under it agreed,
  100% one way or the other).
- **Effect on `gate_verdict`**: Forces `verdict = REJECT` regardless of
  completeness or any other accuracy finding -- `accuracy_proposed_value`
  stays `NULL` (nothing to correct; the record simply isn't ready to be
  looked at as data yet, independent of whether its content is right).
  `accuracy_reason` should state the flag value and, if the record is an
  isolated single-extraction with no corroborating data elsewhere (no
  prior session, no field_provenance beyond the one extraction task that
  produced the preview), say so explicitly -- that absence of any other
  support is itself part of why the record isn't ready, not just the flag.
- **Status**: Confirmed on a real run across 6 managers and every
  fund_family/fund/security under them in one pull (BH3 Fund Advisors,
  Farallon Capital Management, both "Muzinich & Co" rows, Propel Equity,
  TANDEM VENTURES) -- the flag was 100% consistent top-to-bottom within
  each manager's whole subtree in every instance checked. Strong enough to
  treat as trusted immediately given how directly it maps to SM's own
  stated semantics ("this is a preview, not yet onboarded"), not just an
  inferred pattern -- confirmed directly by a human (Lucie) rather than
  discovered by the agent.

  **Explains, and supersedes, an observation from the same run that
  almost became its own catalog entry**: the two "Muzinich & Co" manager
  rows (same `org_id`, created 32 seconds apart, disjoint fund sets, no
  overlapping data) looked at first like a distinct `duplicate_manager_creation`
  failure mode worth cataloguing on its own. It wasn't -- both rows carry
  `ai_generated_preview = true`, so both are already `REJECT` under *this*
  rule regardless of the duplication. The duplication is real and worth
  noting in `accuracy_reason` as a second, independent reason not to trust
  either row (an isolated single-extraction preview with nothing
  corroborating it is weaker evidence than a duplicate preview that at
  least has a second copy backing it up), but it does not need, and should
  not get, its own catalog entry -- there is no confirmed case yet of two
  *onboarded* (`ai_generated_preview = false`) manager rows for the same
  real-world manager under one org_id. If that ever shows up, *that* would
  be the real `duplicate_manager_creation` instance to catalogue.

  **Re-confirmed on a later pull of the same org** (`2346b7f2...`,
  last-10-managers run): both Muzinich rows still showed up, still both
  `ai_generated_preview = true`, still disjoint fund sets -- same instance,
  not a new one, but a useful confirmation the rule and the underlying
  duplicate are both stable over time rather than a one-off extraction
  glitch that would've since been cleaned up.

  **Second, distinct mechanical case the per-level check also catches**:
  L+M Fund Management's `L+M Housing Fund II`/`III`/`V` each have **two
  security rows with the identical name** under the same fund -- one
  `ai_generated_preview = true`, one `= false`. Not a manager-level
  duplicate (the fund and manager rows are singular and clean), but the
  same mechanism at the instrument level: checking `ai_generated_preview`
  independently on every row, rather than inheriting a parent's flag or
  assuming one row per fund, is what keeps a payload-builder from
  submitting both the stale preview copy and the real one as if they were
  two different instruments. No new catalog entry needed -- this is this
  entry's own "checked independently at every level" clause doing its job
  on a shape (duplicate rows within one level, not across levels) the
  original Muzinich finding didn't illustrate.

## Candidates not yet catalogued (to be verified, single instance)

Per this catalog's own discipline, these are named here so they're not
lost, but are **not** trusted rules yet -- one instance each, treat as
`DEFER`/"to be verified" if they recur, don't promote to a catalog entry
until a second independent instance shows up.

- **`vehicle_type_contradiction`**: Hayfin Maritime Yield Fund II has
  `security.vehicle = 'Drawdown'`, but `security.perpetual_term = true`
  and the fund's own `overview_text` describes it as *"a perpetual fund
  with a vintage structure"* with lock-up + biennial-liquidation-window
  redemption -- structurally an `Evergreen` fund mislabeled as `Drawdown`.
  1 instance.
- **`analytics_target_vs_track_record`**: not a data defect, but a mapping
  discipline worth watching for repeat mistakes -- fund-level performance
  figures from marketing material split into two genuinely different
  `observation_type`s (`target` for a currently-raising fund's stated
  goals; `unverified` for a track-record claim about an already-investing
  fund, since it's sourced from a pitch deck, not an audited financial
  statement). Getting this wrong doesn't corrupt data the way a value
  error would, but conflating "what they're promising" with "what
  happened" is exactly the kind of thing marketing-material-sourced data
  makes easy to blur. See `atlas-ontology` for the full rule.
- **`cross_org_value_discrepancy`**: two Security Master orgs' copies of
  the same real-world fund (linked via `universal_id`) disagree on a
  *substantive value* -- "Zero Prime Ventures Fund II" has
  `target_fund_size` = $45M under one org, $48M under another, same
  vintage, same fee terms otherwise. This is the real, distinct failure
  mode that `sm_lineage_metadata_inconsistency` (see "Known non-issues"
  above) is sometimes confused with -- the discriminator is **content vs.
  bookkeeping**: this entry is about the copies' actual *values*
  disagreeing (a real signal), not about SM's own copy-lineage fields
  disagreeing (noise, not a signal). When this fires: compare the two
  copies' overall completeness first -- if one is clearly cleaner/more
  complete, map that one as the source of truth rather than treating
  both as equally uncertain. Only fall back to `flag`/`DEFER` (no basis
  for picking a winner) when the copies are otherwise comparably
  complete and the disagreement itself can't be adjudicated. Dimension:
  accuracy, severity likely `flag` (not confidently wrong, just
  disagreeing) rather than `block`/`correct`. 1 instance.

  **Scope correction, confirmed wrong in a real run**: this "compare
  copies, map the cleanest" guidance applies only to **one source's own
  internal multi-tenant duplication** (Security Master's own multiple
  `org_id` copies of the same real manager/fund, which this agent must
  collapse into one coherent record before anything reaches Atlas -- see
  "Security Master is multi-tenant" in `mapping_guide.md`). It does
  **not** apply across genuinely independent sources
  (`security_master` vs. `form_adv_monthly` vs. `diligence_extraction`
  vs. `arch`) -- those are designed to coexist as separate,
  independently-traceable rows in Atlas (`ingestion_source_group_key`;
  see `atlas-ontology` skill's "one row = one source's claim, never
  blended"), and picking a winner across them is never this agent's
  call. A real run got this wrong: 8VC's `year_founded` was flagged as
  "unconfirmed" by checking Security Master's own internal
  `field_provenance` audit table (which had no row for that field even
  though sibling fields were freshly re-extracted) and treating that as
  if it meant something about Atlas's own data -- it doesn't.
  `field_provenance` is SM-internal bookkeeping, not an Atlas-side
  signal. Checked directly in Atlas's own `entity_attribute`: 8VC's
  `year_founded` has exactly **one** row, from `security_master`, same
  batch as every other field on the record -- no competing
  `diligence_extraction`/`form_adv_monthly` row for that attribute
  exists at all, so there was no actual cross-source disagreement to
  adjudicate in the first place. Before flagging any cross-source
  disagreement, check Atlas's own attribute/name tables grouped by
  `ingestion_source_group_key` directly -- never a source's internal
  audit table -- and confirm more than one source actually wrote a
  competing value before treating it as this failure mode at all.

- **`direct_investment_spv_modeled_as_manager`**: a "manager" row whose
  only fund is a single, company-named direct-investment tender/SPV --
  e.g. "Helion Energy" (manager) -> "Helion Series G Tender" (its one
  fund), "Path Robotics" (manager) -> "Path Robotics Series E" (its one
  fund, 0% management fee). Looks like a portfolio company being modeled
  as if it were an asset manager rather than a genuine GP with a
  diversified fund family -- not necessarily wrong (SM may be deliberately
  using the manager/fund shape as the only way to represent "a direct deal
  in this company"), but worth a human call on whether `entity_type`
  should actually be something other than `management_company`/
  `fund_vehicle` for this shape (e.g. the company itself as the entity,
  the tender as a `co_investment` instrument on it, no separate "manager"
  at all). 2 confirmed instances, both from the same run -- not yet two
  independent sessions/pulls, and both instances happened to also be
  otherwise-clean, non-preview (`ai_generated_preview = false`) records,
  so this is a mapping-shape question, not a data-quality defect. `DEFER`
  with the anomaly described if it recurs; don't invent an `entity_type`
  decision unilaterally.

  **Re-observed on a later pull** (`2346b7f2...`, last-10-managers run):
  Path Robotics showed up again -- same manager, same fund, same record,
  not a new instance. Its one security's fee data (0% management fee, no
  performance fee) is internally consistent with the narrative's "0%
  carried interest" claim, and the instrument itself passes completeness
  (`management.investment_rate` mapped) -- so under the current rules it
  independently scores `LOAD` at the instrument level even while the
  manager/fund level sits at `DEFER` for this shape question. That's the
  gate_relationship design working as intended (a fund/instrument's own
  verdict never depends on its parent's), not a contradiction -- but worth
  noting explicitly since "the instrument loads while the manager doesn't"
  looks surprising at a glance.

- **`manager_entity_thin_despite_rich_instruments`** -- **resolved by a
  rule change, no longer a candidate needing a per-instance human call.**
  A manager row with **zero core fields mapped**
  (`description`/`aum`/`year_founded` all null) while its fund_family/funds
  underneath are rich, consistently named, and well-populated -- e.g.
  Audax Private Equity's own manager row has no overview, AUM, year
  founded, headquarters, or domain at all, while 13 of its funds ("Audax
  Private Equity Fund I-VII", "Audax Origins Fund I/II", three "Flagship
  Fund ... - LMM Track" funds) are well-described with real target sizes
  and vintages, and 4 of those funds already have a resolved
  `fund.atlas_entity_id` from a prior load -- i.e. this is a known-real,
  previously-onboarded manager, not a thin or low-quality one.

  Originally handled by letting the generic completeness rule `DEFER` the
  manager row outright (no core field, hence `completeness_passed = false`
  regardless of ratio) while fund/instrument rows scored independently.
  **On review this was wrong**: a manager that never scores `LOAD` never
  gets an Atlas `entity_id`, which means its `manages` relationship to
  every one of those rich, independently-loadable funds can never resolve
  -- permanently, no matter how good the funds' own data is. Completeness
  now has a third compensating path, **child-corroboration** (see
  `ingest-schemas` skill and `knowledge/ingest_gate_schema.md`'s "complementary
  direction" note): a parent with at least one child that independently
  scores `LOAD` on its own passes completeness on that evidence, even with
  zero core fields of its own. Audax Private Equity now correctly scores
  `completeness_passed = true` / `LOAD` at the manager level, citing its
  loadable funds as the corroborating evidence in `completeness_reason`.
  1 confirmed instance so far (Audax Private Equity, org `2346b7f2...`);
  the rule itself is general (manager→fund and fund→instrument), not
  specific to this one manager -- apply it wherever it fits rather than
  waiting for a second instance, since the reasoning (relationship
  resolution requires the parent to actually load) holds regardless of
  how many times it's been observed.

---

## New entries added this session (8VC/CVC, org `2346b7f2...`, full-graph review)

### 7. `unmerged_brand_vs_legal_adviser_entity`

- **Dimension**: accuracy — this is a graph-completeness/entity-resolution
  gap, not a single wrong value, but it makes the manager's financial
  graph genuinely incomplete if not understood.
- **Severity**: `flag` — confirmed real, not confidently fixable by this
  agent (merging entities is Atlas's own resolution job, never this
  agent's), but worth surfacing every time it recurs.
- **Trigger predicate**: the same real-world manager exists as **two
  separate Atlas `entity_id`s** because one source (Security Master,
  pitch deck) captured its commercial **brand name**, while a different
  source (SEC Form ADV) captured its **registered legal adviser name**,
  and the two names share no common identifier (`CRUNCHBASE_ID`/
  `PITCHBOOK_ID` on one side, `CRD`/`SEC_FILE_NUMBER` on the other) and
  don't fuzzy-match on text (`entity_fuzzy_match`'s soundex/trigram index
  has nothing to join on when the names are this different).
- **Confirmed instance**: "8VC" (`08cf4e46...`, from `security_master`/
  `diligence_extraction`, identifiers `PITCHBOOK_ID`/`CRUNCHBASE_ID`) and
  "EIGHT PARTNERS VC, LLC" (`9e722722...`, from `form_adv_monthly`,
  identifiers `CRD`/`SEC_FILE_NUMBER`) are the same real firm — "Eight"
  spelled out, "VC" kept, wrapped in an LLC, a completely standard
  brand-name-vs-regulatory-filing-name split for VC firms. The split
  matters in practice, not just in principle: the manager's **live
  performance data** (an Arch-sourced position held by "Opto Artificial
  Intelligence Early Stage Venture Fund, LP" into two 8VC SPVs) hangs off
  `ADVISES` relationships from the **Form ADV entity**, completely
  invisible to any query rooted on the `security_master` "8VC" entity's
  `MANAGES` edges alone.
- **Evidence**: both entities' names + identifiers side by side, and
  confirmation that no `entity_fuzzy_match`/identifier overlap exists.
- **Effect on `gate_verdict`**: Not something this agent fixes by
  rewriting `entity_id`s. The actionable fix is to **give the resolution
  engine something to link on** — capture the SEC-registered legal name
  as an additional `LEGAL_NAME`-type alias on the brand-name entity (or
  vice versa) wherever a source actually states both names for the same
  firm, so a future resolution pass has the cross-reference it's
  currently missing. `DEFER` with this reasoning if found mid-run; don't
  silently merge.
- **Status**: 1 confirmed instance (8VC / Eight Partners VC, LLC). Needs
  a second, independent manager before this is a trusted, generalizable
  rule rather than a single real finding — but the shape (brand name vs.
  SEC legal name, no shared identifier) is exactly the kind of split
  that's structurally likely to recur across every VC-branded manager
  that also files Form ADV, so treat new managers with both a
  `security_master` and a `form_adv_monthly` presence as worth this exact
  check every time, not just a one-off.
- **Pipeline note**: `data-factory/pipes/onboarding/docs/phase_4_atlas_ingest.md`
  has an open question asking whether `pipes/onboarding/data/
  p1_manager_crd_mappings.csv` (a manual CRD cross-reference, 191 rows)
  is still the right mechanism for this. Checked this session: **that
  file does not exist at that path right now** — confirm with whoever
  owns Phase 4 whether it was relocated, never committed, or the
  mechanism has already been superseded, before assuming it's available
  at ingest time.

### 8. `instrument_resolution_miss_orphans_fee_data`

- **Dimension**: accuracy — fee/term data ends up attached to the wrong
  (freshly-created, disconnected) instrument instead of the fund's real
  one.
- **Severity**: `flag` — confirmed real and structurally wrong, but not a
  single-field correction; needs a human merge decision (which
  instrument survives, which fee rows move), not an automated fix.
- **Trigger predicate**: a fund entity already has one or more
  instruments from a prior source (e.g. a "MAIN" + "PARALLEL" vehicle
  pair, both legitimately real), and a **new** ingestion batch for that
  same fund entity creates **another, additional** instrument rather
  than resolving to one of the existing ones — identifiable by: the new
  instrument's `instrument_type`/fee data lands on a fresh
  `instrument_id` while the pre-existing "MAIN" instrument for the same
  fund stays untyped/unchanged.
- **Confirmed instance**: 8VC Fund VI (`b0fbc68b...`) already had
  "8VC FUND VI MAIN" and "8VC ENTREPRENEURS FUND VI (PARALLEL)" from a
  prior pitch-deck load. The `security_master` load on 2026-10-23 failed
  to match either and created a third instrument ("8VC Fund VI"), which
  is the one that now carries the new management/performance fee data —
  the real MAIN vehicle still has no type and no fee data. By contrast,
  the same `security_master` batch correctly matched 8VC Fund II and
  Fund III to their existing MAIN instruments in the same run — this is
  an isolated resolution miss, not a systemic failure of the matching
  logic, which makes it more concerning, not less (it means the matching
  logic is inconsistent record-to-record within one batch, not uniformly
  broken in a way that's easy to detect and guard against).
- **Evidence**: all instrument rows for the affected fund entity side by
  side (`instrument_id`, `instrument_type`, `instrument_name`,
  `ingestion_source_group_key`, `recorded_at`), showing the fee data's
  actual anchor vs. the pre-existing untouched MAIN instrument.
- **Effect on `gate_verdict`**: `DEFER` the affected instrument-level
  record with this reasoning; don't silently merge instruments.
- **Status**: 1 confirmed instance. Directly relevant to
  `phase_4_atlas_ingest.md`'s own acceptance criteria ("Re-running this
  phase is idempotent — no duplicate `create_entities` call for a
  `silver_id` already resolved in Atlas, checked live via
  `identify_entity`") — that criterion is written for the *entity* level;
  this incident shows the same idempotency gap exists one level down, at
  the *instrument* level, and isn't yet covered by that check. Worth
  flagging to whoever owns Phase 4 before it ships: instrument-level
  `identify_entity`-equivalent resolution needs the same never-force-create
  discipline the entity level already has.

## Known non-issues (confirmed false positives — don't flag these)

Not every anomaly that *looks* like a defect is one. These are confirmed
cases where the right call, after investigation, was "this doesn't matter
— don't let it drive a verdict," kept here so the same investigation
doesn't get redone, and so these don't quietly get promoted into real
catalog entries by a future session that didn't see the reasoning.

### `sm_lineage_metadata_inconsistency` — SM's own copy-tracking fields disagreeing is not an accuracy issue

- **What it looks like**: a manager/fund record's `extraction_copy_manager_data_result`
  (e.g. `'LINKED_MANAGER'`) and `universal_id` don't agree with each other
  (one says "copied from a link," the other has no link recorded), and/or
  a *different* org's copy's `universal_id` points at this record instead
  of the other way around.
- **Confirmed instance**: Silver Lake's manager record (`manager_id=
  2083e844...`, org `2346b7f2...`) has `extraction_copy_manager_data_result
  = 'LINKED_MANAGER'` with a blank `universal_id`; a second org's "Silver
  Lake Partners" copy (`dbc46096...`, org `48c9e0a8...`) has `universal_id`
  pointing *at* Silver Lake's record -- the reverse of what the first
  record's own flag implies. Silver Lake's actual facts (aum, year_founded,
  description, etc.) were 100% mapped, confidence 1.0 across the board --
  nothing about the manager itself was in question.
- **Why it's not a failure mode**: `universal_id`/
  `extraction_copy_manager_data_result` are SM's own internal
  copy-lineage bookkeeping -- not a fact about the real-world manager,
  fund, or instrument, and not something Atlas's own entity resolution
  reads or trusts at all. A human (Lucie) confirmed directly: Atlas's own
  resolution is more robust than SM's copy-tracking and doesn't need it;
  this agent doesn't need to know "who copied from whom," only "which
  copy is cleanest."
- **What to do instead**: when multiple org-copies of the same real-world
  manager/fund exist, compare them **on substance** (completeness, value
  agreement) and map whichever copy is cleanest/most complete as the
  source of truth. Don't flag or `DEFER` a record over its own or
  another copy's lineage-field inconsistency alone. Only `DEFER`/`flag`
  when the copies **substantively diverge in content** you can't
  adjudicate (see `cross_org_value_discrepancy` below, which is the real,
  distinct failure mode this one is sometimes confused with) -- a values
  disagreement is the real signal; a lineage-bookkeeping disagreement is
  not.
- **Status**: 1 confirmed instance (Silver Lake) where this was gotten
  wrong in a real run before being corrected. See `knowledge/mapping_guide.md`'s
  "Correction: SM's own lineage fields are not Atlas's concern" for the
  full writeup.

---

## Adding a new entry

Keep to unambiguous cases only — if reasonable people could disagree on
whether it's actually wrong, it's not ready for this catalog. Always cite
at least one real, confirmed instance; never add a hypothetical failure
mode "in case it happens." State the false-positive/population-check gap
explicitly in **Status** rather than skipping it — an unverified rule
running unattended is worse than no rule. State **Dimension** and, for
accuracy entries, **Severity** explicitly — don't leave a new entry to
default to the harshest (`block`) just because that's easiest to write;
most real anomalies are `correct` or `flag`.
