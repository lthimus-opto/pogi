# Local Data Agent — Implementation Guide

**Status:** living design doc (iterate before we build)
**Stack bias:** MotherDuck · pi (headless + interactive) · Atlas as world model
**Audience:** you (Lucie) — understand every step before we code together

This is the longer-term architecture the manual process in
`data-agent/project/vision.md` is building toward. It is **not** being built yet —
see that doc's "Where This Is Headed" section for how the two relate.

**Revision note**: the previous version of this doc was written before this
project was built on top of `pi` (the coding agent framework these skills
and extensions live in). It assumed a custom always-on daemon, a bespoke
CLI, and a second local DuckDB store for the "ledger." All three of those
are things pi already provides — see the table below. The phases and
goals are unchanged from the original vision; the *how* is rewritten to
use pi's actual primitives instead of software we'd have to build
ourselves.

| Old idea | What pi already gives us |
|---|---|
| Custom "always-on process" polling collectors | Cron/launchd triggers a headless `pi --mode print` (or `--mode json`) invocation per source, on a schedule. No daemon to write or keep alive. |
| "Agent ledger" as a second local DuckDB store | `gate_verdict` in MotherDuck **is** the ledger. One store, not two. |
| Custom CLI (`agent today`, `agent why <id>`, `agent label`) | A normal interactive `pi` session, querying MotherDuck directly — or a small extension exposing slash-commands if that's worth building later. |
| Nudge policy / paging logic | `.pi/extensions/safety-guard.ts` already distinguishes "unattended run" (`ctx.hasUI === false`) from "human present." That same distinction is where a nudge (Slack/email/local notification) belongs — fired from a headless run's end, not from a separate policy engine. |
| Human labeling CLI (`agent label <id> good\|bad`) | The interactive session itself. Since `hasUI` is true there, a human reviewing/correcting `gate_verdict` rows *is* the labeling workflow — no separate tool needed. |

---

## 1. What we are building

An always-on **local data agent** that:

1. Runs unattended on a schedule (cron/launchd starts it; it mostly does
   not ask you anything while running).
2. Watches source data as it arrives and changes, one source per headless
   `pi` invocation.
3. Writes an auditable ledger of observations and judgments — `gate_verdict`
   in MotherDuck, not a separate store.
4. Answers questions like: *What's happening today? What did you observe?*
   — via a normal interactive `pi` session over that same MotherDuck table.
5. Pages you only when something crosses a quiet-nudge policy.
6. Produces labeled examples (human corrections to `gate_verdict` rows) you
   will use to fine-tune what "good" and "bad" data mean — **before**
   pushing the same loop to the cloud.

### Non-goals (for v0)

- Replacing Atlas (the identity vault).
- Building the full Financial Data Layer (valuations, performance, reconciliation).
- Cloud deployment, multi-tenant entitlements UI, or production ingestion pipelines.
- Training a model on day one (first we define labels and collect them).
- Building a custom daemon, CLI, or second ledger store — see the revision
  note above. If pi's primitives genuinely can't do something, that's the
  trigger to build custom software, not a default.

Atlas remains the **world model**. The agent owns the **observer + judge +
briefing** loop, running as scheduled headless pi invocations plus
on-demand interactive ones.

---

## 2. Mental model: two loops, one store

```
┌─────────────────────────────────────────────────────────────┐
│  LOOP A — Gather / Judge (headless, scheduled, quiet)        │
│  cron → `pi --mode print` per source → extract (MotherDuck) │
│  → map → score → write gate_verdict rows → nudge if needed  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │    MotherDuck    │
                    │  gate_verdict    │
                    │  (+ raw tables)  │
                    └──────────────────┘
                              ▲
┌─────────────────────────────────────────────────────────────┐
│  LOOP B — Q&A / Briefing / Labeling (interactive pi session) │
│  read gate_verdict (+ Atlas as needed) → answer / correct    │
└─────────────────────────────────────────────────────────────┘
```

