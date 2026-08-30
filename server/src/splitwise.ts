import { createHmac, timingSafeEqual } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireUser } from "./auth.js";
import { config } from "./config.js";
import { decryptToken, encryptToken } from "./crypto.js";
import { pool, transaction } from "./db.js";

const apiBase = "https://secure.splitwise.com/api/v3.0";
const publishSchema = z.object({
  draftID: z.string().uuid(), transactionID: z.string().uuid(), merchant: z.string().min(1).max(255), date: z.string().datetime(),
  amountMinor: z.number().int().positive(), currencyCode: z.string().length(3), groupID: z.number().int().optional().nullable(),
  participants: z.array(z.object({ userID: z.number().int(), owedMinor: z.number().int().nonnegative(), paidMinor: z.number().int().nonnegative() })).min(1)
});

export async function splitwiseRoutes(app: FastifyInstance): Promise<void> {
  app.get("/v1/splitwise/connect", { preHandler: requireUser }, async (request) => {
    const state = signedState(request.userID);
    const url = new URL("https://secure.splitwise.com/oauth/authorize");
    url.searchParams.set("response_type", "code"); url.searchParams.set("client_id", config.SPLITWISE_CLIENT_ID);
    url.searchParams.set("redirect_uri", config.SPLITWISE_REDIRECT_URI); url.searchParams.set("state", state);
    return { url: url.toString() };
  });

  app.get("/v1/splitwise/callback", async (request, reply) => {
    const query = z.object({ code: z.string(), state: z.string() }).parse(request.query);
    const userID = verifyState(query.state);
    const body = new URLSearchParams({ grant_type: "authorization_code", code: query.code, redirect_uri: config.SPLITWISE_REDIRECT_URI, client_id: config.SPLITWISE_CLIENT_ID, client_secret: config.SPLITWISE_CLIENT_SECRET });
    const response = await fetch("https://secure.splitwise.com/oauth/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
    const token = await response.json() as { access_token?: string; error?: string };
    if (!response.ok || !token.access_token) throw new Error(token.error ?? "Splitwise authorization failed");
    await pool.query(
      `INSERT INTO provider_connections (user_id, provider, provider_item_id, encrypted_token) VALUES ($1,'splitwise','account',$2)
       ON CONFLICT (user_id, provider, provider_item_id) DO UPDATE SET encrypted_token=EXCLUDED.encrypted_token,status='active',updated_at=now()`,
      [userID, encryptToken(token.access_token)]);
    await refreshCache(userID);
    return reply.type("text/html").send("<html><body><h2>Splitwise connected.</h2><p>You can return to LazySplit.</p></body></html>");
  });

  app.get("/v1/splitwise/friends", { preHandler: requireUser }, async (request) => {
    let cached = await pool.query<{ friends: unknown[] }>("SELECT friends FROM splitwise_cache WHERE user_id=$1", [request.userID]);
    if (!cached.rows[0]) { await refreshCache(request.userID); cached = await pool.query("SELECT friends FROM splitwise_cache WHERE user_id=$1", [request.userID]); }
    const raw = cached.rows[0]?.friends ?? [];
    const friends = raw.map((entry: any) => ({ id: entry.id, firstName: entry.first_name, lastName: entry.last_name ?? null }));
    return { friends };
  });

  app.delete("/v1/splitwise", { preHandler: requireUser }, async (request) => {
    await transaction(async (client) => {
      await client.query("DELETE FROM splitwise_cache WHERE user_id=$1", [request.userID]);
      await client.query("DELETE FROM provider_connections WHERE user_id=$1 AND provider='splitwise'", [request.userID]);
    });
    return {};
  });

  app.post("/v1/splitwise/publish", { preHandler: requireUser }, async (request, reply) => {
    const key = z.string().min(8).parse(request.headers["idempotency-key"]), body = publishSchema.parse(request.body);
    const existing = await pool.query<{ status_code: number | null; response: unknown }>("SELECT status_code,response FROM idempotency_keys WHERE user_id=$1 AND idempotency_key=$2", [request.userID, key]);
    if (existing.rows[0]?.status_code) return reply.code(existing.rows[0].status_code).send(existing.rows[0].response);
    await pool.query("INSERT INTO idempotency_keys(user_id,idempotency_key) VALUES($1,$2) ON CONFLICT DO NOTHING", [request.userID, key]);
    const result = await transaction(async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [request.userID + body.transactionID]);
      const source = await client.query("SELECT review_state,pending,is_credit FROM transactions WHERE id=$1 AND user_id=$2", [body.transactionID, request.userID]);
      if (!source.rowCount) throw Object.assign(new Error("Transaction not found."), { statusCode: 404 });
      if (source.rows[0].review_state === "personal" || source.rows[0].pending || source.rows[0].is_credit) {
        throw Object.assign(new Error("Personal transactions, pending charges, and credits cannot be published."), { statusCode: 409 });
      }
      return publishExpense(request.userID, body);
    });
    const responseBody = { expenseID: result };
    await pool.query("UPDATE idempotency_keys SET status_code=200,response=$1::jsonb WHERE user_id=$2 AND idempotency_key=$3", [JSON.stringify(responseBody), request.userID, key]);
    return responseBody;
  });
}

