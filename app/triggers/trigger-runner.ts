#!/usr/bin/env bun
/**
 * Trigger Runner — replaces trigger.sh + claude-atlas
 *
 * Usage: bun run trigger-runner.ts <trigger-name> [payload] [session-key]
 *
 * Session key determines WHICH session to resume for persistent triggers:
 *   - Email: thread ID       → trigger-runner.ts email-handler '{"body":"..."}' 'thread-4821'
 *   - Signal: sender number  → trigger-runner.ts signal-chat '{"msg":"Hi"}' '+49170123456'
 *   - Webhook: event group   → trigger-runner.ts deploy-hook '{"ref":"main"}' 'repo-myapp'
 *   - No key + persistent    → uses "_default" (one global session per trigger)
 *   - Ephemeral triggers     → key is ignored, always a new session
 *
 * For persistent sessions: if the session is already running (IPC socket alive),
 * the message is injected directly into the running session via the Claude Code
 * IPC socket. No new process is spawned.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKResultMessage } from "@anthropic-ai/claude-agent-sdk";
import { Database } from "bun:sqlite";
import { existsSync, readFileSync, writeFileSync, appendFileSync, unlinkSync, mkdirSync, readdirSync } from "fs";
import { createConnection } from "net";
import { join, dirname } from "path";
import yaml from "js-yaml";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type TriggerConfig = {
  id: number;
  name: string;
  type: string;
  channel: string;
  prompt: string;
  session_mode: "ephemeral" | "persistent";
  enabled: number;
};

export type MetricsData = {
  sessionType: string;
  sessionId: string;
  triggerName: string;
  startedAt: string;
  endedAt: string;
  durationMs: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  costUsd: number;
  numTurns: number;
  isError: boolean;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = process.env.HOME ?? "/home/atlas";
const APP_DIR = "/atlas/app";
const PROMPT_DIR = `${APP_DIR}/prompts`;
const DB_PATH = `${HOME}/.index/atlas.db`;
const CLAUDE_JSON = `${HOME}/.claude.json`;
const WORKSPACE = HOME;

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function makeLogger(triggerName: string) {
  const logPath = `/atlas/logs/trigger-${triggerName}.log`;
  return {
    log(msg: string) {
      const line = `[${new Date().toISOString()}] ${msg}`;
      console.log(line);
      try {
        appendFileSync(logPath, line + "\n");
      } catch {
        // Log dir may not exist in test environment, ignore
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Exported pure functions (for testing)
// ---------------------------------------------------------------------------

/**
 * Build the system prompt by concatenating:
 * - ~/SOUL.md (wrapped in <soul> tags)
 * - ~/IDENTITY.md (wrapped in <identity> tags)
 * - /atlas/app/prompts/trigger-system-prompt.md
 * - /atlas/app/prompts/trigger-channel-{channel}.md
 */
export function buildSystemPrompt(channel: string, options?: {
  appDir?: string;
  workspace?: string;
}): string {
  const appDir = options?.appDir ?? APP_DIR;
  const workspace = options?.workspace ?? WORKSPACE;
  const promptDir = `${appDir}/prompts`;

  let systemPrompt = "";

  // SOUL.md and IDENTITY.md (optional — user may not have them)
  for (const { tag, file } of [
    { tag: "soul", file: `${workspace}/SOUL.md` },
    { tag: "identity", file: `${workspace}/IDENTITY.md` },
  ]) {
    if (existsSync(file)) {
      systemPrompt += `\n<${tag} file="${file}">\n${readFileSync(file, "utf8")}\n</${tag}>\n`;
    }
  }

  // Core trigger system prompt
  const triggerSystemPromptFile = `${promptDir}/trigger-system-prompt.md`;
  if (existsSync(triggerSystemPromptFile)) {
    systemPrompt += `\n---\n\n${readFileSync(triggerSystemPromptFile, "utf8")}`;
  }

  // Channel-specific prompt
  const channelPromptFile = `${promptDir}/trigger-channel-${channel}.md`;
  if (existsSync(channelPromptFile)) {
    systemPrompt += `\n---\n\n${readFileSync(channelPromptFile, "utf8")}`;
  }

  return systemPrompt;
}

