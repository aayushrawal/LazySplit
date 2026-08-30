import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import { pool } from "./db.js";
import { friendRoutes } from "./friends.js";
import { hash } from "./crypto.js";

test("friends are opt-in, user-scoped, and removal preserves existing preferences", async (t) => {
  const directory = [{ id: 1, first_name: "Alex" }, { id: 2, first_name: "Sam" }];
  type Preference = { splitwise_user_id: string; alias: string | null; sort_order: number | null; selected: boolean };
  const preferences = new Map<string, Preference>([
    ["owner:1", { splitwise_user_id: "1", alias: "Roommate", sort_order: 0, selected: false }]
  ]);
  let connected = true;
  // Fake database only: these route tests never touch real account records.
  const query = async (sql: string, values: unknown[] = []) => {
    if (["BEGIN", "COMMIT", "ROLLBACK"].includes(sql)) return { rows: [], rowCount: 0 };
    if (sql.includes("FROM sessions")) return { rows: [{ user_id: values[0] === hash("other") ? "other" : "owner" }] };
    const user = String(values[0]);
    if (sql.includes("SELECT friends FROM splitwise_cache")) return { rows: connected ? [{ friends: directory }] : [] };
    if (sql.includes("SELECT splitwise_user_id,alias")) return { rows: [...preferences].filter(([key]) => key.startsWith(`${user}:`)).map(([, value]) => value) };
    if (sql.includes("FROM split_drafts")) return { rows: [] };
    if (sql.includes("INSERT INTO friend_preferences(user_id,splitwise_user_id,selected)")) {
      const key = `${user}:${values[1]}`;
      preferences.set(key, { ...(preferences.get(key) ?? { splitwise_user_id: String(values[1]), alias: null, sort_order: null }), selected: true });
      return { rows: [], rowCount: 1 };
    }
    if (sql.includes("UPDATE friend_preferences SET selected=false")) {
      const preference = preferences.get(`${user}:${values[1]}`);
      if (preference) preference.selected = false;
      return { rows: [], rowCount: preference ? 1 : 0 };
    }
    throw new Error(`Unexpected SQL in test: ${sql}`);
  };
  t.mock.method(pool, "query", query);
  t.mock.method(pool, "connect", async () => ({ query, release() {} }));
  const app = Fastify();
  await app.register(friendRoutes);
  t.after(async () => { await app.close(); t.mock.restoreAll(); });
  const headers = { authorization: "Bearer owner" };
  const getFriends = async (url = "/v1/friends", auth = headers) => (await app.inject({ method: "GET", url, headers: auth })).json().friends;

  assert.equal((await app.inject({ method: "GET", url: "/v1/friends" })).statusCode, 401);
  assert.deepEqual(await getFriends(), []); // Existing rename/order is not consent to add.
  assert.equal((await getFriends("/v1/friends?available=true")).length, 2);
  assert.deepEqual(await getFriends(), []); // Opening the picker has no side effects.

  assert.equal((await app.inject({ method: "POST", url: "/v1/friends", headers, payload: { friendIDs: [1, 99] } })).statusCode, 422);
  assert.deepEqual(await getFriends(), []); // Invalid batch adds nobody.
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.equal((await app.inject({ method: "POST", url: "/v1/friends", headers, payload: { friendIDs: [1, 1] } })).statusCode, 200);
  }
  assert.equal((await getFriends()).length, 1); // Retries and duplicate IDs are safe.
  assert.equal((await getFriends())[0].alias, "Roommate");
  assert.deepEqual(await getFriends("/v1/friends", { authorization: "Bearer other" }), []);
  directory.push({ id: 3, first_name: "New Splitwise friend" });
  assert.equal((await getFriends("/v1/friends?available=true")).length, 3);
  assert.equal((await getFriends()).length, 1); // Cache changes do not auto-add friends.

  assert.equal((await app.inject({ method: "DELETE", url: "/v1/friends/1", headers: { authorization: "Bearer other" } })).statusCode, 200);
  assert.equal((await getFriends()).length, 1); // Another user cannot remove my friend.
  assert.equal((await app.inject({ method: "DELETE", url: "/v1/friends/1", headers })).statusCode, 200);
  assert.deepEqual(await getFriends(), []);
  assert.equal(preferences.get("owner:1")?.alias, "Roommate");
  assert.equal(preferences.get("owner:1")?.sort_order, 0);
  await app.inject({ method: "POST", url: "/v1/friends", headers, payload: { friendIDs: [1] } });
  assert.equal((await getFriends())[0].alias, "Roommate");

  connected = false;
  assert.deepEqual(await getFriends(), []);
  assert.equal((await app.inject({ method: "GET", url: "/v1/friends?available=true", headers })).statusCode, 409);
});
