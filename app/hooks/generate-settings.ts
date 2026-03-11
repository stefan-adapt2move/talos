#!/usr/bin/env bun
/**
 * Generate Claude Code settings.json from agent config.yml.
 * Reads model preferences and produces the hooks configuration.
 * Run from init.sh on every container start.
 */
import { readFileSync, writeFileSync, mkdirSync } from "fs";

const HOME = process.env.HOME!;
const CONFIG_PATH = HOME + "/config.yml";
const SETTINGS_PATH = HOME + "/.claude/settings.json";

// Defaults if config.yml is missing or incomplete
const DEFAULT_MODELS = {
  main: "claude-sonnet-4-6",
  subagent_review: "claude-sonnet-4-6",
  hooks: "claude-haiku-4-5",
};

const DEFAULT_FAILURE = {
  notification_command: "",
  backoff_initial_seconds: "30",
  backoff_max_seconds: "900",
  notification_threshold_minutes: "30",
};

/**
 * Minimal YAML parser for the flat models section.
 */
function parseModelsFromYaml(raw: string): Record<string, string> {
  const result: Record<string, string> = {};
  let inModels = false;
  for (const line of raw.split("\n")) {
    const trimmed = line.trimEnd();
    if (/^\S/.test(trimmed)) {
      inModels = trimmed.startsWith("models:");
      continue;
    }
    if (!inModels) continue;
    const m = trimmed.match(/^\s+(\w+):\s*(.+?)(?:\s+#.*)?$/);
    if (m) result[m[1]] = m[2];
  }
  return result;
}

/**
 * Minimal YAML parser for the failure_handling section.
 */
function parseFailureHandlingFromYaml(raw: string): Record<string, string> {
  const result: Record<string, string> = {};
  let inSection = false;
  for (const line of raw.split("\n")) {
    const trimmed = line.trimEnd();
    if (/^\S/.test(trimmed)) {
      inSection = trimmed.startsWith("failure_handling:");
      continue;
    }
    if (!inSection) continue;
    const m = trimmed.match(/^\s+(\w+):\s*(.*)(?:\s+#.*)?$/);
    if (m) result[m[1]] = m[2].trim();
  }
  return result;
}

// Read config
let models = { ...DEFAULT_MODELS };
let failure = { ...DEFAULT_FAILURE };
try {
  const raw = readFileSync(CONFIG_PATH, "utf-8");
  const parsed = parseModelsFromYaml(raw);
  if (parsed.main) models.main = parsed.main;
  if (parsed.subagent_review) models.subagent_review = parsed.subagent_review;
  if (parsed.hooks) models.hooks = parsed.hooks;
  const parsedFailure = parseFailureHandlingFromYaml(raw);
  if (parsedFailure.notification_command !== undefined)
    failure.notification_command = parsedFailure.notification_command;
  if (parsedFailure.backoff_initial_seconds)
    failure.backoff_initial_seconds = parsedFailure.backoff_initial_seconds;
  if (parsedFailure.backoff_max_seconds)
    failure.backoff_max_seconds = parsedFailure.backoff_max_seconds;
  if (parsedFailure.notification_threshold_minutes)
    failure.notification_threshold_minutes =
      parsedFailure.notification_threshold_minutes;
} catch {
  console.log("Warning: could not read config.yml, using default models");
}

const failureEnvContent = [
  `ATLAS_BACKOFF_INITIAL=${failure.backoff_initial_seconds}`,
  `ATLAS_BACKOFF_MAX=${failure.backoff_max_seconds}`,
  `ATLAS_NOTIFY_THRESHOLD_MINUTES=${failure.notification_threshold_minutes}`,
  `ATLAS_NOTIFY_COMMAND=${JSON.stringify(failure.notification_command)}`,
  "",
].join("\n");
writeFileSync(HOME + "/.failure-env", failureEnvContent);

const stopCompletionPrompt = [
  "Review this session to determine if it can safely exit.",
  "",
  "If this session did NOT create any teams (no TeamCreate calls) and is not a trigger session handling external messages, respond: {\"ok\": true}",
  "",
  "Otherwise, check:",
  "1. **Team lifecycle**: Were all teams properly shut down? (SendMessage shutdown_request to each teammate, then TeamDelete)",
  "2. **Task completion**: Were all created tasks completed? Check for TaskUpdate(status=completed) for each TaskCreate.",
  "3. **Response delivery**: If this session was triggered by an external message (Signal, Email, Web), was a response sent using the appropriate channel CLI tool (signal send, email reply, etc.)?",
  "4. **Original request**: Was the triggering task/prompt fully addressed?",
  "",
  "Respond with JSON:",
  '{"ok": true} — if the session can safely exit',
  '{"ok": false, "reason": "brief explanation of what is unfinished"} — if work is clearly incomplete',
  "",
  "Be pragmatic: only block if there is concrete unfinished work visible in the conversation. Do not block for minor cleanup.",
].join("\n");

const subagentStopPrompt = [
  "A team member has completed their task. Review the result in $ARGUMENTS.",
  "",
  "Evaluate:",
  "1. Was the original task fully completed?",
  "2. Are there obvious errors or gaps?",
  "3. Is the result acceptable or does it need rework?",
  "",
  'Respond with JSON: {"ok": true/false, "reason": "brief explanation"}',
  'Use "ok": false only if the result is clearly incomplete or wrong.',
].join("\n");

const settings: Record<string, unknown> = {
  env: {
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1",
    CLAUDE_MODEL: models.main,
  },
  permissions: {
    allow: [
      "Bash(*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "WebFetch",
      "WebSearch",
      "Agent",
      "TeamCreate",
      "TeamDelete",
      "TaskCreate",
      "TaskUpdate",
      "TaskList",
      "TaskGet",
      "SendMessage",
      "mcp__*",
    ],
    deny: [
      "Write(/atlas/app/**)",
      "Edit(/atlas/app/**)",
      "Write(/atlas/logs/**)",
      "Edit(/atlas/logs/**)",
    ],
  },
  hooks: {
    SessionStart: [
      {
        hooks: [
          { type: "command", command: "/atlas/app/hooks/session-start.sh" },
        ],
      },
    ],
    Stop: [
      {
        hooks: [
          { type: "command", command: "/atlas/app/hooks/stop.sh" },
          {
            type: "prompt",
            prompt: stopCompletionPrompt,
            model: models.subagent_review,
          },
        ],
      },
    ],
    PreCompact: [
      {
        matcher: "auto",
        hooks: [
          { type: "command", command: "/atlas/app/hooks/pre-compact-auto.sh" },
        ],
      },
      {
        matcher: "manual",
        hooks: [
          {
            type: "command",
            command: "/atlas/app/hooks/pre-compact-manual.sh",
          },
        ],
      },
    ],
    SubagentStop: [
      {
        hooks: [
          {
            type: "prompt",
            prompt: subagentStopPrompt,
            model: models.subagent_review,
          },
        ],
      },
    ],
  },
};

mkdirSync(HOME + "/.claude", { recursive: true });
writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");

// Generate trigger MCP config: base .mcp.json + atlas-mcp + memory
const MCP_BASE_PATH = "/atlas/app/.mcp.json";
const MCP_TRIGGER_PATH = HOME + "/.mcp-trigger.json";
try {
  const baseMcp = JSON.parse(readFileSync(MCP_BASE_PATH, "utf-8"));
  baseMcp.mcpServers.work = {
    command: "bun",
    args: ["run", "/atlas/app/atlas-mcp/index.ts"],
  };
  baseMcp.mcpServers.memory = { command: "qmd", args: ["mcp"] };
  writeFileSync(MCP_TRIGGER_PATH, JSON.stringify(baseMcp, null, 2) + "\n");
  console.log("Trigger MCP config generated: " + MCP_TRIGGER_PATH);
} catch (e) {
  console.log("Warning: could not generate trigger MCP config:", e);
}

console.log(
  `Settings generated: main=${models.main}, subagent_review=${models.subagent_review}, hooks=${models.hooks}`,
);