/**
 * Resolve the model from ~/config.yml or APP_DIR/defaults/config.yml.
 * Falls back to "claude-opus-4-6" if not configured.
 *
 * @param configPath - Primary config path to check (pass empty string to skip primary and use defaults only)
 * @param triggerType - Model key to look up (e.g. "trigger", "cron")
 * @param extraCandidates - Additional paths to search (replaces default HOME/APP_DIR fallbacks in tests)
 */
export function resolveModel(
  configPath: string,
  triggerType: string,
  extraCandidates?: string[]
): string {
  const DEFAULT_MODEL = "claude-opus-4-6";

  const candidates = extraCandidates
    ? [configPath, ...extraCandidates]
    : [
        configPath,
        `${HOME}/config.yml`,
        `${APP_DIR}/defaults/config.yml`,
      ];

  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue;
    try {
      const content = readFileSync(candidate, "utf8");
      const config = yaml.load(content) as Record<string, unknown> | null;
      if (!config || typeof config !== "object") continue;
      const models = config.models as Record<string, string> | undefined;
      if (!models) continue;
      const model = models[triggerType] ?? models["trigger"];
      if (model && typeof model === "string") {
        return model;
      }
    } catch {
      // Malformed YAML, try next
    }
  }

  return DEFAULT_MODEL;
}

/**
 * Returns the MCP servers config object for the query() call.
 * Only stdio-based servers are included (URL-based cause silent exit issues).
 */
export function getMcpServers(): Record<string, { command: string; args: string[] }> {
  return {
    work: {
      command: "bun",
      args: ["run", "/atlas/app/atlas-mcp/index.ts"],
    },
    memory: {
      command: "qmd",
      args: ["mcp"],
    },
  };
}

/**
 * Safe template substitution — replaces all occurrences of each key with
 * the corresponding value. Safe against regex injection because we use
 * simple string replace (not regex replace).
 */
export function safePlaceholderReplace(
  template: string,
  vars: Record<string, string>
): string {
  let result = template;
  for (const [key, value] of Object.entries(vars)) {
    // Split on key and join with value — no regex involved
    result = result.split(key).join(value);
  }
  return result;
}

/**
 * Read a trigger's config from the SQLite database.
 * Returns null if not found or disabled.
 */
export function readTriggerConfig(db: Database, name: string): TriggerConfig | null {
  const row = db.prepare(
    "SELECT id, name, type, channel, prompt, session_mode, enabled FROM triggers WHERE name = ? LIMIT 1"
  ).get(name) as TriggerConfig | undefined;
  return row ?? null;
}

/**
 * Write session metrics to the session_metrics table.
 */
