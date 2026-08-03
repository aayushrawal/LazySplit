import * as http2 from "node:http2";
import { importPKCS8, SignJWT } from "jose";
import { config } from "./config.js";
import { pool } from "./db.js";

type Device = { token: string; user_id: string; timezone: string; digest_hour: number; last_digest_date: string | null; pending_count: number };

export async function sendDueDigests(now = new Date()): Promise<number> {
  if (!config.APNS_PRIVATE_KEY || !config.APNS_KEY_ID || !config.APNS_TEAM_ID || !config.APNS_TOPIC) return 0;
  const result = await pool.query<Device>(
    `SELECT d.token,d.user_id,d.timezone,d.digest_hour,d.last_digest_date,
      (SELECT count(*)::integer FROM transactions t WHERE t.user_id=d.user_id AND t.review_state='needsReview' AND NOT t.pending) AS pending_count
     FROM devices d WHERE d.enabled=true`);
  let sent = 0;
  for (const device of result.rows) {
    const parts = localParts(now, device.timezone);
    if (parts.hour !== device.digest_hour || device.pending_count < 1 || device.last_digest_date === parts.date) continue;
    await sendAPNS(device.token, { aps: { alert: { title: "Ready for a quick review", body: `${device.pending_count} posted charge${device.pending_count === 1 ? " is" : "s are"} waiting in LazySplit.` }, sound: "default", badge: device.pending_count } });
    await pool.query("UPDATE devices SET last_digest_date=$1,updated_at=now() WHERE token=$2", [parts.date, device.token]); sent++;
  }
  return sent;
}

function localParts(date: Date, timezone: string): { date: string; hour: number } {
  const values = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" }).formatToParts(date);
  const get = (type: string) => values.find((part) => part.type === type)?.value ?? "";
  return { date: `${get("year")}-${get("month")}-${get("day")}`, hour: Number(get("hour")) };
}

async function sendAPNS(deviceToken: string, payload: unknown): Promise<void> {
  const privateKey = config.APNS_PRIVATE_KEY.replace(/\\n/g, "\n");
  const key = await importPKCS8(privateKey, "ES256");
  const jwt = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: config.APNS_KEY_ID }).setIssuer(config.APNS_TEAM_ID).setIssuedAt().sign(key);
  const host = config.NODE_ENV === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
  const client = http2.connect(host);
  await new Promise<void>((resolve, reject) => {
    const request = client.request({ ":method": "POST", ":path": `/3/device/${deviceToken}`, authorization: `bearer ${jwt}`, "apns-topic": config.APNS_TOPIC, "apns-push-type": "alert", "apns-priority": "10" });
    let status = 0; request.on("response", (headers) => { status = Number(headers[":status"]); });
    request.on("error", reject); request.on("end", () => status === 200 ? resolve() : reject(new Error(`APNs rejected notification (${status})`)));
    request.end(JSON.stringify(payload));
  }).finally(() => client.close());
}
