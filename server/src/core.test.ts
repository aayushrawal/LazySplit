import assert from "node:assert/strict";
import test from "node:test";
import { decryptToken, encryptToken } from "./crypto.js";
import { canonicalFingerprint } from "./transactions.js";
import { parseJSONBody } from "./http.js";

test("provider tokens round-trip through authenticated encryption", () => {
  const encrypted = encryptToken("provider-secret");
  assert.notEqual(encrypted, "provider-secret");
  assert.equal(decryptToken(encrypted), "provider-secret");
});

test("fingerprints normalize merchant punctuation and accents", () => {
  assert.equal(canonicalFingerprint("card", "2026-08-01", 2450, "Café, North"), canonicalFingerprint("card", "2026-08-01T12:00:00Z", 2450, "Cafe North"));
});

test("JSON parser accepts bodyless authenticated POST and DELETE requests", () => {
  assert.deepEqual(parseJSONBody(Buffer.alloc(0)), {});
  assert.deepEqual(parseJSONBody(Buffer.from('{"ok":true}')), { ok: true });
});