async function tokenFor(userID: string): Promise<string> {
  const result = await pool.query<{ encrypted_token: string }>("SELECT encrypted_token FROM provider_connections WHERE user_id=$1 AND provider='splitwise' AND status='active'", [userID]);
  if (!result.rows[0]) throw Object.assign(new Error("Connect Splitwise first."), { statusCode: 409 });
  return decryptToken(result.rows[0].encrypted_token);
}

async function sw<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const response = await fetch(`${apiBase}${path}`, { ...init, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init?.headers ?? {}) } });
      const retryable = response.status === 429 || response.status >= 500;
      if (retryable && attempt < 3 && (response.status === 429 || !init?.method || init.method === "GET")) {
        const retryAfter = Number(response.headers.get("retry-after"));
        await new Promise((resolve) => setTimeout(resolve, Number.isFinite(retryAfter) && retryAfter > 0 ? Math.min(retryAfter * 1_000, 5_000) : 250 * 2 ** attempt));
        continue;
      }
      const data = await response.json() as T & { errors?: Record<string, unknown> };
      if (!response.ok) throw Object.assign(new Error(`Splitwise request failed (${response.status})`), { statusCode: response.status });
      if (data.errors && Object.keys(data.errors).length > 0) throw Object.assign(new Error(`Splitwise rejected the expense: ${JSON.stringify(data.errors)}`), { statusCode: 422 });
      return data;
    } catch (error) {
      const isRead = !init?.method || init.method === "GET";
      const hasStatus = error instanceof Error && "statusCode" in error;
      if (!isRead || hasStatus || attempt === 3) throw error;
      await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
    }
  }
  throw new Error("Splitwise rate limit retry exhausted");
}

async function refreshCache(userID: string): Promise<void> {
  const token = await tokenFor(userID);
  const [me, friends, groups, categories] = await Promise.all([
    sw<{ user: unknown }>(token, "/get_current_user"), sw<{ friends: unknown[] }>(token, "/get_friends"),
    sw<{ groups: unknown[] }>(token, "/get_groups"), sw<{ categories: unknown[] }>(token, "/get_categories")
  ]);
  await pool.query(
    `INSERT INTO splitwise_cache(user_id,splitwise_user,friends,groups,categories) VALUES($1,$2::jsonb,$3::jsonb,$4::jsonb,$5::jsonb)
     ON CONFLICT(user_id) DO UPDATE SET splitwise_user=EXCLUDED.splitwise_user,friends=EXCLUDED.friends,groups=EXCLUDED.groups,categories=EXCLUDED.categories,refreshed_at=now()`,
    [userID, JSON.stringify(me.user), JSON.stringify(friends.friends), JSON.stringify(groups.groups), JSON.stringify(categories.categories)]);
}

