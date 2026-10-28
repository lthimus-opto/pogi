# pogi

Autonomous/interactive agents built on `@earendil-works/pi-coding-agent`'s
SDK, each scoped to a specific operational job. npm workspaces monorepo —
each agent is self-contained (own `.pi/AGENTS.md`, skills, knowledge base,
queries) but shares a thin layer of real infra (`shared/`).

## Agents

- **[`agents/data-agent`](agents/data-agent/README.md)** — reads source
  databases (Security Master, Atlas, Invest), maps records onto Atlas's
  ontology, QCs them, and writes `gate_verdict`/`gate_relationship` rows
  to MotherDuck for a downstream pipe to load. Non-interactive,
  single-invocation-per-source.
- **[`agents/debug-agent`](agents/debug-agent/README.md)** — diagnoses
  infra/data issues by cross-referencing CloudWatch (logs, metrics,
  alarms) with live DB state (connections, locks, query stats, replica
  lag, capacity headroom) on the same Aurora cluster. Read-only,
  primarily interactive (ask it a question).

## Shared layer (`shared/`)

- `shared/connect.sh` — IAM-auth `psql` connection to the Aurora cluster,
  symlinked into each agent as `./connect.sh` so `AGENTS.md`/skill docs
  can reference it the same way regardless of which agent they're in.
- `shared/env/` — the actual `.env.*` credential files (gitignored —
  never committed), symlinked into each agent that needs them. One place
  to update credentials instead of N copies drifting apart.
- `shared/lib/sdk-bootstrap.ts` — the SDK session-creation boilerplate
  every agent's `run.ts` uses (resource loading, console
  streaming/tool-call logging). Agent-specific logic (prompt templating,
  output schema, run tracking) stays in each agent's own `run.ts`.

## Setup

```bash
npm install   # installs + hoists all agents' dependencies via workspaces
```

Each agent needs its own `.env*` files under `shared/env/` (not committed —
ask whoever set up the previous instance, or provision fresh credentials
per `agents/data-agent/.pi/AGENTS.md`'s "Source connection" section).

## Running an agent

```bash
# via root scripts
npm run data-agent -- security_master .env.security_master.prod
npm run debug-agent -- .env.atlas.prod "why did connections spike at 14:00 UTC?"

# or directly, from the agent's own directory
cd agents/data-agent && npx tsx run.ts security_master .env.security_master.prod
cd agents/debug-agent && npx tsx run.ts .env.atlas.prod
```

## Adding a new agent

1. `agents/<name>/` with its own `package.json` (see either existing
   agent's for the shape), `.pi/AGENTS.md`, `.pi/extensions/safety-guard.ts`,
   `run.ts` + `run_prompt.md`.
2. Symlink `connect.sh` and whichever `shared/env/.env*` files it needs:
   `ln -s ../../shared/connect.sh agents/<name>/connect.sh`.
3. Import `bootstrapAgentSession`/`subscribeConsoleLogging` from
   `../../shared/lib/sdk-bootstrap.ts` in `run.ts` rather than
   reimplementing session setup.
4. Add it to this README's "Agents" list and a root `npm run <name>` script.