There is one store, not two — `gate_verdict` (and the raw source tables
alongside it) in MotherDuck. Loop A only ever *appends*/*writes* verdict
rows; Loop B is where a human reads, questions, and corrects them. This
mirrors `.pi/extensions/safety-guard.ts`'s actual enforcement: headless
runs (`ctx.hasUI === false`) write only within that boundary; interactive
sessions (`ctx.hasUI === true`) are where correction/editing happens.

Do **not** let the agent invent competing `entity_id`s outside Atlas's own
resolution. Judgments (`gate_verdict` rows) attach to source records and
proposed payloads; identity creation stays in Atlas resolution, downstream
of this agent.

---

## 3. Atlas context (assumptions from your data model)

We assume Atlas principles you already defined:

- Stable IDs (`entity_id`, later `instrument_id`, `position_id`).
- Bi-temporality when applicable: `valid_from` / `valid_to` vs `recorded_at`.
- Keep conflicting source facts; lineage via `INGESTION_SOURCE`.
- Front Door: all records pass **entity resolution** before the vault.
- Identity layer ≠ financial layer; Position is the handoff.

The agent's job is **not** to redefine Atlas. It is to **observe** source
data, **propose** payloads, and **judge** their fitness to load — never to
write to Atlas itself.

---

## 4. Definition of done for "the agent works"

You can say the system works when all of these are true:

1. A scheduled headless `pi` invocation runs per source with no human
   present (`ctx.hasUI === false`, enforced by `safety-guard.ts`).
2. It extracts source data straight into MotherDuck (`tooling-pipeline` skill).
3. It maps, scores, and writes `gate_verdict` rows for every record —
   Accept/Quarantine/Reject per `ingest-schemas` skill.
4. You can open an interactive `pi` session and ask "what happened today?"
   grounded in `gate_verdict` rows (not vibes) — a plain SQL query against
   MotherDuck, no bespoke tool required.
5. It stays quiet unless a nudge rule fires (see Phase 6 below).
6. You can correct a verdict in that same interactive session — the
   correction itself is the human label, stored back onto the row.

### Phase 6 — Loop A runner (the scheduled headless invocation)

**Goal:** One scheduled job per source that owns that source's daily pull.

**Behavior:**

1. Cron/launchd triggers `pi --mode print -p run_prompt.md` (or
   `--mode json` if a wrapper script needs to consume structured events)
   with `{{SOURCE}}`/`{{ENV_FILE}}` filled in.
2. The invocation runs Tasks 1-5 from `TASK_SPEC.md` end to end, per the
   `tooling-pipeline` / `source-mapping` / `failure-modes` / `ingest-schemas`
   skills.
3. `safety-guard.ts` enforces that this run can only write inside
   `.scratch/` on disk — the actual output (`gate_verdict` rows) goes to
   MotherDuck, which is not subject to that filesystem restriction.
4. On completion, a small wrapper script (not pi itself) diffs new
   `gate_verdict` rows against the nudge policy (below) and sends a
   notification if warranted. This lives outside pi — a cron wrapper or a
   tiny script reading MotherDuck after the invocation exits — not inside
   the agent's own run.

**Quiet policy (example — edit ruthlessly):**

| Condition | Action |
| --- | --- |
| New `REJECT` verdict | Nudge `attention` |
| New `DEFER` with an uncatalogued failure mode | Nudge `attention` |
| New `LOAD` | Ledger only, no nudge |
| Run itself errored (invocation didn't complete) | Nudge `urgent` |

**Open**: what "nudge" actually sends through (Slack webhook? email? a
local OS notification?) isn't decided — pick the cheapest thing that
reaches you reliably; this is infrastructure outside pi, not a pi feature.

**Done when:** a source can run on a schedule for a week with only the
nudges you configured, no missed silent failures.

---

### Phase 7 — Loop B (ask / briefing)

**Goal:** Answer "what happened" from an ordinary interactive `pi` session.

**Minimum interface:** no new tooling — plain SQL against MotherDuck in an
interactive session:

```sql
-- today
SELECT verdict, count(*) FROM output.gate_verdict WHERE recorded_at::date = current_date GROUP BY 1;

-- why a specific record
SELECT * FROM output.gate_verdict WHERE input_id = '<id>';
```

Optional later: a small pi extension exposing this as a slash-command
(`/today`, `/why <id>`) once the raw-SQL habit gets tedious — see
`docs/extensions.md`'s custom-command pattern. Not needed for v0.

**Done when:** "what did you observe?" is answered with citations
(`input_id`s / `gate_verdict` rows), not prose alone.

---

### Phase 8 — Human labeling workflow (your fine-tuning engine)

**Goal:** Turn verdicts into a growing gold set of human-confirmed labels.

**Steps:**

1. In an interactive session (`hasUI === true`, so edits are permitted per
   `safety-guard.ts`), review a sample of `DEFER`/`REJECT` rows.
2. Add a `human_verdict`/`reviewed_by`/`reviewed_at` column set directly on
   `gate_verdict` (or a companion `gate_verdict_review` table if we don't
   want to mutate the original row) — **open question, not yet decided**.
3. Export dataset: `(completeness_passed, completeness_missing,
   accuracy_passed, accuracy_failure_mode, verdict, reason)` →
   `human_verdict`, for later fine-tuning or rule-tightening.
4. Track agreement: rules vs. human (confusion matrix).

**Done when:** you have ≥ N trusted labeled rows (pick N; e.g. 100) and
know where the rules disagree with you.

---

### Phase 9 — Improve the verdict rule (still local)

Only after Phase 8 has signal:

- Tighten the core/supplementary field split or the completeness-ratio
  threshold in `ingest-schemas` (see that skill), **or**
- Train a small local classifier / prompt+few-shot pack on the labeled
  set, **or**
- Use an LLM as tiebreak **only** on ambiguous cases, with its output
  still written as a `gate_verdict` row subject to human review — never
  skip writing the decision into the ledger.

---

### Phase 10 — Cloud push (later)

When the local loop is trustworthy:

1. Same schema (`gate_verdict` in MotherDuck — already cloud-native, no
   migration needed for the store itself).
2. Replace cron/launchd with a cloud scheduler invoking the same headless
   `pi --mode print`/`--mode json` calls (e.g. a scheduled Lambda/ECS task
   running the same run prompt).
3. Keep the **same** verdict taxonomy and nudge policy.
4. Entitlements stay outside Atlas's vault — this agent must respect them
   when *showing* data (Loop B), not when *proposing* verdicts (Loop A).

Local → cloud should feel like relocating the scheduler, not redesigning
the agent.

---

## 5. How we will work together

1. You read this doc and mark: **agree / change / don't understand** per section.
2. We settle the two **open questions** above (nudge channel; whether
   human review is a new column set on `gate_verdict` or a companion
   table) before building Phase 6.
3. Then we wire one source's `run_prompt.md` into an actual cron job,
   pointed at `.scratch/` + MotherDuck, and watch it run unattended for a
   few cycles before trusting it.
4. Only then Phase 7 (briefing) and Phase 8 (labeling) get built out.

**Rule:** if a step doesn't create a queryable artifact in MotherDuck or a
clearer definition of good/bad, it's probably premature.

---

## 6. Open questions

1. Notification channel for nudges — Slack, email, local OS notification?
2. Human review: mutate `gate_verdict` in place, or a companion
   `gate_verdict_review` table? (Mutating in place loses the original
   automated verdict unless we keep both columns; a companion table keeps
   history cleaner but is a second table — weigh against the "one table"
   lesson from `knowledge/ingest_gate_schema.md`.)
3. Which failure mode hurts you most today, i.e. which source should get
   the first scheduled Loop A run?
4. How loud a nudge will you tolerate in a morning?
5. Scheduling mechanism on your machine — cron, launchd, something else?

---

## 7. One-page checklist

- [ ] Nudge channel decided
- [ ] Human-review shape decided (in-place vs. companion table)
- [ ] First source's `run_prompt.md` wired into a scheduled headless invocation
- [ ] Nudge wrapper script written (outside pi, reads MotherDuck post-run)
- [ ] Loop A runs unattended for a week with only configured nudges firing
- [ ] Loop B answered from plain SQL in an interactive session
- [ ] First batch of human-reviewed labels captured
- [ ] Cloud scheduler plan postponed until labels exist

---

*End of v0 implementation guide. Edit freely; we'll treat your edits as the source of truth going forward.*