async function publishExpense(userID: string, body: z.infer<typeof publishSchema>): Promise<number> {
  const token = await tokenFor(userID), marker = `LazySplit:${body.draftID}`;
  const prior = await pool.query<{ splitwise_expense_id: string | null }>("SELECT splitwise_expense_id FROM split_drafts WHERE id=$1 AND user_id=$2", [body.draftID, userID]);
  if (prior.rows[0]?.splitwise_expense_id) return Number(prior.rows[0].splitwise_expense_id);
  const date = body.date.slice(0, 10);
  const remote = await sw<{ expenses: { id: number; details?: string | null }[] }>(token, `/get_expenses?dated_after=${date}T00:00:00Z&dated_before=${date}T23:59:59Z&limit=100`);
  const found = remote.expenses.find((expense) => expense.details?.includes(marker));
  if (found) { await saveDraft(userID, body, marker, found.id); return found.id; }
  const cache = await pool.query<{ splitwise_user: { id?: number } }>("SELECT splitwise_user FROM splitwise_cache WHERE user_id=$1", [userID]);
  const selfID = cache.rows[0]?.splitwise_user.id;
  if (!selfID) { await refreshCache(userID); return publishExpense(userID, body); }
  const friendOwed = body.participants.reduce((sum, item) => sum + item.owedMinor, 0);
  if (friendOwed > body.amountMinor) throw Object.assign(new Error("Participant shares exceed the expense total."), { statusCode: 422 });
  const payload: Record<string, string | number | boolean | null> = {
    cost: (body.amountMinor / 100).toFixed(2), description: body.merchant, details: marker, date: body.date,
    currency_code: body.currencyCode, group_id: body.groupID ?? 0,
    users__0__user_id: selfID, users__0__paid_share: (body.amountMinor / 100).toFixed(2), users__0__owed_share: ((body.amountMinor - friendOwed) / 100).toFixed(2)
  };
  body.participants.forEach((participant, index) => {
    payload[`users__${index + 1}__user_id`] = participant.userID;
    payload[`users__${index + 1}__paid_share`] = (participant.paidMinor / 100).toFixed(2);
    payload[`users__${index + 1}__owed_share`] = (participant.owedMinor / 100).toFixed(2);
  });
  const created = await sw<{ expenses: { id: number }[] }>(token, "/create_expense", { method: "POST", body: JSON.stringify(payload) });
  const id = created.expenses[0]?.id;
  if (!id) throw new Error("Splitwise did not return the created expense.");
  await saveDraft(userID, body, marker, id); return id;
}

async function saveDraft(userID: string, body: z.infer<typeof publishSchema>, marker: string, expenseID: number): Promise<void> {
  await pool.query(
    `INSERT INTO split_drafts(id,user_id,transaction_id,payload,state,splitwise_expense_id,marker) VALUES($1,$2,$3,$4::jsonb,'published',$5,$6)
     ON CONFLICT(id) DO UPDATE SET state='published',splitwise_expense_id=EXCLUDED.splitwise_expense_id,updated_at=now()`,
    [body.draftID, userID, body.transactionID, JSON.stringify(body), expenseID, marker]);
}

function signedState(userID: string): string {
  const payload = Buffer.from(JSON.stringify({ userID, exp: Date.now() + 10 * 60_000 })).toString("base64url");
  const signature = createHmac("sha256", config.SESSION_SECRET).update(payload).digest("base64url");
  return `${payload}.${signature}`;
}
function verifyState(value: string): string {
  const [payload, signature] = value.split("."); if (!payload || !signature) throw new Error("Invalid OAuth state");
  const expected = createHmac("sha256", config.SESSION_SECRET).update(payload).digest();
  const actual = Buffer.from(signature, "base64url"); if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) throw new Error("Invalid OAuth state");
  const decoded = JSON.parse(Buffer.from(payload, "base64url").toString()) as { userID: string; exp: number };
  if (decoded.exp < Date.now()) throw new Error("OAuth state expired"); return decoded.userID;
}
