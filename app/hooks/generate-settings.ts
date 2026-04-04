#!/usr/bin/env bun
/**
 * Generate Claude Code settings.json from agent config.yml.
 * Reads model preferences and produces the hooks configuration.
 * Run from init.sh on every container start.
 */
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { resolveConfig, expandModelName } from "../lib/config.ts";

const HOME = process.env.HOME!;
const SETTINGS_PATH = HOME + "/.claude/settings.json";

// Resolve unified config (ENV > runtime JSON > config.yml > defaults)
const config = resolveConfig(HOME);

// Expand shorthand model names to full API names for Claude Code
const mainModel = expandModelName(config.models.main);
const subagentReviewModel = expandModelName(config.models.subagent_review);
const hooksModel = expandModelName(config.models.hooks);

// Write failure handling env file
const failureEnvContent = [
  `ATLAS_BACKOFF_INITIAL=${config.failure_handling.backoff_initial_seconds}`,
  `ATLAS_BACKOFF_MAX=${config.failure_handling.backoff_max_seconds}`,
  `ATLAS_NOTIFY_THRESHOLD_MINUTES=${config.failure_handling.notification_threshold_minutes}`,
  `ATLAS_NOTIFY_COMMAND=${JSON.stringify(config.failure_handling.notification_command)}`,
  "",
].join("\n");
writeFileSync(HOME + "/.failure-env", failureEnvContent);

// Beads session-isolated hooks — each session gets its own .beads/ directory
const beadsSessionScript = "/atlas/app/hooks/beads-session.sh";

// Stop completion prompt — secondary gate after the Beads command hook.
// The beads-session.sh check command already blocks exit if Beads tasks are open
// (RalphLoop-style, via {"decision":"block"} JSON). This prompt hook handles
// non-Beads checks that require conversation-level reasoning.
const stopCompletionPrompt = [
  "Review this session for non-task completion issues.",
  "Note: Beads task completion is already enforced by a prior hook — do not check for open tasks.",
  "",
  "Check:",
  "1. **Team lifecycle**: Were all teams properly shut down? (SendMessage shutdown_request to each teammate, then TeamDelete)",
  "2. **Response delivery**: If this session was triggered by an external message (Signal, Email, Web), was a response sent using the appropriate channel CLI tool (signal send, email reply, etc.)?",
  "",
  "If neither check applies (no teams created, not a trigger session), respond: {\"ok\": true}",
  "",
  "Respond with JSON:",
  '{"ok": true} — if the session can safely exit',
  '{"ok": false, "reason": "brief explanation of what is unfinished"} — if work is clearly incomplete',
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

// Build enabledPlugins map from config
const enabledPlugins: Record<string, boolean> = { ...config.plugins.enabled };

// Attribution: use agent email if configured, otherwise disable co-authored-by
const agentEmail = config.agent?.email;
const commitAttribution = agentEmail
  ? `Co-Authored-By: ${config.agent.name || "Atlas"} <${agentEmail}>`
  : "";

const settings: Record<string, unknown> = {
  env: {
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
    CLAUDE_MODEL: mainModel,
  },
  attribution: {
    commit: commitAttribution,
    pr: "",
  },
  enabledPlugins,
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
      "SendMessage",
      "mcp__*",
    ],
    deny: [
      "Write(/atlas/app/**)",
      "Edit(/atlas/app/**)",
      "Write(/atlas/logs/**)",
      "Edit(/atlas/logs/**)",
      "Write(/home/agent/.claude/settings.json)",
      "Edit(/home/agent/.claude/settings.json)",
      "TodoWrite",
      "TaskCreate",
      "TaskUpdate",
      "TaskList",
      "TaskGet",
    ],
  },
  hooks: {
    SessionStart: [
      {
        hooks: [
          { type: "command", command: "/atlas/app/hooks/session-start.sh" },
          { type: "command", command: `${beadsSessionScript} start` },
        ],
      },
    ],
    Stop: [
      {
        hooks: [
          { type: "command", command: "/atlas/app/hooks/stop.sh" },
          { type: "command", command: `${beadsSessionScript} check` },
          {
            type: "prompt",
            prompt: stopCompletionPrompt,
            model: subagentReviewModel,
          },
        ],
      },
    ],
    PreCompact: [
      {
        matcher: "auto",
        hooks: [
          { type: "command", command: "/atlas/app/hooks/pre-compact-auto.sh" },
          { type: "command", command: `${beadsSessionScript} prime` },
        ],
      },
      {
        matcher: "manual",
        hooks: [
          {
            type: "command",
            command: "/atlas/app/hooks/pre-compact-manual.sh",
          },
          { type: "command", command: `${beadsSessionScript} prime` },
        ],
      },
    ],
    SubagentStop: [
      {
        hooks: [
          {
            type: "prompt",
            prompt: subagentStopPrompt,
            model: subagentReviewModel,
          },
        ],
      },
    ],
  },
};

mkdirSync(HOME + "/.claude", { recursive: true });
writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");

// Generate trigger MCP config from base .mcp.json
const MCP_BASE_PATH = "/atlas/app/.mcp.json";
const MCP_TRIGGER_PATH = HOME + "/.mcp-trigger.json";
try {
  const baseMcp = JSON.parse(readFileSync(MCP_BASE_PATH, "utf-8"));
  writeFileSync(MCP_TRIGGER_PATH, JSON.stringify(baseMcp, null, 2) + "\n");
  console.log("Trigger MCP config generated: " + MCP_TRIGGER_PATH);
} catch (e) {
  console.log("Warning: could not generate trigger MCP config:", e);
}

console.log(
  `Settings generated: main=${mainModel}, subagent_review=${subagentReviewModel}, hooks=${hooksModel}`,
);
