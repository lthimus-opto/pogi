/**
 * Shared SDK bootstrap — common to every agent's run.ts in this repo.
 *
 * Each agent (agents/data-agent, agents/debug-agent, ...) is a single
 * autonomous invocation built directly on @earendil-works/pi-coding-agent's
 * SDK (not the `pi` CLI). This file holds the boilerplate that's identical
 * across all of them: resource discovery (.pi/skills, .pi/extensions,
 * .pi/AGENTS.md from the agent's own cwd), session creation, and basic
 * console streaming/tool-call logging.
 *
 * Agent-specific bits (prompt templating, run-tracking writes, output
 * schema) stay in each agent's own run.ts — don't grow this file to cover
 * those; it should stay generic across very different agents.
 */

import {
  createAgentSession,
  DefaultResourceLoader,
  getAgentDir,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";

export interface BootstrapOptions {
  /** Agent's own directory — where .pi/ lives. Usually import.meta.dirname. */
  cwd: string;
  /** Tools the agent's SDK session is allowed to use. Default: read + bash. */
  tools?: string[];
}

export type AgentSession = Awaited<ReturnType<typeof createAgentSession>>["session"];

/**
 * Discovers .pi/skills, .pi/extensions, .pi/AGENTS.md under `cwd` and
 * creates an in-memory SDK session wired up with them.
 */
export async function bootstrapAgentSession({ cwd, tools = ["read", "bash"] }: BootstrapOptions) {
  const loader = new DefaultResourceLoader({ cwd, agentDir: getAgentDir() });
  await loader.reload();

  const { session } = await createAgentSession({
    cwd,
    resourceLoader: loader,
    tools,
    sessionManager: SessionManager.inMemory(cwd),
    settingsManager: SettingsManager.inMemory({
      compaction: { enabled: true },
      retry: { enabled: true, maxRetries: 3 },
    }),
  });

  return { loader, session };
}

/**
 * Streams assistant text to stdout and logs each tool call (with elapsed
 * time) to stderr. Returns a live counter the caller can read after the
 * run completes, for a trailing summary line.
 */
export function subscribeConsoleLogging(session: AgentSession, runStart: number) {
  let toolCallCount = 0;
  let lastToolName = "";

  session.subscribe((event) => {
    if (event.type === "message_update" && event.assistantMessageEvent.type === "text_delta") {
      process.stdout.write(event.assistantMessageEvent.delta);
    }

    if (event.type === "message_update" && event.assistantMessageEvent.type === "tool_use_begin") {
      toolCallCount++;
      lastToolName = event.assistantMessageEvent.name ?? "";
      const elapsed = ((Date.now() - runStart) / 1000).toFixed(0);
      console.error(`\n[${elapsed}s] Tool #${toolCallCount}: ${lastToolName}`);
    }
  });

  return {
    get toolCallCount() {
      return toolCallCount;
    },
    get lastToolName() {
      return lastToolName;
    },
  };
}
