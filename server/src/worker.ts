import { pool } from "./db.js";
import { sendDueDigests } from "./digest.js";

let running = false;

async function run(): Promise<void> {
  if (running) return;
  running = true;
  try {
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
