import { randomBytes } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { config } from "./config.js";
import { hash } from "./crypto.js";
import { pool } from "./db.js";

const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const appleBody = z.object({ identityToken: z.string().min(1), authorizationCode: z.string().optional().nullable() });

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post("/v1/auth/apple", async (request, reply) => {
    const body = appleBody.parse(request.body);
    const { payload } = await jwtVerify(body.identityToken, appleKeys, { issuer: "https://appleid.apple.com", audience: config.APPLE_CLIENT_ID });
    if (!payload.sub) return reply.code(401).send({ message: "Apple identity is missing a subject." });
    const user = await pool.query<{ id: string }>(
      `INSERT INTO users (apple_subject, email) VALUES ($1, $2)
       ON CONFLICT (apple_subject) DO UPDATE SET email = COALESCE(users.email, EXCLUDED.email)
       RETURNING id`, [payload.sub, typeof payload.email === "string" ? payload.email : null]);
    const userID = user.rows[0]!.id;
    const token = randomBytes(32).toString("base64url");
    await pool.query("INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, now() + interval '30 days')", [hash(token), userID]);
    return { token };
  });

  app.delete("/v1/account", { preHandler: requireUser }, async (request) => {
    await pool.query("UPDATE users SET deleted_at = now() WHERE id = $1", [request.userID]);
    await pool.query("DELETE FROM sessions WHERE user_id = $1", [request.userID]);
    return {};
  });
}

export async function requireUser(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const raw = request.headers.authorization;
  if (!raw?.startsWith("Bearer ")) { await reply.code(401).send({ message: "Authentication required." }); return; }
  const result = await pool.query<{ user_id: string }>(
    `SELECT s.user_id FROM sessions s JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = $1 AND s.expires_at > now() AND u.deleted_at IS NULL`, [hash(raw.slice(7))]);
  const session = result.rows[0];
  if (!session) { await reply.code(401).send({ message: "Session expired." }); return; }
  request.userID = session.user_id;
}
