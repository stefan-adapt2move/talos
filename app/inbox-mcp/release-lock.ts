#!/usr/bin/env bun
/**
 * CLI: Release the path lock for a task.
 * Usage: bun run release-lock.ts <task_id>
 * Output: "released" or "not_found"
 */
import { releasePathLock } from "./locks";

const [taskId] = process.argv.slice(2);

if (!taskId) {
  console.error("Usage: release-lock.ts <task_id>");
  process.exit(2);
}

const released = releasePathLock(Number(taskId));
console.log(released ? "released" : "not_found");
