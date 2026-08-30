import { createHash, timingSafeEqual } from "node:crypto";
import { decodeProtectedHeader, importJWK, jwtVerify, type JWK } from "jose";
import type { FastifyInstance } from "fastify";
import type { PoolClient } from "pg";
import { z } from "zod";
import { config } from "./config.js";
import { decryptToken, encryptToken, hash } from "./crypto.js";
import { pool, transaction } from "./db.js";
import { requireUser } from "./auth.js";

const plaidBase = `https://${config.PLAID_ENV}.plaid.com`;
const verificationKeys = new Map<string, JWK>();

type PlaidTransaction = {
  transaction_id: string; account_id: string; amount: number; iso_currency_code: string | null;
  date: string; merchant_name: string | null; name: string; original_description?: string | null;
  pending: boolean; pending_transaction_id?: string | null;
  personal_finance_category?: { primary: string; detailed: string } | null;
  location?: { city?: string | null; region?: string | null; country?: string | null } | null;
  payment_channel?: string | null;
};
type SyncResponse = { added: PlaidTransaction[]; modified: PlaidTransaction[]; removed: { transaction_id: string }[]; next_cursor: string; has_more: boolean; error_code?: string };
type HostedLinkStatus = { state: "pending" | "processing" | "connected" | "exited" | "failed"; connected_count: number; error_message: string | null };
type HostedLinkGetResponse = {
  link_sessions?: Array<{
    finished_at?: string | null;
    on_success?: { public_token?: string | null } | null;
    results?: { item_add_results?: Array<{ public_token?: string | null }> } | null;
  }>;
};

