import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { getDb } from "./db";
import { acquirePathLock, releasePathLock, getActiveLocks } from "./locks";

// --- Session context from environment ---
const TALOS_TRIGGER = process.env.TALOS_TRIGGER || "";
const IS_TRIGGER = !!TALOS_TRIGGER;

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
  name: "work-mcp",
  version: "3.0.0",
});

// =============================================================================
// TRIGGER TOOLS — only registered when TALOS_TRIGGER is set
// =============================================================================
if (IS_TRIGGER) {
  // --- path_lock: Acquire a path lock before spawning an agent ---
  server.tool(
    "path_lock",
    "Acquire a path lock before spawning an agent for file-modifying work. Prevents concurrent writes to the same directory. Stores the trigger's PID for crash recovery.",
    {
      path: z
        .string()
        .describe(
          "Directory path to lock (e.g. '/home/talos/projects/myapp'). The path and all subdirectories are locked, preventing conflicting parallel writes.",
        ),
    },
    async ({ path }) => {
      const pid = process.pid;
      // Use PID as a pseudo task_id for lock tracking
      const acquired = acquirePathLock(pid, path, pid);
      if (!acquired) {
        const locks = getActiveLocks();
        const conflict = locks.find(
          (l) =>
            path.startsWith(l.locked_path) ||
            l.locked_path.startsWith(path + "/"),
        );
        return err(
          `Path conflict: ${path} is locked by PID ${conflict?.pid || "unknown"} (path: ${conflict?.locked_path || "unknown"})`,
        );
      }
      return ok({ locked: true, path, pid });
    },
  );

  // --- path_unlock: Release a path lock after agent completes ---
  server.tool(
    "path_unlock",
    "Release a path lock after an agent completes its work.",
    {
      path: z.string().describe("Directory path to unlock"),
    },
    async ({ path }) => {
      const db = getDb();
      const norm = path.endsWith("/") ? path : path + "/";
      const result = db
        .prepare("DELETE FROM path_locks WHERE locked_path = ?")
        .run(norm);
      return ok({
        unlocked: result.changes > 0,
        path,
      });
    },
  );

  // --- path_lock_status: View active path locks ---
  server.tool(
    "path_lock_status",
    "View active path locks to understand which directories are currently locked.",
    {},
    async () => {
      const locks = getActiveLocks();
      return ok({ locks });
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
