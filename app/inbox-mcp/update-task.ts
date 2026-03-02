#!/usr/bin/env bun
/**
 * CLI: Safe parameterized task updates (no SQL injection).
 * Reads value from stdin when needed.
 *
 * Usage:
 *   bun run update-task.ts <task_id> processing
 *   bun run update-task.ts <task_id> reviewing <iteration>
 *   echo "$VALUE" | bun run update-task.ts <task_id> worker_result
 *   echo "$VALUE" | bun run update-task.ts <task_id> done
 *   echo "$VALUE" | bun run update-task.ts <task_id> failed
 */
import { getDb } from "./db";

const [taskId, command, arg] = process.argv.slice(2);

if (!taskId || !command) {
  console.error("Usage: update-task.ts <task_id> <command> [arg]");
  process.exit(2);
}

const db = getDb();
const id = Number(taskId);

/** Read all of stdin as text */
function readStdin(): string {
  try {
    return require("fs").readFileSync("/dev/stdin", "utf-8");
  } catch {
    return "";
  }
}

switch (command) {
  case "pending":
    db.prepare(
      "UPDATE tasks SET status='pending', processed_at=NULL WHERE id=?"
    ).run(id);
    break;

  case "processing":
    db.prepare(
      "UPDATE tasks SET status='processing', processed_at=datetime('now') WHERE id=?"
    ).run(id);
    break;

  case "reviewing": {
    const iteration = Number(arg || 1);
    db.prepare(
      "UPDATE tasks SET status='reviewing', review_iteration=? WHERE id=?"
    ).run(iteration, id);
    break;
  }

  case "worker_result": {
    const value = readStdin();
    db.prepare("UPDATE tasks SET worker_result=? WHERE id=?").run(value, id);
    break;
  }

  case "done": {
    const summary = readStdin();
    db.prepare(
      "UPDATE tasks SET status='done', response_summary=?, processed_at=datetime('now') WHERE id=?"
    ).run(summary, id);
    break;
  }

  case "failed": {
    const error = readStdin();
    db.prepare(
      "UPDATE tasks SET status='failed', response_summary=?, processed_at=datetime('now') WHERE id=?"
    ).run(error, id);
    break;
  }

  default:
    console.error(`Unknown command: ${command}`);
    process.exit(2);
}
