/**
 * Tests for trigger-runner.ts exported pure functions.
 * Uses Bun's built-in test runner.
 *
 * Run with: cd app/triggers && bun test
 */

import { test, describe, expect, beforeAll, afterAll } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, existsSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { Database } from "bun:sqlite";

import {
  buildSystemPrompt,
  resolveModel,
  getMcpServers,
  safePlaceholderReplace,
  readTriggerConfig,
  recordMetrics,
  checkCorruptedSession,
  tryIpcInject,
  type TriggerConfig,
  type MetricsData,
} from "./trigger-runner.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTempDir(): string {
  return mkdtempSync(join(tmpdir(), "atlas-trigger-test-"));
}

function createInMemoryDb(): Database {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE IF NOT EXISTS triggers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      channel TEXT DEFAULT 'internal',
      prompt TEXT DEFAULT '',
      session_mode TEXT DEFAULT 'ephemeral',
      enabled INTEGER DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS session_metrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_type TEXT NOT NULL,
      session_id TEXT,
      trigger_name TEXT,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      duration_ms INTEGER DEFAULT 0,
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      cache_read_tokens INTEGER DEFAULT 0,
      cache_creation_tokens INTEGER DEFAULT 0,
      cost_usd REAL DEFAULT 0,
      num_turns INTEGER DEFAULT 0,
      is_error INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now'))
    );
  `);
  return db;
}

// ---------------------------------------------------------------------------
// safePlaceholderReplace
// ---------------------------------------------------------------------------

describe("safePlaceholderReplace", () => {
  test("replaces simple placeholders", () => {
    const result = safePlaceholderReplace(
      "Hello {{name}}, welcome to {{place}}!",
      { "{{name}}": "Alice", "{{place}}": "Wonderland" }
    );
    expect(result).toBe("Hello Alice, welcome to Wonderland!");
  });

  test("handles values containing regex special characters", () => {
    const result = safePlaceholderReplace(
      "{{payload}}",
      { "{{payload}}": "price is $10.00 (USD) [+tax]" }
    );
    expect(result).toBe("price is $10.00 (USD) [+tax]");
  });

  test("handles values with backslashes", () => {
    const result = safePlaceholderReplace(
      "{{payload}}",
      { "{{payload}}": "path\\to\\file" }
    );
    expect(result).toBe("path\\to\\file");
  });

  test("replaces multiple occurrences", () => {
    const result = safePlaceholderReplace(
      "{{x}} and {{x}} again",
      { "{{x}}": "hello" }
    );
    expect(result).toBe("hello and hello again");
  });

  test("handles empty value", () => {
    const result = safePlaceholderReplace(
      "before {{empty}} after",
      { "{{empty}}": "" }
    );
    expect(result).toBe("before  after");
  });

  test("handles no-match gracefully", () => {
    const result = safePlaceholderReplace(
      "no placeholders here",
      { "{{missing}}": "value" }
    );
    expect(result).toBe("no placeholders here");
  });

  test("handles newlines in values", () => {
    const result = safePlaceholderReplace(
      "message: {{payload}}",
      { "{{payload}}": "line1\nline2\nline3" }
    );
    expect(result).toBe("message: line1\nline2\nline3");
  });
});

// ---------------------------------------------------------------------------
// buildSystemPrompt
// ---------------------------------------------------------------------------

describe("buildSystemPrompt", () => {
  let tmpDir: string;
  let appDir: string;
  let workspace: string;

  beforeAll(() => {
    tmpDir = makeTempDir();
    appDir = join(tmpDir, "app");
    workspace = join(tmpDir, "workspace");

    mkdirSync(join(appDir, "prompts"), { recursive: true });
    mkdirSync(workspace, { recursive: true });
  });

  afterAll(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  test("includes SOUL.md wrapped in soul tags", () => {
    writeFileSync(join(workspace, "SOUL.md"), "You are Atlas.");
    const result = buildSystemPrompt("internal", { appDir, workspace });
    expect(result).toContain("<soul");
    expect(result).toContain("You are Atlas.");
    expect(result).toContain("</soul>");
  });

  test("includes IDENTITY.md wrapped in identity tags", () => {
    writeFileSync(join(workspace, "IDENTITY.md"), "Identity content here.");
    const result = buildSystemPrompt("internal", { appDir, workspace });
    expect(result).toContain("<identity");
    expect(result).toContain("Identity content here.");
    expect(result).toContain("</identity>");
  });

  test("includes trigger-system-prompt.md after --- separator", () => {
    writeFileSync(
      join(appDir, "prompts", "trigger-system-prompt.md"),
      "Core trigger instructions."
    );
    const result = buildSystemPrompt("internal", { appDir, workspace });
    expect(result).toContain("---");
    expect(result).toContain("Core trigger instructions.");
  });

  test("includes channel-specific prompt after --- separator", () => {
    writeFileSync(
      join(appDir, "prompts", "trigger-channel-signal.md"),
      "Signal-specific instructions."
    );
    const result = buildSystemPrompt("signal", { appDir, workspace });
    expect(result).toContain("Signal-specific instructions.");
  });

  test("gracefully skips missing optional files", () => {
    // Create a fresh temp dir with no optional files
    const minimalTmpDir = makeTempDir();
    const minimalAppDir = join(minimalTmpDir, "app");
    const minimalWorkspace = join(minimalTmpDir, "workspace");
    mkdirSync(join(minimalAppDir, "prompts"), { recursive: true });
    mkdirSync(minimalWorkspace, { recursive: true });

    // Only create the core system prompt
    writeFileSync(
      join(minimalAppDir, "prompts", "trigger-system-prompt.md"),
      "Core prompt only."
    );

    const result = buildSystemPrompt("nonexistent-channel", {
      appDir: minimalAppDir,
      workspace: minimalWorkspace,
    });

    expect(result).toContain("Core prompt only.");
    // Should NOT throw and should NOT contain undefined/null
    expect(result).not.toContain("undefined");
    expect(result).not.toContain("null");

    rmSync(minimalTmpDir, { recursive: true, force: true });
  });

  test("concatenates sections with --- separators", () => {
    const result = buildSystemPrompt("internal", { appDir, workspace });
    // With both soul+identity and trigger-system-prompt.md, we expect --- separators
    expect(result).toContain("---");
  });
});

// ---------------------------------------------------------------------------
// resolveModel
// ---------------------------------------------------------------------------

describe("resolveModel", () => {
  let tmpDir: string;

  beforeAll(() => {
    tmpDir = makeTempDir();
  });

  afterAll(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // Note: pass [] as extraCandidates to isolate tests from ~/config.yml on the host

  test("reads trigger model from config.yml", () => {
    const configPath = join(tmpDir, "config.yml");
    writeFileSync(configPath, `