export function recordMetrics(db: Database, data: MetricsData): void {
  db.prepare(`
    INSERT OR IGNORE INTO session_metrics
      (session_type, session_id, trigger_name, started_at, ended_at,
       duration_ms, input_tokens, output_tokens, cache_read_tokens,
       cache_creation_tokens, cost_usd, num_turns, is_error)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    data.sessionType,
    data.sessionId,
    data.triggerName,
    data.startedAt,
    data.endedAt,
    data.durationMs,
    data.inputTokens,
    data.outputTokens,
    data.cacheReadTokens,
    data.cacheCreationTokens,
    data.costUsd,
    data.numTurns,
    data.isError ? 1 : 0
  );
}

/**
 * Attempt to inject a message into a running Claude session via IPC socket.
 * Returns true if the injection succeeded, false otherwise.
 */
export async function tryIpcInject(
  sessionId: string,
  message: string
): Promise<boolean> {
  const socketPath = `/tmp/claudec-${sessionId}.sock`;

  if (!existsSync(socketPath)) return false;

  return new Promise((resolve) => {
    const client = createConnection(socketPath, () => {
      const payload =
        JSON.stringify({ action: "send", text: message, submit: true }) + "\n";
      client.write(payload, () => {
        client.end();
        resolve(true);
      });
    });
    client.on("error", () => resolve(false));
    client.setTimeout(5000, () => {
      client.destroy();
      resolve(false);
    });
  });
}

/**
 * Disable remote MCP connectors that hang on startup by writing to ~/.claude.json.
 */
export function disableRemoteMcp(): void {
  if (!existsSync(CLAUDE_JSON)) return;
  try {
    const raw = readFileSync(CLAUDE_JSON, "utf8");
    const data = JSON.parse(raw) as Record<string, unknown>;
    if (!data.cachedGrowthBookFeatures) {
      data.cachedGrowthBookFeatures = {};
    }
    (data.cachedGrowthBookFeatures as Record<string, unknown>).tengu_claudeai_mcp_connectors = false;
    writeFileSync(CLAUDE_JSON, JSON.stringify(data, null, 2));
  } catch {
    // Non-fatal — proceed anyway
  }
}

/**
 * Check if a session's JSONL file ends with a "queue-operation" entry,
 * which indicates the container was killed mid-IPC-inject (corrupted state).
 */
export function checkCorruptedSession(sessionId: string, homeDir?: string): boolean {
  const base = homeDir ?? HOME;
  const projectsDir = `${base}/.claude/projects`;

  if (!existsSync(projectsDir)) return false;

  // Search all project subdirectories for the session JSONL
  let jsonlPath: string | null = null;
  try {
    for (const projectEntry of readdirSync(projectsDir)) {
      const sessionsDir = `${projectsDir}/${projectEntry}/sessions`;
      if (!existsSync(sessionsDir)) continue;
      const candidate = `${sessionsDir}/${sessionId}.jsonl`;
      if (existsSync(candidate)) {
        jsonlPath = candidate;
        break;
      }
    }
  } catch {
    return false;
  }

  if (!jsonlPath) return false;

  try {
    const content = readFileSync(jsonlPath, "utf8");
    const lines = content.trimEnd().split("\n");
    if (lines.length === 0) return false;
    const lastLine = lines[lines.length - 1];
    const parsed = JSON.parse(lastLine) as { type?: string };
    return parsed.type === "queue-operation";
  } catch {
    return false;
  }
}

/**
 * Run the optional middleware filter script for a trigger.
 * Returns true if the trigger should proceed, false if vetoed by filter.
 */
export async function runMiddlewareFilter(
  triggerName: string,
  payload: string
): Promise<boolean> {
  const filterScript = `${WORKSPACE}/triggers/${triggerName}/filter.sh`;
  if (!existsSync(filterScript)) return true;

  const filterInput = payload || "{}";
  const proc = Bun.spawn(["bash", filterScript], {
    stdin: new TextEncoder().encode(filterInput),
    stdout: "ignore",
    stderr: "ignore",
  });
  const exitCode = await proc.exited;
  return exitCode === 0;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function isoNow(): string {
  return new Date().toISOString().replace(/\.\d+Z$/, "Z");
}

/**
 * Build the inject message for IPC injection, using channel-specific template
 * or the generic trigger-inject.md template.
 */
function buildInjectMessage(
  channel: string,
  triggerName: string,
  sessionKey: string,
  payload: string,
  promptFallback: string
): string {
  const candidates = [
    `${PROMPT_DIR}/trigger-${channel}-inject.md`,
    `${PROMPT_DIR}/trigger-inject.md`,
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      const template = readFileSync(candidate, "utf8");
      return safePlaceholderReplace(template, {
        "{{trigger_name}}": triggerName,
        "{{channel}}": channel,
        "{{sender}}": sessionKey,
        "{{payload}}": payload || promptFallback,
      });
    }
  }

  // Fallback if no template found
  return `New message arrived:\n\n${payload || promptFallback}\n\nProcess this message using the channel CLI tools (signal send / email reply) as appropriate.`;
}

/**
 * Open (or create) the database, ensuring required tables exist.
 * Does NOT run migrations — that's handled by atlas-mcp on startup.
 * We use a simple open-only approach here.
 */
function openDb(): Database {
  mkdirSync(dirname(DB_PATH), { recursive: true });
  const db = new Database(DB_PATH, { create: true });
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA foreign_keys = ON");
  return db;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

export async function main(): Promise<void> {
  const [triggerName, payload = "", sessionKeyArg] = process.argv.slice(2);

  if (!triggerName) {
    console.error("Usage: trigger-runner.ts <trigger-name> [payload] [session-key]");
    process.exit(1);
  }

  const log = makeLogger(triggerName);

  // --- Open DB ---
  if (!existsSync(DB_PATH)) {
    console.error(`[${new Date().toISOString()}] ERROR: Database not found: ${DB_PATH}`);
    process.exit(1);
  }
  const db = openDb();

  // --- Read trigger config ---
  const config = readTriggerConfig(db, triggerName);
  if (!config) {
    console.error(`[${new Date().toISOString()}] Trigger not found: ${triggerName}`);
    process.exit(1);
  }

  if (!config.enabled) {
    log.log(`Trigger disabled: ${triggerName}`);
    process.exit(0);
  }

  const channel = config.channel || "internal";
  const sessionMode = config.session_mode || "ephemeral";
  const sessionKey = sessionKeyArg ?? "_default";

  // --- Build prompt ---
  let prompt = config.prompt;

  // Fallback: load prompt from workspace file
  if (!prompt) {
    const promptFile = `${WORKSPACE}/triggers/${triggerName}/prompt.md`;
    if (existsSync(promptFile)) {
      prompt = readFileSync(promptFile, "utf8");
    } else {
      prompt = `Trigger '${triggerName}' was fired.`;
    }
  }

  // Substitute placeholders
  prompt = safePlaceholderReplace(prompt, {
    "{{payload}}": payload,
    "{{sender}}": sessionKey,
    "{{channel}}": channel,
    "{{trigger_name}}": triggerName,
  });

  // --- Update trigger stats ---
  db.prepare(
    "UPDATE triggers SET last_run = datetime('now'), run_count = run_count + 1 WHERE name = ?"
  ).run(triggerName);

  // --- Persistent session: try IPC injection first ---
  let existingSession: string | null = null;

  if (sessionMode === "persistent") {
    const sessionRow = db.prepare(
      "SELECT session_id FROM trigger_sessions WHERE trigger_name = ? AND session_key = ? LIMIT 1"
    ).get(triggerName, sessionKey) as { session_id: string } | undefined;

    existingSession = sessionRow?.session_id ?? null;

    // Guard: corrupted session (killed mid-IPC-inject)
    if (existingSession && checkCorruptedSession(existingSession)) {
      log.log(`Corrupted session ${existingSession} (ended mid-IPC-inject) — clearing, will start fresh`);
      db.prepare(
        "DELETE FROM trigger_sessions WHERE trigger_name = ? AND session_key = ?"
      ).run(triggerName, sessionKey);
      existingSession = null;
    }

    // Try IPC injection if session is running
    if (existingSession) {
      const injectMsg = buildInjectMessage(channel, triggerName, sessionKey, payload, prompt);
      const injected = await tryIpcInject(existingSession, injectMsg);
      if (injected) {
        log.log(`Injected into running session ${existingSession} (key=${sessionKey})`);
        process.exit(0);
      }
      // Socket exists but connection failed — session may be stale, continue to spawn
      const socketPath = `/tmp/claudec-${existingSession}.sock`;
      if (existsSync(socketPath)) {
        log.log(`Stale socket for ${existingSession}, spawning new session`);
      }
    }
  }

  // --- Middleware filter ---
  const shouldProceed = await runMiddlewareFilter(triggerName, payload);
  if (!shouldProceed) {
    log.log(`Filtered by middleware: ${triggerName} (key=${sessionKey})`);
    process.exit(0);
  }

  // --- Acquire flock-style dedup lock ---
  // We use a simple lockfile approach: write our PID, check if process is alive
  const safeKey = sessionKey.replace(/[^a-zA-Z0-9_]/g, "_");
  const flockFile = `/tmp/.trigger-${triggerName}-${safeKey}.flock`;

  // Acquire lock: check existing PID, wait up to 60s
  const lockAcquireStart = Date.now();
  let lockAcquired = false;
  while (Date.now() - lockAcquireStart < 60_000) {
    if (existsSync(flockFile)) {
      const existingPid = parseInt(readFileSync(flockFile, "utf8").trim(), 10);
      // Check if process is still alive
      let isAlive = false;
      try {
        process.kill(existingPid, 0);
        isAlive = true;
      } catch {
        // Process dead — stale lock
      }
      if (isAlive) {
        await Bun.sleep(500);
        continue;
      }
    }
    // Write our PID
    writeFileSync(flockFile, String(process.pid));
    lockAcquired = true;
    break;
  }

  if (!lockAcquired) {
    log.log(`Trigger ${triggerName} (key=${sessionKey}) locked — skipping spawn`);
    process.exit(0);
  }

  // Ensure lock is released on exit
  const releaseLock = () => {
    try { unlinkSync(flockFile); } catch {}
  };
  process.on("exit", releaseLock);
  process.on("SIGTERM", () => { releaseLock(); process.exit(0); });
  process.on("SIGINT", () => { releaseLock(); process.exit(0); });

  // Re-read session from DB after lock (another runner may have created one)
  if (sessionMode === "persistent" && !existingSession) {
    const sessionRow = db.prepare(
      "SELECT session_id FROM trigger_sessions WHERE trigger_name = ? AND session_key = ? LIMIT 1"
    ).get(triggerName, sessionKey) as { session_id: string } | undefined;
    existingSession = sessionRow?.session_id ?? null;
    if (existingSession) {
      log.log(`Session appeared after lock wait: ${existingSession} (key=${sessionKey})`);
    }
  }

  // Re-check IPC socket after acquiring lock
  if (sessionMode === "persistent" && existingSession) {
    const injectMsg = buildInjectMessage(channel, triggerName, sessionKey, payload, prompt);
    const injected = await tryIpcInject(existingSession, injectMsg);
    if (injected) {
      log.log(`Injected into session after lock wait ${existingSession} (key=${sessionKey})`);
      releaseLock();
      process.exit(0);
    }
  }

  log.log(`Trigger firing: ${triggerName} (mode=${sessionMode}, key=${sessionKey}, channel=${channel})`);

  const startedAt = isoNow();

  // --- Track this run ---
  let runId: number | null = null;
  try {
    const runRow = db.prepare(`
      INSERT INTO trigger_runs (trigger_name, session_key, session_mode, payload)
      VALUES (?, ?, ?, ?)
      RETURNING id
    `).get(triggerName, sessionKey, sessionMode, payload) as { id: number } | undefined;
    runId = runRow?.id ?? null;
  } catch {
    // trigger_runs table may not exist in older DBs
  }

  // --- Disable remote MCP ---
  disableRemoteMcp();

  // --- Build system prompt ---
  const systemPrompt = buildSystemPrompt(channel);

  // --- Resolve model ---
  const modelKey = process.env.ATLAS_CRON === "1" ? "cron" : "trigger";
  const model = resolveModel(`${HOME}/config.yml`, modelKey);

  // --- MCP servers ---
  const mcpServers = getMcpServers();

  // --- Set environment variables ---
  process.env.ATLAS_TRIGGER = triggerName;
  process.env.ATLAS_TRIGGER_CHANNEL = channel;
  process.env.ATLAS_TRIGGER_SESSION_KEY = sessionKey;
  process.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
  delete process.env.CLAUDECODE; // avoid nested-session detection

  // --- Run the query ---
  const triggerTimeout = parseInt(process.env.TRIGGER_TIMEOUT ?? "3600", 10) * 1000;

  let resultMsg: SDKResultMessage | null = null;
  let capturedSessionId: string | null = null;
  let isError = false;

  const runQuery = async (resumeId?: string) => {
    const options: Parameters<typeof query>[0]["options"] = {
      systemPrompt,
      model,
      mcpServers,
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      cwd: HOME,
      ...(resumeId ? { resume: resumeId } : {}),
      ...(sessionMode === "ephemeral" ? { persistSession: false } : {}),
    };

    const q = query({ prompt, options });

    const timeoutHandle = setTimeout(() => {
      q.return(undefined);
    }, triggerTimeout);

    try {
      for await (const msg of q) {
        if (msg.type === "result") {
          resultMsg = msg as SDKResultMessage;
          capturedSessionId = msg.session_id ?? null;
          isError = msg.subtype !== "success";
          break;
        }
        // Capture session_id from any message that carries it
        if ("session_id" in msg && msg.session_id && !capturedSessionId) {
          capturedSessionId = msg.session_id as string;
        }
      }
    } finally {
      clearTimeout(timeoutHandle);
    }
  };

  try {
    if (sessionMode === "persistent" && existingSession) {
      log.log(`Resuming session for key=${sessionKey}: ${existingSession}`);
      try {
        await runQuery(existingSession);
      } catch (err) {
        // Resume failed — retry as fresh session
        log.log(`Resume failed for session ${existingSession} — retrying as fresh session`);
        db.prepare(
          "DELETE FROM trigger_sessions WHERE trigger_name = ? AND session_key = ?"
        ).run(triggerName, sessionKey);
        existingSession = null;
        resultMsg = null;
        capturedSessionId = null;
        isError = false;
        await runQuery();
      }
    } else {
      if (sessionMode === "persistent") {
        log.log(`New persistent session for key=${sessionKey}`);
      }
      await runQuery();
    }
  } catch (err) {
    log.log(`ERROR running trigger: ${err}`);
    isError = true;
  }

  // Log result text
  if (resultMsg && "result" in resultMsg) {
    log.log(`Result: ${(resultMsg as { result: string }).result ?? "(no result)"}`);
  }

  const endedAt = isoNow();

  // --- Save session for persistent triggers ---
  if (sessionMode === "persistent" && capturedSessionId) {
    db.prepare(`
      INSERT INTO trigger_sessions (trigger_name, session_key, session_id)
      VALUES (?, ?, ?)
      ON CONFLICT(trigger_name, session_key) DO UPDATE SET session_id = ?, updated_at = datetime('now')
    `).run(triggerName, sessionKey, capturedSessionId, capturedSessionId);
    log.log(`Saved session for key=${sessionKey}: ${capturedSessionId}`);
  }

  // --- Record metrics ---
  const usage = (resultMsg as { usage?: Record<string, number> } | null)?.usage ?? {};
  try {
    recordMetrics(db, {
      sessionType: "trigger",
      sessionId: capturedSessionId ?? "",
      triggerName,
      startedAt,
      endedAt,
      durationMs: (resultMsg as { duration_ms?: number } | null)?.duration_ms ?? 0,
      inputTokens: (usage.input_tokens as number | undefined) ?? 0,
      outputTokens: (usage.output_tokens as number | undefined) ?? 0,
      cacheReadTokens: (usage.cache_read_input_tokens as number | undefined) ?? 0,
      cacheCreationTokens: (usage.cache_creation_input_tokens as number | undefined) ?? 0,
      costUsd: (resultMsg as { total_cost_usd?: number } | null)?.total_cost_usd ?? 0,
      numTurns: (resultMsg as { num_turns?: number } | null)?.num_turns ?? 0,
      isError,
    });
  } catch {
    // session_metrics table may not exist in very old DBs
  }

  // --- Mark run completed ---
  if (runId !== null && capturedSessionId !== null) {
    try {
      db.prepare(
        "UPDATE trigger_runs SET session_id = ?, completed_at = datetime('now') WHERE id = ?"
      ).run(capturedSessionId, runId);
    } catch {
      // Non-fatal
    }
  }

  releaseLock();
  log.log(`Trigger done: ${triggerName} (key=${sessionKey})`);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

if (import.meta.main) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
