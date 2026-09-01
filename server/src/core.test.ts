import assert from "node:assert/strict";
import test from "node:test";
import { decryptToken, encryptToken } from "./crypto.js";
import { canonicalFingerprint, importedTransactionSchema, manualAccountSchema } from "./transactions.js";
import { parseJSONBody } from "./http.js";

test("provider tokens round-trip through authenticated encryption", () => {
  const encrypted = encryptToken("provider-secret");
  assert.notEqual(encrypted, "provider-secret");
  assert.equal(decryptToken(encrypted), "provider-secret");
});

test("fingerprints normalize merchant punctuation and accents", () => {
  assert.equal(canonicalFingerprint("card", "2026-08-01", 2450, "Café, North"), canonicalFingerprint("card", "2026-08-01T12:00:00Z", 2450, "Cafe North"));
});

test("manual accounts accept only last four digits and supported currencies", () => {
  const id = "11111111-1111-4111-8111-111111111111";
  assert.deepEqual(manualAccountSchema.parse({ id, name: " Apple Card ", mask: "4242", currencyCode: "USD" }), { id, name: "Apple Card", mask: "4242", currencyCode: "USD" });
  assert.throws(() => manualAccountSchema.parse({ id, name: "Apple Card", mask: "1234567890123456", currencyCode: "USD" }));
  assert.throws(() => manualAccountSchema.parse({ id, name: "Apple Card", mask: "4242", currencyCode: "BTC" }));
});

test("statement import can be scoped to an owned account ID", () => {
  const value = importedTransactionSchema.parse({ id: "22222222-2222-4222-8222-222222222222", accountID: "11111111-1111-4111-8111-111111111111", accountName: "Apple Card", accountMask: "4242", merchant: "Coffee", originalDescription: "Coffee", date: "2026-08-31T00:00:00.000Z", amountMinor: 1234, currencyCode: "USD", fingerprint: "preview", isCredit: false });
  assert.equal(value.accountID, "11111111-1111-4111-8111-111111111111");
  assert.throws(() => importedTransactionSchema.parse({ ...value, accountID: "not-a-uuid" }));
  assert.notEqual(canonicalFingerprint(value.accountID!, value.date, value.amountMinor, value.merchant), canonicalFingerprint("33333333-3333-4333-8333-333333333333", value.date, value.amountMinor, value.merchant));
  assert.equal(canonicalFingerprint(value.accountID!.toUpperCase(), value.date, value.amountMinor, value.merchant), canonicalFingerprint(value.accountID!, value.date, value.amountMinor, value.merchant));
});

test("JSON parser accepts bodyless authenticated POST and DELETE requests", () => {
  assert.deepEqual(parseJSONBody(Buffer.alloc(0)), {});
  assert.deepEqual(parseJSONBody(Buffer.from('{"ok":true}')), { ok: true });
});