models:
  trigger: claude-sonnet-4-6
  cron: claude-haiku-4-5
`);
    expect(resolveModel(configPath, "trigger", [])).toBe("claude-sonnet-4-6");
  });

  test("reads cron model from config.yml", () => {
    const configPath = join(tmpDir, "config-cron.yml");
    writeFileSync(configPath, `
models:
  trigger: claude-sonnet-4-6
  cron: claude-haiku-4-5
`);
    expect(resolveModel(configPath, "cron", [])).toBe("claude-haiku-4-5");
  });

  test("falls back to default model when config missing", () => {
    const nonexistentPath = join(tmpDir, "nonexistent.yml");
    // Pass [] to prevent falling back to ~/config.yml on the host
    const model = resolveModel(nonexistentPath, "trigger", []);
    expect(model).toBe("claude-opus-4-6");
  });

  test("falls back to default model when key not in config", () => {
    const configPath = join(tmpDir, "config-no-trigger.yml");
    writeFileSync(configPath, `
models:
  cron: claude-haiku-4-5
`);
    // Pass [] to prevent falling back to ~/config.yml on the host
    const model = resolveModel(configPath, "trigger", []);
    expect(model).toBe("claude-opus-4-6");
  });

  test("falls back to trigger key when specific type not found", () => {
    const configPath = join(tmpDir, "config-fallback.yml");
    writeFileSync(configPath, `
models:
  trigger: claude-sonnet-4-6
