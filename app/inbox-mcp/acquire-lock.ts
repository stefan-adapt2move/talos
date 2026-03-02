#!/usr/bin/env bun
/**
 * CLI: Acquire a path lock for a task.
 * Usage: bun run acquire-lock.ts <task_id> <path> [pid]
 * Output: "acquired" or "conflict:<task_id>"
 * Exit:   0 = acquired, 1 = conflict
 */
import { acquirePathLock } from "./locks";

const [taskId, path, pid] = process.argv.slice(2);

if (!taskId || !path) {
  console.error("Usage: acquire-lock.ts <task_id> <path> [pid]");
  process.exit(2);
}

// Single atomic check-and-insert — no separate pre-check (avoids TOCTOU race)
const acquired = acquirePathLock(Number(taskId), path, pid ? Number(pid) : undefined);
if (acquired) {
  console.log("acquired");
  process.exit(0);
} else {
  console.log("conflict");
  process.exit(1);
}
