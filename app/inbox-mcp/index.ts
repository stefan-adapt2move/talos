import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { mkdirSync, closeSync, openSync, writeFileSync } from "fs";
import { getDb } from "./db";

// --- Session context from environment ---
const ATLAS_TRIGGER = process.env.ATLAS_TRIGGER || "";
const ATLAS_TRIGGER_SESSION_KEY =
  process.env.ATLAS_TRIGGER_SESSION_KEY || "_default";
const IS_TRIGGER = !!ATLAS_TRIGGER;

/** Touch a file (create or update mtime) */
function touchFile(path: string): void {
  closeSync(openSync(path, "w"));
}

/** JSON MCP response helper */
function ok(data: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
  };
}
function err(message: string) {
  return {
    content: [
      { type: "text" as const, text: JSON.stringify({ error: message }) },
    ],
  };
}

const server = new McpServer({
  name: "inbox-mcp",
  version: "2.0.0",
});

// =============================================================================
// TRIGGER TOOLS — only registered when ATLAS_TRIGGER is set
// =============================================================================
if (IS_TRIGGER) {
  // --- task_create: Create a task for the worker session ---
  server.tool(
    "task_create",
    "Create a task for the worker session. Automatically wakes a task-runner and registers for re-awakening when done. Tasks with non-overlapping paths can run in parallel.",
    {
      content: z
        .string()
        .describe(
          "Task brief with full context, including acceptance criteria / definition of done (self-contained — worker has no access to this conversation)",
        ),
      path: z
        .string()
        .optional()
        .describe(
          "Optional working directory path for the task. Specify the project directory (e.g. '/home/atlas/projects/myapp'). The path and all subdirectories are locked during execution, preventing conflicting parallel writes. Tasks with non-overlapping paths run in parallel. Omit for tasks that don't modify files (research, browser automation, etc.).",
        ),
      review: z
        .boolean()
        .optional()
        .default(false)
        .describe(
          "Whether a review agent should verify the work before marking it done. Default: false. Set to true for more complex tasks.",
        ),
    },
    async ({ content, path, review }) => {
      const db = getDb();

      const task = db
        .prepare(
          "INSERT INTO tasks (trigger_name, content, path, review) VALUES (?, ?, ?, ?) RETURNING *",
        )
        .get(ATLAS_TRIGGER, content, path || null, review ? 1 : 0) as any;
      const taskId = task.id;

      // Auto-register for re-awakening
      db.prepare(
        "INSERT OR REPLACE INTO task_awaits (task_id, trigger_name, session_key) VALUES (?, ?, ?)",
      ).run(taskId, ATLAS_TRIGGER, ATLAS_TRIGGER_SESSION_KEY);

      // Write per-task wake file to signal the watcher
      const indexDir2 = process.env.HOME + "/.index";
      mkdirSync(indexDir2, { recursive: true });
      writeFileSync(
        `${indexDir2}/.wake-task-${taskId}`,
        JSON.stringify({
          task_id: taskId,
          path: path || null,
        }),
      );

      return ok(task);
    },
  );

  // --- task_get: Check task status ---
  server.tool(
    "task_get",
    "Get a specific task by ID — check its status and response_summary",
    {
      task_id: z.number().describe("ID of the task to retrieve"),
    },
    async ({ task_id }) => {
      const db = getDb();
      const task = db.prepare("SELECT * FROM tasks WHERE id = ?").get(task_id);
      if (!task) return err(`Task ${task_id} not found`);
      return ok(task);
    },
  );

  // --- task_update: Update a pending task ---
  server.tool(
    "task_update",
    "Update the content of a pending task. Only works if the worker hasn't picked it up yet (status='pending').",
    {
      task_id: z.number().describe("ID of the task to update"),
      content: z.string().describe("New task brief content"),
    },
    async ({ task_id, content }) => {
      const db = getDb();
      const task = db
        .prepare("SELECT status FROM tasks WHERE id = ?")
        .get(task_id) as { status: string } | undefined;
      if (!task) return err(`Task ${task_id} not found`);
      if (task.status !== "pending")
        return err(
          `Task ${task_id} is '${task.status}' — can only update pending tasks`,
        );
      db.prepare("UPDATE tasks SET content = ? WHERE id = ?").run(
        content,
        task_id,
      );
      return ok(db.prepare("SELECT * FROM tasks WHERE id = ?").get(task_id));
    },
  );

  // --- task_cancel: Cancel a pending task ---
  server.tool(
    "task_cancel",
    "Cancel a pending task. Only works if the worker hasn't picked it up yet (status='pending').",
    {
      task_id: z.number().describe("ID of the task to cancel"),
      reason: z.string().optional().describe("Reason for cancellation"),
    },
    async ({ task_id, reason }) => {
      const db = getDb();
      const task = db
        .prepare("SELECT status FROM tasks WHERE id = ?")
        .get(task_id) as { status: string } | undefined;
      if (!task) return err(`Task ${task_id} not found`);
      if (task.status !== "pending")
        return err(
          `Task ${task_id} is '${task.status}' — can only cancel pending tasks`,
        );
      db.prepare(
        "UPDATE tasks SET status = 'cancelled', response_summary = ?, processed_at = datetime('now') WHERE id = ?",
      ).run(reason ? `Cancelled: ${reason}` : "Cancelled", task_id);
      db.prepare("DELETE FROM task_awaits WHERE task_id = ?").run(task_id);
      return ok(db.prepare("SELECT * FROM tasks WHERE id = ?").get(task_id));
    },
  );

  // --- task_lock_status: View active path locks ---
  server.tool(
    "task_lock_status",
    "View active path locks to understand which directories are currently locked by running tasks.",
    {},
    async () => {
      const db = getDb();
      const locks = db
        .prepare(
          `SELECT pl.task_id, pl.locked_path, pl.pid, pl.locked_at, t.status
         FROM path_locks pl
         JOIN tasks t ON t.id = pl.task_id
         ORDER BY pl.locked_at ASC`,
        )
        .all();
      const activeCount = db
        .prepare(
          "SELECT COUNT(*) as count FROM tasks WHERE status IN ('processing', 'reviewing')",
        )
        .get() as { count: number };
      return ok({ active_workers: activeCount.count, locks });
    },
  );
}

// --- Start server ---
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((e) => {
  console.error("Fatal error:", e);
  process.exit(1);
});