`);
    // Asking for "cron" but only "trigger" is defined — should use trigger as fallback
    const model = resolveModel(configPath, "cron", []);
    expect(model).toBe("claude-sonnet-4-6");
  });

  test("handles malformed YAML gracefully", () => {
    const configPath = join(tmpDir, "broken.yml");
    writeFileSync(configPath, "{ this is: not valid: yaml: [");
    // Pass [] to prevent falling back to ~/config.yml on the host
    const model = resolveModel(configPath, "trigger", []);
    expect(model).toBe("claude-opus-4-6");
  });
});

// ---------------------------------------------------------------------------
// getMcpServers
// ---------------------------------------------------------------------------

describe("getMcpServers", () => {
  test("returns work and memory servers", () => {
    const servers = getMcpServers();
    expect(servers).toHaveProperty("work");
    expect(servers).toHaveProperty("memory");
  });

  test("work server uses bun command", () => {
    const servers = getMcpServers();
    expect(servers.work.command).toBe("bun");
    expect(servers.work.args).toContain("run");
    expect(servers.work.args.some((a) => a.includes("atlas-mcp"))).toBe(true);
  });

  test("memory server uses qmd command", () => {
    const servers = getMcpServers();
    expect(servers.memory.command).toBe("qmd");
    expect(servers.memory.args).toContain("mcp");
  });

  test("does not include URL-based servers", () => {
    const servers = getMcpServers();
    for (const config of Object.values(servers)) {
      expect(config).not.toHaveProperty("url");
    }
  });
});

// ---------------------------------------------------------------------------
// readTriggerConfig
// ---------------------------------------------------------------------------

describe("readTriggerConfig", () => {
  test("returns trigger config for existing trigger", () => {
    const db = createInMemoryDb();
    db.prepare(`
      INSERT INTO triggers (name, type, channel, prompt, session_mode, enabled)
      VALUES ('test-trigger', 'manual', 'signal', 'Do the thing', 'persistent', 1)
    `).run();

    const config = readTriggerConfig(db, "test-trigger");
    expect(config).not.toBeNull();
    expect(config!.name).toBe("test-trigger");
    expect(config!.channel).toBe("signal");
    expect(config!.prompt).toBe("Do the thing");
    expect(config!.session_mode).toBe("persistent");
    expect(config!.enabled).toBe(1);
  });

  test("returns null for missing trigger", () => {
    const db = createInMemoryDb();
    const config = readTriggerConfig(db, "nonexistent-trigger");
    expect(config).toBeNull();
  });

  test("handles trigger with default values", () => {
    const db = createInMemoryDb();
    db.prepare(`
      INSERT INTO triggers (name, type) VALUES ('minimal', 'cron')
    `).run();

    const config = readTriggerConfig(db, "minimal");
    expect(config).not.toBeNull();
    expect(config!.channel).toBe("internal");
    expect(config!.session_mode).toBe("ephemeral");
    expect(config!.enabled).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// recordMetrics
// ---------------------------------------------------------------------------

describe("recordMetrics", () => {
  test("inserts metrics row correctly", () => {
    const db = createInMemoryDb();

    const data: MetricsData = {
      sessionType: "trigger",
      sessionId: "sess-abc-123",
      triggerName: "test-trigger",
      startedAt: "2026-03-08T10:00:00Z",
      endedAt: "2026-03-08T10:01:00Z",
      durationMs: 60000,
      inputTokens: 1000,
      outputTokens: 500,
      cacheReadTokens: 200,
      cacheCreationTokens: 100,
      costUsd: 0.005,
      numTurns: 3,
      isError: false,
    };

    recordMetrics(db, data);

    const row = db.prepare("SELECT * FROM session_metrics LIMIT 1").get() as Record<string, unknown>;
    expect(row.session_type).toBe("trigger");
    expect(row.session_id).toBe("sess-abc-123");
    expect(row.trigger_name).toBe("test-trigger");
    expect(row.duration_ms).toBe(60000);
    expect(row.input_tokens).toBe(1000);
    expect(row.output_tokens).toBe(500);
    expect(row.cache_read_tokens).toBe(200);
    expect(row.cache_creation_tokens).toBe(100);
    expect(row.cost_usd).toBeCloseTo(0.005);
    expect(row.num_turns).toBe(3);
    expect(row.is_error).toBe(0);
  });

  test("records error flag correctly", () => {
    const db = createInMemoryDb();

    const data: MetricsData = {
      sessionType: "trigger",
      sessionId: "sess-error",
      triggerName: "test-trigger",
      startedAt: "2026-03-08T10:00:00Z",
      endedAt: "2026-03-08T10:00:05Z",
      durationMs: 5000,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      costUsd: 0,
      numTurns: 0,
      isError: true,
    };

    recordMetrics(db, data);

    const row = db.prepare("SELECT is_error FROM session_metrics LIMIT 1").get() as { is_error: number };
    expect(row.is_error).toBe(1);
  });

  test("handles empty session_id", () => {
    const db = createInMemoryDb();

    const data: MetricsData = {
      sessionType: "trigger",
      sessionId: "",
      triggerName: "test-trigger",
      startedAt: "2026-03-08T10:00:00Z",
      endedAt: "2026-03-08T10:00:00Z",
      durationMs: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      costUsd: 0,
      numTurns: 0,
      isError: false,
    };

    // Should not throw
    expect(() => recordMetrics(db, data)).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// checkCorruptedSession
// ---------------------------------------------------------------------------

describe("checkCorruptedSession", () => {
  let tmpDir: string;

  beforeAll(() => {
    tmpDir = makeTempDir();
  });

  afterAll(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  test("returns false for non-existent session", () => {
    expect(checkCorruptedSession("nonexistent-session-id", tmpDir)).toBe(false);
  });

  test("returns true when last JSONL line is queue-operation", () => {
    const sessionsDir = join(tmpDir, ".claude", "projects", "test-proj", "sessions");
    mkdirSync(sessionsDir, { recursive: true });

    const sessionId = "test-session-corrupted";
    const jsonlPath = join(sessionsDir, `${sessionId}.jsonl`);

    writeFileSync(jsonlPath, [
      JSON.stringify({ type: "user", content: "Hello" }),
      JSON.stringify({ type: "assistant", content: "Hi there" }),
      JSON.stringify({ type: "queue-operation", data: {} }),
    ].join("\n") + "\n");

    expect(checkCorruptedSession(sessionId, tmpDir)).toBe(true);
  });

  test("returns false when last JSONL line is not queue-operation", () => {
    const sessionsDir = join(tmpDir, ".claude", "projects", "test-proj", "sessions");
    mkdirSync(sessionsDir, { recursive: true });

    const sessionId = "test-session-healthy";
    const jsonlPath = join(sessionsDir, `${sessionId}.jsonl`);

    writeFileSync(jsonlPath, [
      JSON.stringify({ type: "user", content: "Hello" }),
      JSON.stringify({ type: "result", subtype: "success" }),
    ].join("\n") + "\n");

    expect(checkCorruptedSession(sessionId, tmpDir)).toBe(false);
  });

  test("returns false for empty JSONL file", () => {
    const sessionsDir = join(tmpDir, ".claude", "projects", "test-proj2", "sessions");
    mkdirSync(sessionsDir, { recursive: true });

    const sessionId = "test-session-empty";
    const jsonlPath = join(sessionsDir, `${sessionId}.jsonl`);

    writeFileSync(jsonlPath, "");

    expect(checkCorruptedSession(sessionId, tmpDir)).toBe(false);
  });

  test("returns false for malformed JSONL", () => {
    const sessionsDir = join(tmpDir, ".claude", "projects", "test-proj3", "sessions");
    mkdirSync(sessionsDir, { recursive: true });

    const sessionId = "test-session-malformed";
    const jsonlPath = join(sessionsDir, `${sessionId}.jsonl`);

    writeFileSync(jsonlPath, "not valid json\n");

    expect(checkCorruptedSession(sessionId, tmpDir)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// tryIpcInject
// ---------------------------------------------------------------------------

describe("tryIpcInject", () => {
  test("returns false for non-existent socket", async () => {
    const result = await tryIpcInject("nonexistent-session-id-12345", "hello");
    expect(result).toBe(false);
  });

  test("returns false for invalid socket path (no socket file)", async () => {
    // Use a session ID that definitely doesn't have a socket
    const result = await tryIpcInject("00000000-0000-0000-0000-000000000000", "test message");
    expect(result).toBe(false);
  });
});
