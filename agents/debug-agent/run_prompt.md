# Debug Agent Run

Env file: **{{ENV_FILE}}**
Question: **{{QUESTION}}**

---

## Instructions

Your standing rules are in `.pi/AGENTS.md` — already loaded into context.
This agent is read-only against everything it touches (CloudWatch, the
Aurora cluster, Performance Insights) — it diagnoses, it never mutates.

### If a specific question was given

Investigate it directly. Load whichever skill fits the question
(`cloudwatch-queries` for logs/metrics, `db-capacity` for connections/
locks/query stats/sizing, `incident-playbooks` if the question matches a
catalogued incident shape) — don't load skills you don't need.

Work backward from symptom to cause:
1. Establish the time window (from the question, or default: last 1h).
2. Pull the relevant CloudWatch metrics/logs for that window
   (`./connect.sh` is for the DB only — CloudWatch is via `aws cloudwatch`
   / `aws logs` CLI, see `cloudwatch-queries` skill).
3. Cross-reference against live DB state for the same window
   (`pg_stat_activity`, `pg_stat_statements`, replica lag, connection
   counts — see `queries/` and the `db-capacity` skill).
4. State a root cause with evidence, or say explicitly what you checked
   and couldn't confirm — never guess a confident root cause without
   evidence from this run.

### If no question was given (general sweep)

Run the default health/capacity checks:
- Connection counts vs. max_connections, by database
- Top queries by total time / calls (`pg_stat_statements`)
- Replica lag (if applicable)
- Table/index bloat beyond the baseline (see `knowledge/capacity_baselines.md`)
- Any CloudWatch alarms currently in ALARM state for this cluster

### Summary

End with a short report:
- What was checked
- Anything outside the known-good baseline (`knowledge/capacity_baselines.md`),
  with the actual numbers
- Root cause (if a specific question was asked) or overall health verdict
  (if a general sweep)
- Any catalogued incident this matches (`knowledge/failure_modes.md`), or
  `UNCATALOGUED` if it doesn't match anything known yet
