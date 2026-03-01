#!/usr/bin/env bun
/**
 * CLI: Wake a trigger session if it's awaiting a completed task.
 * Extracted from index.ts for use by task-runner.sh.
 * Usage: bun run wake-trigger.ts <task_id> <response_summary>
 */
import { mkdirSync, writeFileSync } from "fs";
import { getDb } from "./db";

const [taskId, responseSummary] = process.argv.slice(2);

if (!taskId || !responseSummary) {
  console.error("Usage: wake-trigger.ts <task_id> <response_summary>");
  process.exit(2);
}

const db = getDb();
const id = Number(taskId);

const awaiter = db.prepare(
  `SELECT ta.trigger_name, ta.session_key,
          COALESCE(ts.session_id, '') AS session_id,
          COALESCE(t.channel, 'internal') AS channel
   FROM task_awaits ta
   LEFT JOIN trigger_sessions ts ON ts.trigger_name = ta.trigger_name AND ts.session_key = ta.session_key
   LEFT JOIN triggers t ON t.name = ta.trigger_name
   WHERE ta.task_id = ?`
).get(id) as { trigger_name: string; session_key: string; session_id: string; channel: string } | undefined;

if (!awaiter) {
  console.log("no_awaiter");
  process.exit(0);
}

const wakeData = JSON.stringify({
  task_id: id,
  trigger_name: awaiter.trigger_name,
  session_key: awaiter.session_key,
  session_id: awaiter.session_id,
  channel: awaiter.channel,
  response_summary: responseSummary,
});

const indexDir = process.env.HOME + "/.index";
mkdirSync(indexDir, { recursive: true });

try {
  writeFileSync(
    `${indexDir}/.wake-${awaiter.trigger_name}-${id}`,
    wakeData,
  );
  // Only delete AFTER wake file is confirmed on disk
  db.prepare("DELETE FROM task_awaits WHERE task_id = ?").run(id);
  console.log(`woke:${awaiter.trigger_name}`);
} catch (e) {
  console.error(`Failed to write wake file for task ${id}: ${e}`);
  process.exit(1);
}
