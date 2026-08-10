import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireUser } from "./auth.js";
import { pool, transaction } from "./db.js";

const importedTransaction = z.object({
  id: z.string().uuid(), accountName: z.string().min(1), accountMask: z.string().default(""), merchant: z.string().min(1),
  originalDescription: z.string().default(""), date: z.string().datetime(), amountMinor: z.number().int().positive(),
  currencyCode: z.string().length(3), fingerprint: z.string().min(1)
});

export async function transactionRoutes(app: FastifyInstance): Promise<void> {
  app.get("/v1/transactions", { preHandler: requireUser }, async (request) => {
    const query = z.object({ state: z.string().optional(), account: z.string().uuid().optional(), before: z.string().optional(), limit: z.coerce.number().int().min(1).max(500).default(200) }).parse(request.query);
    const values: unknown[] = [request.userID]; let where = "t.user_id=$1";
    if (query.state) { values.push(query.state); where += ` AND t.review_state=$${values.length}`; }
    if (query.account) { values.push(query.account); where += ` AND t.account_id=$${values.length}`; }
    if (query.before) { values.push(query.before); where += ` AND t.transaction_date<$${values.length}`; }
    values.push(query.limit);
    const result = await pool.query(
      `SELECT t.id,t.external_id AS "externalID",t.source,a.name AS "accountName",COALESCE(a.mask,'') AS "accountMask",
       t.merchant,COALESCE(t.original_description,'') AS "originalDescription",t.transaction_date AS date,
       t.amount_minor::integer AS "amountMinor",t.currency_code AS "currencyCode",t.review_state AS state,
       t.raw_category AS category,t.fingerprint,t.possible_duplicate_id AS "possibleDuplicateID"
       FROM transactions t LEFT JOIN accounts a ON a.id=t.account_id WHERE ${where}
       ORDER BY t.transaction_date DESC LIMIT $${values.length}`, values);
    return { transactions: result.rows };
  });

  app.post("/v1/transactions/import", { preHandler: requireUser }, async (request) => {
    const body = z.object({ idempotencyKey: z.string().min(8), transactions: z.array(importedTransaction).max(10_000) }).parse(request.body);
    return transaction(async (client) => {
      const existingKey = await client.query<{ response: { inserted: number; duplicates: number } }>("SELECT response FROM idempotency_keys WHERE user_id=$1 AND idempotency_key=$2", [request.userID, body.idempotencyKey]);
      if (existingKey.rows[0]?.response) return existingKey.rows[0].response;
      let inserted = 0, duplicates = 0;
      for (const item of body.transactions) {
        const found = await client.query<{ id: string }>("SELECT id FROM accounts WHERE user_id=$1 AND name=$2 AND COALESCE(mask,'')=$3 LIMIT 1", [request.userID, item.accountName, item.accountMask]);
        let accountID = found.rows[0]?.id;
        if (!accountID) {
          const created = await client.query<{ id: string }>("INSERT INTO accounts(user_id,name,mask,currency_code) VALUES($1,$2,$3,$4) RETURNING id", [request.userID, item.accountName, item.accountMask, item.currencyCode]);
          accountID = created.rows[0]!.id;
        }
        const result = await client.query(
          `INSERT INTO transactions(id,user_id,account_id,source,merchant,original_description,transaction_date,amount_minor,currency_code,pending,review_state,fingerprint)
           VALUES($1,$2,$3,'csv',$4,$5,$6,$7,$8,false,'needsReview',$9)
           ON CONFLICT(user_id,fingerprint) DO NOTHING RETURNING id`,
          [item.id, request.userID, accountID, item.merchant, item.originalDescription, item.date.slice(0,10), item.amountMinor, item.currencyCode, item.fingerprint]);
        result.rowCount ? inserted++ : duplicates++;
      }
      const response = { inserted, duplicates };
      await client.query("INSERT INTO idempotency_keys(user_id,idempotency_key,status_code,response) VALUES($1,$2,200,$3) ON CONFLICT DO NOTHING", [request.userID, body.idempotencyKey, response]);
      return response;
    });
  });

  app.patch("/v1/transactions/:id/review", { preHandler: requireUser }, async (request, reply) => {
    const params = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z.object({ state: z.enum(["needsReview", "personal", "sharedDraft", "queued"]) }).parse(request.body);
    const result = await pool.query("UPDATE transactions SET review_state=$1,updated_at=now() WHERE id=$2 AND user_id=$3 RETURNING id", [body.state, params.id, request.userID]);
    if (!result.rowCount) return reply.code(404).send({ message: "Transaction not found." });
    return {};
  });

  app.get("/v1/coverage", { preHandler: requireUser }, async (request) => {
    const result = await pool.query(
      `SELECT a.id,a.name,a.mask,date_trunc('month',t.transaction_date)::date AS month,
       bool_or(t.source='plaid') AS plaid,bool_or(t.source='csv') AS csv,count(*)::integer AS count
       FROM accounts a LEFT JOIN transactions t ON t.account_id=a.id
       WHERE a.user_id=$1 GROUP BY a.id,a.name,a.mask,date_trunc('month',t.transaction_date) ORDER BY month`, [request.userID]);
    return { months: result.rows };
  });

  app.get("/v1/connections", { preHandler: requireUser }, async (request) => {
    const [providers, accounts] = await Promise.all([
      pool.query<{ provider: "plaid" | "splitwise"; count: number }>(
        `SELECT provider,count(*)::integer AS count FROM provider_connections
         WHERE user_id=$1 AND status='active' GROUP BY provider`, [request.userID]),
      pool.query(
        `SELECT a.id,a.name,COALESCE(a.mask,'') AS mask,a.currency_code AS "currencyCode",
         (pc.provider='plaid' AND pc.status='active') AS connected,
         COALESCE(bool_or(t.source='plaid'),false) AS "hasPlaidHistory",
         COALESCE(bool_or(t.source='csv'),false) AS "hasStatementHistory",
         count(t.id)::integer AS "transactionCount",max(t.transaction_date)::date AS "lastTransactionDate"
         FROM accounts a
         LEFT JOIN provider_connections pc ON pc.id=a.connection_id
         LEFT JOIN transactions t ON t.account_id=a.id
         WHERE a.user_id=$1
         GROUP BY a.id,a.name,a.mask,a.currency_code,pc.provider,pc.status
         ORDER BY a.name,a.mask`, [request.userID])
    ]);
    const counts = new Map(providers.rows.map((row) => [row.provider, row.count]));
    return {
      plaidConnected: (counts.get("plaid") ?? 0) > 0,
      plaidConnectionCount: counts.get("plaid") ?? 0,
      splitwiseConnected: (counts.get("splitwise") ?? 0) > 0,
      accounts: accounts.rows
    };
  });
}

export function canonicalFingerprint(account: string, date: string, amountMinor: number, merchant: string): string {
  const normalized = merchant.normalize("NFKD").replace(/[^a-zA-Z0-9]/g, "").toLowerCase();
  return createHash("sha256").update(`${account}|${date.slice(0,10)}|${amountMinor}|${normalized}`).digest("hex");
}
