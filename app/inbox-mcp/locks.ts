import { resolve } from "path";
import { getDb } from "./db";

/** Normalize a path to absolute with trailing slash for prefix matching */
export function normalizePath(p: string): string {
  const abs = resolve(p);
  return abs.endsWith("/") ? abs : abs + "/";
}

/** Check if a new path conflicts with any existing lock (bidirectional) */
export function hasPathConflict(path: string): { task_id: number; locked_path: string } | null {
  const db = getDb();
  const norm = normalizePath(path);

  // Check both directions:
  // 1. New path is under an existing lock (ancestor locked)
  // 2. Existing lock is under the new path (descendant locked)
  const conflict = db.prepare(
    `SELECT task_id, locked_path FROM path_locks
     WHERE ? LIKE locked_path || '%'
        OR locked_path LIKE ? || '%'
     LIMIT 1`
  ).get(norm, norm) as { task_id: number; locked_path: string } | undefined;

  return conflict || null;
}

/** Acquire a path lock for a task. Returns true if acquired, false if conflict. */
export function acquirePathLock(taskId: number, path: string, pid?: number): boolean {
  const db = getDb();
  const norm = normalizePath(path);

  // Use a transaction to atomically check + insert
  const txn = db.transaction(() => {
    const conflict = db.prepare(
      `SELECT task_id, locked_path FROM path_locks
       WHERE ? LIKE locked_path || '%'
          OR locked_path LIKE ? || '%'
       LIMIT 1`
    ).get(norm, norm);

    if (conflict) return false;

    db.prepare(
      "INSERT INTO path_locks (task_id, locked_path, pid) VALUES (?, ?, ?)"
    ).run(taskId, norm, pid || null);

    return true;
  });

  return txn();
}

/** Release the path lock for a task */
export function releasePathLock(taskId: number): boolean {
  const db = getDb();
  const result = db.prepare("DELETE FROM path_locks WHERE task_id = ?").run(taskId);
  return result.changes > 0;
}

/** Get all active path locks */
export function getActiveLocks(): Array<{ task_id: number; locked_path: string; pid: number | null; locked_at: string }> {
  const db = getDb();
  return db.prepare("SELECT task_id, locked_path, pid, locked_at FROM path_locks ORDER BY locked_at ASC").all() as any[];
}

/** Clean up stale locks where the PID is no longer running */
export function cleanupStaleLocks(): number {
  const db = getDb();
  const locks = db.prepare("SELECT task_id, pid FROM path_locks WHERE pid IS NOT NULL").all() as Array<{ task_id: number; pid: number }>;

  let cleaned = 0;
  for (const lock of locks) {
    try {
      // Check if process is still alive (signal 0 = no signal, just check)
      process.kill(lock.pid, 0);
    } catch {
      // Process doesn't exist — stale lock
      db.prepare("DELETE FROM path_locks WHERE task_id = ?").run(lock.task_id);
      // Reset task to pending so it can be re-dispatched
      db.prepare("UPDATE tasks SET status = 'pending', processed_at = NULL WHERE id = ? AND status IN ('processing', 'reviewing')").run(lock.task_id);
      cleaned++;
    }
  }

  return cleaned;
}

/** Count active task-runner processes (tasks in processing/reviewing state) */
export function activeWorkerCount(): number {
  const db = getDb();
  const result = db.prepare(
    "SELECT COUNT(*) as count FROM tasks WHERE status IN ('processing', 'reviewing')"
  ).get() as { count: number };
  return result.count;
}
