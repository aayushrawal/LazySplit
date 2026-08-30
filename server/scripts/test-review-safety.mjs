// Run after building/migrating: docker compose exec -T api node --input-type=module < scripts/test-review-safety.mjs
// Uses only a temporary synthetic user. No Splitwise or Plaid requests are made.
import assert from "node:assert/strict";
import { randomUUID, randomBytes, createHash } from "node:crypto";
import Fastify from "fastify";
import { pool } from "./dist/db.js";
import { transactionRoutes } from "./dist/transactions.js";
import { splitwiseRoutes } from "./dist/splitwise.js";

const app = Fastify({ logger: false });
await app.register(transactionRoutes);
await app.register(splitwiseRoutes);
const userID = randomUUID(), transactionID = randomUUID();
const token = randomBytes(32).toString("hex");
const headers = { authorization: `Bearer ${token}` };
try {
  await pool.query("INSERT INTO users(id) VALUES($1)", [userID]);
  await pool.query("INSERT INTO sessions(token_hash,user_id,expires_at) VALUES($1,$2,now()+interval '5 minutes')",
    [createHash("sha256").update(token).digest("hex"), userID]);
  await pool.query(`INSERT INTO transactions(id,user_id,source,merchant,transaction_date,amount_minor,currency_code,fingerprint,city,raw_category)
    VALUES($1,$2,'plaid','Synthetic Cafe','2026-08-01',1200,'USD',$3,'Test City','FOOD_AND_DRINK')`,
    [transactionID, userID, randomUUID()]);
  const review = (state, id = transactionID) => app.inject({ method: "PATCH", url: `/v1/transactions/${id}/review`, headers, payload: { state } });
  const publish = () => app.inject({ method: "POST", url: "/v1/splitwise/publish", headers: { ...headers, "idempotency-key": randomUUID() }, payload: {
    transactionID, draftID: randomUUID(), merchant: "Synthetic Cafe", date: "2026-08-01T00:00:00Z",
    amountMinor: 1200, currencyCode: "USD", participants: [{ userID: 1, owedMinor: 1200, paidMinor: 1200 }]
  } });
  assert.equal((await review("personal")).statusCode, 200);
  const inbox = await app.inject({ method: "GET", url: "/v1/transactions", headers });
  assert.equal(inbox.statusCode, 200);
  assert.equal(inbox.json().transactions.length, 1, "Personal remains in the default inbox response");
  assert.equal(inbox.json().transactions[0].state, "personal");
  assert.equal(inbox.json().transactions[0].city, "Test City");
  const blocked = await publish();
  assert.equal(blocked.statusCode, 409);
  assert.match(blocked.json().message, /Personal transactions/);
  assert.equal((await review("needsReview")).statusCode, 200);
  assert.equal((await review("personal", randomUUID())).statusCode, 404);
  await pool.query("UPDATE transactions SET pending=true WHERE id=$1 AND user_id=$2", [transactionID, userID]);
  assert.equal((await review("personal")).statusCode, 409);
  assert.equal((await publish()).statusCode, 409);
  await pool.query("UPDATE transactions SET pending=false,is_credit=true WHERE id=$1 AND user_id=$2", [transactionID, userID]);
  assert.equal((await publish()).statusCode, 409);
  assert.equal((await pool.query("SELECT count(*)::int AS count FROM split_drafts WHERE user_id=$1", [userID])).rows[0].count, 0);
  console.log("PASS: personal visibility, review/restore, metadata, missing records, pending/refund export protection; no expenses created.");
} finally {
  await pool.query("DELETE FROM users WHERE id=$1", [userID]);
  await app.close();
  await pool.end();
}