async function plaid<T>(path: string, body: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${plaidBase}${path}`, {
    method: "POST", headers: { "Content-Type": "application/json", "PLAID-CLIENT-ID": config.PLAID_CLIENT_ID, "PLAID-SECRET": config.PLAID_SECRET }, body: JSON.stringify(body)
  });
  const data = await response.json() as T & { error_message?: string };
  if (!response.ok) throw Object.assign(new Error(data.error_message ?? `Plaid request failed (${response.status})`), { statusCode: response.status, data });
  return data;
}

export async function plaidRoutes(app: FastifyInstance): Promise<void> {
  app.post("/v1/plaid/link-token", { preHandler: requireUser }, async (request) => {
    const result = await plaid<{ link_token: string }>("/link/token/create", {
      user: { client_user_id: request.userID }, client_name: "LazySplit", language: "en", country_codes: ["US"],
      products: ["transactions"], transactions: { days_requested: 730 }, webhook: `${config.PUBLIC_BASE_URL}/v1/plaid/webhook`, redirect_uri: config.PLAID_REDIRECT_URI
    });
    return { linkToken: result.link_token };
  });

  app.post("/v1/plaid/hosted-link", { preHandler: requireUser }, async (request) => {
    await pool.query("DELETE FROM plaid_link_sessions WHERE expires_at < now() - interval '1 day'");
    const result = await plaid<{ link_token: string; hosted_link_url?: string; expiration: string }>("/link/token/create", {
      user: { client_user_id: request.userID }, client_name: "LazySplit", language: "en", country_codes: ["US"],
      products: ["transactions"], transactions: { days_requested: 730 }, webhook: `${config.PUBLIC_BASE_URL}/v1/plaid/webhook`,
      redirect_uri: config.PLAID_REDIRECT_URI,
      hosted_link: { is_mobile_app: true, completion_redirect_uri: "lazysplit://plaid-hosted-complete", url_lifetime_seconds: 1800 }
    });
    if (!result.hosted_link_url) throw Object.assign(new Error("Plaid Hosted Link is unavailable for this account."), { statusCode: 502 });
    const inserted = await pool.query<{ id: string }>(
      `INSERT INTO plaid_link_sessions(user_id,link_token_hash,encrypted_link_token,expires_at)
       VALUES($1,$2,$3,$4) RETURNING id`,
      [request.userID, hash(result.link_token), encryptToken(result.link_token), result.expiration]);
    return { sessionID: inserted.rows[0]!.id, hostedLinkURL: result.hosted_link_url };
  });

  app.post("/v1/plaid/hosted-link/:id/complete", { preHandler: requireUser }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    await pool.query(
      `UPDATE plaid_link_sessions SET state='exited',error_message='This Plaid connection session expired. Please try again.',updated_at=now()
       WHERE id=$1 AND user_id=$2 AND state='pending' AND expires_at < now()`, [id, request.userID]);
    const existing = await hostedSession(id, request.userID);
    if (!existing) return reply.code(404).send({ message: "Plaid connection session not found." });
    if (existing.state === "pending" || existing.state === "failed") await refreshHostedSession(id, request.userID);
    const current = await hostedSession(id, request.userID);
    return { status: current!.state, connectedCount: current!.connected_count, message: current!.error_message };
  });

  app.post("/v1/plaid/exchange", { preHandler: requireUser }, async (request) => {
    const body = z.object({ publicToken: z.string().min(1) }).parse(request.body);
    await exchangePublicToken(request.userID, body.publicToken);
    return {};
  });

  app.delete("/v1/plaid", { preHandler: requireUser }, async (request) => {
    const connections = await pool.query<{ encrypted_token: string }>(
      "SELECT encrypted_token FROM provider_connections WHERE user_id=$1 AND provider='plaid'",
      [request.userID]
    );
    for (const connection of connections.rows) {
      await plaid("/item/remove", { access_token: decryptToken(connection.encrypted_token) });
    }
    await pool.query("DELETE FROM provider_connections WHERE user_id=$1 AND provider='plaid'", [request.userID]);
    return {};
  });

  app.post("/v1/plaid/webhook", async (request, reply) => {
    const signedJWT = request.headers["plaid-verification"];
    if (typeof signedJWT !== "string" || !request.rawBody || !(await verifyWebhook(signedJWT, request.rawBody))) {
      return reply.code(401).send({ message: "Invalid Plaid webhook signature." });
    }
    const body = z.object({ webhook_type: z.string(), webhook_code: z.string() }).passthrough().parse(request.body);
    reply.code(200).send({});
    if (body.webhook_type === "TRANSACTIONS") {
      const { item_id } = z.object({ item_id: z.string() }).parse(body);
      const connection = await pool.query<{ id: string }>("SELECT id FROM provider_connections WHERE provider = 'plaid' AND provider_item_id = $1", [item_id]);
      for (const row of connection.rows) syncConnection(row.id).catch((error) => app.log.error({ err: error, connectionID: row.id }, "Plaid webhook sync failed"));
    } else if (body.webhook_type === "LINK" && body.webhook_code === "ITEM_ADD_RESULT") {
      const event = z.object({ link_token: z.string(), public_token: z.string() }).parse(body);
      void processHostedWebhook(event.link_token, [event.public_token]).catch((error) => app.log.error({ err: error }, "Hosted Link item processing failed"));
    } else if (body.webhook_type === "LINK" && body.webhook_code === "SESSION_FINISHED") {
      const event = z.object({
        link_token: z.string(), status: z.enum(["SUCCESS", "EXITED"]), public_tokens: z.array(z.string()).default([]),
        public_token: z.string().optional().nullable()
      }).parse(body);
      const publicTokens = [...event.public_tokens, ...(event.public_token ? [event.public_token] : [])];
      if (event.status === "SUCCESS" && publicTokens.length) {
        void processHostedWebhook(event.link_token, publicTokens).catch((error) => app.log.error({ err: error }, "Hosted Link completion failed"));
      } else if (event.status === "EXITED") {
        void pool.query("UPDATE plaid_link_sessions SET state='exited',updated_at=now() WHERE link_token_hash=$1 AND state='pending'", [hash(event.link_token)]);
      }
    }
  });
}

async function hostedSession(id: string, userID: string): Promise<(HostedLinkStatus & { encrypted_link_token: string }) | undefined> {
  const result = await pool.query<HostedLinkStatus & { encrypted_link_token: string }>(
    "SELECT state,connected_count,error_message,encrypted_link_token FROM plaid_link_sessions WHERE id=$1 AND user_id=$2", [id, userID]);
  return result.rows[0];
}

async function refreshHostedSession(id: string, userID: string): Promise<void> {
  const session = await hostedSession(id, userID);
  if (!session) return;
  const linkToken = decryptToken(session.encrypted_link_token);
  const details = await plaid<HostedLinkGetResponse>("/link/token/get", { link_token: linkToken });
  const linkSessions = details.link_sessions ?? [];
  const tokens = [...new Set(linkSessions.flatMap((linkSession) => [
    ...(linkSession.results?.item_add_results ?? []).map((result) => result.public_token),
    linkSession.on_success?.public_token
  ]).filter((token): token is string => Boolean(token)))];
  if (tokens.length) await processHostedTokens(id, tokens);
  else if (linkSessions.some((linkSession) => linkSession.finished_at)) {
    await pool.query("UPDATE plaid_link_sessions SET state='exited',updated_at=now() WHERE id=$1 AND user_id=$2 AND state='pending'", [id, userID]);
  }
}

async function processHostedWebhook(linkToken: string, publicTokens: string[]): Promise<void> {
  const session = await pool.query<{ id: string }>("SELECT id FROM plaid_link_sessions WHERE link_token_hash=$1", [hash(linkToken)]);
  if (session.rows[0]) await processHostedTokens(session.rows[0].id, publicTokens);
}

async function processHostedTokens(sessionID: string, publicTokens: string[]): Promise<void> {
  const alreadyConnected = await pool.query<{ count: number }>(
    "SELECT count(*)::integer AS count FROM provider_connections WHERE provider='plaid' AND metadata->>'hostedLinkSessionID'=$1", [sessionID]);
  if ((alreadyConnected.rows[0]?.count ?? 0) > 0) {
    await pool.query("UPDATE plaid_link_sessions SET state='connected',connected_count=$2,error_message=NULL,updated_at=now() WHERE id=$1", [sessionID, alreadyConnected.rows[0]!.count]);
    return;
  }
  const claimed = await pool.query<{ user_id: string }>(
    `UPDATE plaid_link_sessions SET state='processing',error_message=NULL,updated_at=now()
     WHERE id=$1 AND (state IN ('pending','failed') OR (state='processing' AND updated_at < now() - interval '2 minutes'))
     RETURNING user_id`, [sessionID]);
  const userID = claimed.rows[0]?.user_id;
  if (!userID) return;
  try {
    let connectedCount = 0;
    for (const publicToken of [...new Set(publicTokens)]) {
      await exchangePublicToken(userID, publicToken, sessionID);
      connectedCount += 1;
    }
    await pool.query("UPDATE plaid_link_sessions SET state='connected',connected_count=$2,error_message=NULL,updated_at=now() WHERE id=$1", [sessionID, connectedCount]);
  } catch (error) {
    const persisted = await pool.query<{ count: number }>(
      "SELECT count(*)::integer AS count FROM provider_connections WHERE provider='plaid' AND metadata->>'hostedLinkSessionID'=$1", [sessionID]);
    const count = persisted.rows[0]?.count ?? 0;
    if (count > 0) {
      await pool.query("UPDATE plaid_link_sessions SET state='connected',connected_count=$2,error_message=NULL,updated_at=now() WHERE id=$1", [sessionID, count]);
      return;
    }
    const message = error instanceof Error ? error.message.slice(0, 300) : "Plaid could not finish this connection.";
    await pool.query("UPDATE plaid_link_sessions SET state='failed',error_message=$2,updated_at=now() WHERE id=$1", [sessionID, message]);
    throw error;
  }
}

async function exchangePublicToken(userID: string, publicToken: string, hostedSessionID?: string): Promise<void> {
  const result = await plaid<{ access_token: string; item_id: string }>("/item/public_token/exchange", { public_token: publicToken });
  const metadata = hostedSessionID ? { hostedLinkSessionID: hostedSessionID } : {};
  const inserted = await pool.query<{ id: string }>(
    `INSERT INTO provider_connections (user_id,provider,provider_item_id,encrypted_token,metadata)
     VALUES ($1,'plaid',$2,$3,$4::jsonb)
     ON CONFLICT (user_id,provider,provider_item_id) DO UPDATE SET encrypted_token=EXCLUDED.encrypted_token,
       metadata=provider_connections.metadata || EXCLUDED.metadata,status='active',updated_at=now()
     RETURNING id`, [userID, result.item_id, encryptToken(result.access_token), JSON.stringify(metadata)]);
  await hydrateAccounts(userID, inserted.rows[0]!.id, result.access_token);
  await syncConnection(inserted.rows[0]!.id);
}

async function verifyWebhook(signedJWT: string, rawBody: Buffer): Promise<boolean> {
  try {
    const header = decodeProtectedHeader(signedJWT);
    if (header.alg !== "ES256" || !header.kid) return false;
    let jwk = verificationKeys.get(header.kid);
    if (!jwk) {
      const response = await plaid<{ key: JWK & { expired_at?: number | null } }>("/webhook_verification_key/get", { key_id: header.kid });
      if (response.key.expired_at && response.key.expired_at * 1000 <= Date.now()) return false;
      jwk = response.key; verificationKeys.set(header.kid, jwk);
    }
    const key = await importJWK(jwk, "ES256");
    const { payload } = await jwtVerify(signedJWT, key, { algorithms: ["ES256"], maxTokenAge: "5 min" });
    if (typeof payload.request_body_sha256 !== "string") return false;
    const actual = Buffer.from(createHash("sha256").update(rawBody).digest("hex"));
    const expected = Buffer.from(payload.request_body_sha256);
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

async function hydrateAccounts(userID: string, connectionID: string, accessToken: string): Promise<void> {
  const result = await plaid<{ accounts: { account_id: string; name: string; official_name?: string | null; mask?: string | null; balances?: { iso_currency_code?: string | null } }[] }>("/accounts/get", { access_token: accessToken });
  for (const account of result.accounts) {
    await pool.query(
      `INSERT INTO accounts(user_id,connection_id,external_id,name,mask,currency_code) VALUES($1,$2,$3,$4,$5,$6)
       ON CONFLICT(user_id,external_id) DO UPDATE SET connection_id=EXCLUDED.connection_id,name=EXCLUDED.name,mask=EXCLUDED.mask,currency_code=EXCLUDED.currency_code`,
      [userID, connectionID, account.account_id, account.official_name ?? account.name, account.mask ?? null, account.balances?.iso_currency_code ?? "USD"]);
  }
}

export async function syncConnection(connectionID: string, replayMetadata = false): Promise<void> {
  const connectionResult = await pool.query<{ id: string; user_id: string; encrypted_token: string; sync_cursor: string | null }>(
    "SELECT id, user_id, encrypted_token, sync_cursor FROM provider_connections WHERE id = $1 AND status = 'active'", [connectionID]);
  const connection = connectionResult.rows[0];
  if (!connection) return;
  const accessToken = decryptToken(connection.encrypted_token), originalCursor = replayMetadata ? null : connection.sync_cursor;
  for (let restart = 0; restart < 3; restart++) {
    let cursor = originalCursor ?? undefined;
    const pages: SyncResponse[] = [];
    try {
      do {
        const page = await plaid<SyncResponse>("/transactions/sync", { access_token: accessToken, ...(cursor ? { cursor } : {}), count: 500, options: { include_original_description: true, personal_finance_category_version: "v2" } });
        pages.push(page); cursor = page.next_cursor;
      } while (pages.at(-1)!.has_more);
      await applyPages(connection, pages, cursor!);
      return;
    } catch (error) {
      const code = (error as { data?: { error_code?: string } }).data?.error_code;
      if (code !== "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" || restart === 2) throw error;
    }
  }
}

async function applyPages(connection: { id: string; user_id: string }, pages: SyncResponse[], cursor: string): Promise<void> {
  await transaction(async (client) => {
    for (const page of pages) {
      for (const removed of page.removed) await client.query("DELETE FROM transactions WHERE user_id = $1 AND source = 'plaid' AND external_id = $2", [connection.user_id, removed.transaction_id]);
      for (const item of [...page.added, ...page.modified]) {
        if (item.pending_transaction_id) await client.query("DELETE FROM transactions WHERE user_id=$1 AND source='plaid' AND external_id=$2", [connection.user_id, item.pending_transaction_id]);
        const account = await client.query<{ id: string; name: string; mask: string | null }>(
          `INSERT INTO accounts (user_id, connection_id, external_id, name, currency_code) VALUES ($1, $2, $3, $3, $4)
           ON CONFLICT (user_id, external_id) DO UPDATE SET connection_id = EXCLUDED.connection_id RETURNING id, name, mask`,
          [connection.user_id, connection.id, item.account_id, item.iso_currency_code ?? "USD"]);
        const accountRow = account.rows[0]!;
        const merchant = item.merchant_name ?? item.name;
        const minor = Math.round(Math.abs(item.amount) * 100);
        const fingerprint = createHash("sha256").update(`${accountRow.id}|${item.date}|${minor}|${normalize(merchant)}`).digest("hex");
        const importedMatch = await client.query<{ id: string }>(
          "SELECT id FROM transactions WHERE user_id=$1 AND source='csv' AND transaction_date=$2 AND amount_minor=$3 AND regexp_replace(lower(merchant),'[^a-z0-9]','','g')=$4 LIMIT 1",
          [connection.user_id, item.date, minor, normalize(merchant)]);
        if (importedMatch.rows[0]) {
          await client.query(
            `UPDATE transactions SET account_id=$1,external_id=$2,source='plaid',merchant=$3,original_description=$4,
             currency_code=$5,pending=$6,review_state=CASE WHEN $6 THEN 'pending' ELSE review_state END,
             fingerprint=$7,raw_category=$8,updated_at=now() WHERE id=$9`,
            [accountRow.id, item.transaction_id, merchant, item.original_description ?? item.name, item.iso_currency_code ?? "USD",
             item.pending, fingerprint, item.personal_finance_category?.primary ?? null, importedMatch.rows[0].id]);
          await updateTransactionMetadata(client, connection.user_id, item);
          continue;
        }
        await client.query(
          `INSERT INTO transactions (user_id, account_id, external_id, source, merchant, original_description, transaction_date, amount_minor, currency_code, pending, review_state, fingerprint, raw_category)
           VALUES ($1,$2,$3,'plaid',$4,$5,$6,$7,$8,$9,$10,$11,$12)
           ON CONFLICT (user_id, source, external_id) DO UPDATE SET merchant=EXCLUDED.merchant, original_description=EXCLUDED.original_description,
             transaction_date=EXCLUDED.transaction_date, amount_minor=EXCLUDED.amount_minor, currency_code=EXCLUDED.currency_code,
             pending=EXCLUDED.pending, fingerprint=EXCLUDED.fingerprint, raw_category=EXCLUDED.raw_category,
             review_state=CASE WHEN transactions.review_state='pending' AND NOT EXCLUDED.pending THEN 'needsReview' ELSE transactions.review_state END, updated_at=now()`,
          [connection.user_id, accountRow.id, item.transaction_id, merchant, item.original_description ?? item.name, item.date, minor,
           item.iso_currency_code ?? "USD", item.pending, item.pending ? "pending" : "needsReview", fingerprint, item.personal_finance_category?.primary ?? null]);
        await updateTransactionMetadata(client, connection.user_id, item);
      }
    }
    await client.query("UPDATE provider_connections SET sync_cursor=$1, updated_at=now() WHERE id=$2", [cursor, connection.id]);
  });
}

function normalize(value: string): string { return value.normalize("NFKD").replace(/[^a-zA-Z0-9]/g, "").toLowerCase(); }

async function updateTransactionMetadata(client: PoolClient, userID: string, item: PlaidTransaction): Promise<void> {
  await client.query(
    `UPDATE transactions SET category_detail=$1,city=$2,region=$3,country=$4,payment_channel=$5,is_credit=$6
     WHERE user_id=$7 AND source='plaid' AND external_id=$8`,
    [item.personal_finance_category?.detailed ?? null, item.location?.city ?? null, item.location?.region ?? null,
     item.location?.country ?? null, item.payment_channel ?? null, item.amount < 0, userID, item.transaction_id]);
}
