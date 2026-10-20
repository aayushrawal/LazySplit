import { pool } from "./db.js";
import { sendDueDigests } from "./digest.js";
import { syncActiveConnections } from "./plaid.js";

let running = false;
let lastPlaidSyncAt = 0;
const plaidSyncIntervalMilliseconds = 15 * 60_000;

async function run(): Promise<void> {
  if (running) return;
  running = true;
  try {
    if (Date.now() - lastPlaidSyncAt >= plaidSyncIntervalMilliseconds) {
      // Advance every active cursor even when an institution webhook is delayed or missed.
      lastPlaidSyncAt = Date.now();
      const result = await syncActiveConnections();
      if (result.syncedCount > 0 || result.failedCount > 0) {
        console.log(`Plaid sync completed: ${result.syncedCount} succeeded, ${result.failedCount} failed.`);
      }
    }
    const sent = await sendDueDigests();
    if (sent > 0) console.log(`Sent ${sent} LazySplit digest notification${sent === 1 ? "" : "s"}.`);
  } catch (error) {
    console.error("Digest worker failed:", error instanceof Error ? error.message : "unknown error");
  } finally {
    running = false;
  }
}

await run();
const timer = setInterval(run, 60_000);

async function shutdown(): Promise<void> {
  clearInterval(timer);
  await pool.end();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
