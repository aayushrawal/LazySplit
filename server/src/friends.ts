import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireUser } from "./auth.js";
import { pool, transaction } from "./db.js";

type CachedFriend = { id: number; first_name?: string | null; last_name?: string | null; email?: string | null };

export async function friendRoutes(app: FastifyInstance): Promise<void> {
  app.get("/v1/friends", { preHandler: requireUser }, async (request, reply) => {
    const cache = await pool.query<{ friends: CachedFriend[] }>("SELECT friends FROM splitwise_cache WHERE user_id=$1", [request.userID]);
    if (!cache.rows[0]) return reply.code(409).send({ message: "Connect Splitwise to manage friends." });
    const [preferences, interactions] = await Promise.all([
      pool.query<{ splitwise_user_id: string; alias: string | null; sort_order: number | null }>(
        "SELECT splitwise_user_id,alias,sort_order FROM friend_preferences WHERE user_id=$1", [request.userID]),
      pool.query<{ splitwise_user_id: string; interaction_count: number }>(
        `SELECT (participant->>'userID')::bigint AS splitwise_user_id,count(*)::integer AS interaction_count
         FROM split_drafts d CROSS JOIN LATERAL jsonb_array_elements(COALESCE(d.payload->'participants','[]'::jsonb)) participant
         WHERE d.user_id=$1 AND d.state='published' AND participant ? 'userID'
         GROUP BY (participant->>'userID')::bigint`, [request.userID])
    ]);
    const preferenceByID = new Map(preferences.rows.map((row) => [Number(row.splitwise_user_id), row]));
    const interactionsByID = new Map(interactions.rows.map((row) => [Number(row.splitwise_user_id), row.interaction_count]));
    const friends = cache.rows[0].friends.map((friend) => {
      const preference = preferenceByID.get(friend.id);
      return {
        id: friend.id,
        firstName: friend.first_name ?? friend.email ?? "Friend",
        lastName: friend.last_name ?? null,
        alias: preference?.alias ?? null,
        sortOrder: preference?.sort_order ?? null,
        interactionCount: interactionsByID.get(friend.id) ?? 0
      };
    });
    return { friends };
  });

  app.patch("/v1/friends/:id", { preHandler: requireUser }, async (request) => {
    const { id } = z.object({ id: z.coerce.number().int().positive() }).parse(request.params);
    const { alias = null } = z.object({ alias: z.string().trim().min(1).max(80).nullable().optional() }).parse(request.body);
    await pool.query(
      `INSERT INTO friend_preferences(user_id,splitwise_user_id,alias) VALUES($1,$2,$3)
       ON CONFLICT(user_id,splitwise_user_id) DO UPDATE SET alias=EXCLUDED.alias,updated_at=now()`,
      [request.userID, id, alias]);
    return {};
  });

  app.put("/v1/friends/order", { preHandler: requireUser }, async (request) => {
    const { friendIDs } = z.object({ friendIDs: z.array(z.number().int().positive()).max(500) }).parse(request.body);
    await transaction(async (client) => {
      for (const [index, friendID] of friendIDs.entries()) {
        await client.query(
          `INSERT INTO friend_preferences(user_id,splitwise_user_id,sort_order) VALUES($1,$2,$3)
           ON CONFLICT(user_id,splitwise_user_id) DO UPDATE SET sort_order=EXCLUDED.sort_order,updated_at=now()`,
          [request.userID, friendID, index]);
      }
    });
    return {};
  });

  app.get("/v1/friend-groups", { preHandler: requireUser }, async (request) => {
    const [groups, members] = await Promise.all([
      pool.query<{ id: string; name: string; createdAt: Date }>(
        `SELECT id,name,created_at AS "createdAt" FROM friend_groups WHERE user_id=$1 ORDER BY name`, [request.userID]),
      pool.query<{ group_id: string; splitwise_user_id: string }>(
        `SELECT m.group_id,m.splitwise_user_id FROM friend_group_members m
         JOIN friend_groups g ON g.id=m.group_id WHERE g.user_id=$1 ORDER BY m.position`, [request.userID])
    ]);
    return { groups: groups.rows.map((group) => ({ ...group, friendIDs: members.rows.filter((member) => member.group_id === group.id).map((member) => Number(member.splitwise_user_id)) })) };
  });

  app.post("/v1/friend-groups", { preHandler: requireUser }, async (request) => {
    const body = groupBody.parse(request.body);
    return transaction(async (client) => {
      const created = await client.query<{ id: string; createdAt: Date }>(
        `INSERT INTO friend_groups(user_id,name) VALUES($1,$2) RETURNING id,created_at AS "createdAt"`, [request.userID, body.name]);
      const group = created.rows[0]!;
      for (const [index, friendID] of body.friendIDs.entries()) {
        await client.query("INSERT INTO friend_group_members(group_id,splitwise_user_id,position) VALUES($1,$2,$3)", [group.id, friendID, index]);
      }
      return { group: { id: group.id, name: body.name, friendIDs: body.friendIDs, createdAt: group.createdAt } };
    });
  });

  app.put("/v1/friend-groups/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params), body = groupBody.parse(request.body);
    return transaction(async (client) => {
      const updated = await client.query("UPDATE friend_groups SET name=$1,updated_at=now() WHERE id=$2 AND user_id=$3 RETURNING id", [body.name, id, request.userID]);
      if (!updated.rowCount) return reply.code(404).send({ message: "Group not found." });
      await client.query("DELETE FROM friend_group_members WHERE group_id=$1", [id]);
      for (const [index, friendID] of body.friendIDs.entries()) {
        await client.query("INSERT INTO friend_group_members(group_id,splitwise_user_id,position) VALUES($1,$2,$3)", [id, friendID, index]);
      }
      return {};
    });
  });

  app.delete("/v1/friend-groups/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const deleted = await pool.query("DELETE FROM friend_groups WHERE id=$1 AND user_id=$2 RETURNING id", [id, request.userID]);
    if (!deleted.rowCount) return reply.code(404).send({ message: "Group not found." });
    return {};
  });
}

const groupBody = z.object({ name: z.string().trim().min(1).max(80), friendIDs: z.array(z.number().int().positive()).max(100) });
