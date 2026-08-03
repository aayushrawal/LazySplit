import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { config } from "./config.js";
import { decryptToken, encryptToken } from "./crypto.js";
import { pool, transaction } from "./db.js";
import { requireUser } from "./auth.js";

const plaidBase = `https://${config.PLAID_ENV}.plaid.com`;

type PlaidTransaction = {
  transaction_id: string; account_id: string; amount: number; iso_currency_code: string | null;
  date: string; merchant_name: string | null; name: string; original_description?: string | null;
  pending: boolean; pending_transaction_id?: string | null;
  personal_finance_category?: { primary: string; detailed: string } | null;
};
type SyncResponse = { added: PlaidTransaction[]; modified: PlaidTransaction[]; removed: { transaction_id: string }[]; next_cursor: string; has_more: boolean; error_code?: string };

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

  app.post("/v1/plaid/exchange", { preHandler: requireUser }, async (request) => {
    const body = z.object({ publicToken: z.string().min(1) }).parse(request.body);
    const result = await plaid<{ access_token: string; item_id: string }>("/item/public_token/exchange", { public_token: body.publicToken });
    const inserted = await pool.query<{ id: string }>(
      `INSERT INTO provider_connections (user_id, provider, provider_item_id, encrypted_token)
       VALUES ($1, 'plaid', $2, $3)
       ON CONFLICT (user_id, provider, provider_item_id) DO UPDATE SET encrypted_token = EXCLUDED.encrypted_token, status = 'active', updated_at = now()
       RETURNING id`, [request.userID, result.item_id, encryptToken(result.access_token)]);
    await hydrateAccounts(request.userID, inserted.rows[0]!.id, result.access_token);
    await syncConnection(inserted.rows[0]!.id);
    return {};
  });

  app.post("/v1/plaid/webhook", async (request, reply) => {
    const body = z.object({ webhook_type: z.string(), webhook_code: z.string(), item_id: z.string() }).passthrough().parse(request.body);
    reply.code(200).send({});
    if (body.webhook_type === "TRANSACTIONS") {
      const connection = await pool.query<{ id: string }>("SELECT id FROM provider_connections WHERE provider = 'plaid' AND provider_item_id = $1", [body.item_id]);
      for (const row of connection.rows) syncConnection(row.id).catch((error) => app.log.error({ err: error, connectionID: row.id }, "Plaid webhook sync failed"));
    }
  });
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

export async function syncConnection(connectionID: string): Promise<void> {
  const connectionResult = await pool.query<{ id: string; user_id: string; encrypted_token: string; sync_cursor: string | null }>(
    "SELECT id, user_id, encrypted_token, sync_cursor FROM provider_connections WHERE id = $1 AND status = 'active'", [connectionID]);
  const connection = connectionResult.rows[0];
  if (!connection) return;
  const accessToken = decryptToken(connection.encrypted_token), originalCursor = connection.sync_cursor;
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
          continue;
        }
        await client.query(
          `INSERT INTO transactions (user_id, account_id, external_id, source, merchant, original_description, transaction_date, amount_minor, currency_code, pending, review_state, fingerprint, raw_category)
           VALUES ($1,$2,$3,'plaid',$4,$5,$6,$7,$8,$9,$10,$11,$12)
           ON CONFLICT (user_id, source, external_id) DO UPDATE SET merchant=EXCLUDED.merchant, original_description=EXCLUDED.original_description,
             transaction_date=EXCLUDED.transaction_date, amount_minor=EXCLUDED.amount_minor, currency_code=EXCLUDED.currency_code,
             pending=EXCLUDED.pending, fingerprint=EXCLUDED.fingerprint, raw_category=EXCLUDED.raw_category, updated_at=now()`,
          [connection.user_id, accountRow.id, item.transaction_id, merchant, item.original_description ?? item.name, item.date, minor,
           item.iso_currency_code ?? "USD", item.pending, item.pending ? "pending" : "needsReview", fingerprint, item.personal_finance_category?.primary ?? null]);
      }
    }
    await client.query("UPDATE provider_connections SET sync_cursor=$1, updated_at=now() WHERE id=$2", [cursor, connection.id]);
  });
}

function normalize(value: string): string { return value.normalize("NFKD").replace(/[^a-zA-Z0-9]/g, "").toLowerCase(); }
