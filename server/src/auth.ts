import { randomBytes } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { config } from "./config.js";
import { decryptToken, hash } from "./crypto.js";
import { pool } from "./db.js";

const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
const appleBody = z.object({ identityToken: z.string().min(1), authorizationCode: z.string().optional().nullable() });
const googleBody = z.object({ identityToken: z.string().min(1) });

async function createSession(userID: string): Promise<string> {
  const token = randomBytes(32).toString("base64url");
  await pool.query("INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, now() + interval '30 days')", [hash(token), userID]);
  return token;
}

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post("/v1/auth/development", async (request, reply) => {
    if (config.NODE_ENV !== "development" || !config.DEVELOPMENT_ACCESS_CODE) return reply.code(404).send({ message: "Not found." });
    const body = z.object({ accessCode: z.string().min(1) }).parse(request.body);
    if (hash(body.accessCode) !== hash(config.DEVELOPMENT_ACCESS_CODE)) return reply.code(401).send({ message: "Invalid development access code." });
    const user = await pool.query<{ id: string }>(
      `INSERT INTO users (apple_subject) VALUES ('development-local-user')
       ON CONFLICT (apple_subject) DO UPDATE SET deleted_at = NULL
       RETURNING id`
    );
    return { token: await createSession(user.rows[0]!.id) };
  });

  app.post("/v1/auth/apple", async (request, reply) => {
    const body = appleBody.parse(request.body);
    const { payload } = await jwtVerify(body.identityToken, appleKeys, { issuer: "https://appleid.apple.com", audience: config.APPLE_CLIENT_ID });
    if (!payload.sub) return reply.code(401).send({ message: "Apple identity is missing a subject." });
    const user = await pool.query<{ id: string }>(
      `INSERT INTO users (apple_subject, email) VALUES ($1, $2)
       ON CONFLICT (apple_subject) DO UPDATE SET email = COALESCE(users.email, EXCLUDED.email)
       RETURNING id`, [payload.sub, typeof payload.email === "string" ? payload.email : null]);
    const userID = user.rows[0]!.id;
    return { token: await createSession(userID) };
  });

  app.post("/v1/auth/google", async (request, reply) => {
    if (!config.GOOGLE_CLIENT_ID) return reply.code(503).send({ message: "Google Sign-In is not configured." });
    const parsed = googleBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ message: "A Google identity token is required." });
    let payload;
    try {
      ({ payload } = await jwtVerify(parsed.data.identityToken, googleKeys, {
        issuer: ["https://accounts.google.com", "accounts.google.com"],
        audience: config.GOOGLE_CLIENT_ID
      }));
    } catch {
      return reply.code(401).send({ message: "Google identity token is invalid or expired." });
    }
    if (!payload.sub || payload.email_verified !== true || typeof payload.email !== "string") {
      return reply.code(401).send({ message: "Google did not provide a verified identity." });
    }
    const existing = await pool.query<{ id: string }>(
      "SELECT id FROM users WHERE google_subject=$1 OR (email=$2 AND google_subject IS NULL) ORDER BY google_subject=$1 DESC LIMIT 1",
      [payload.sub, payload.email]
    );
    let userID = existing.rows[0]?.id;
    if (userID) {
      await pool.query("UPDATE users SET google_subject=$1,email=$2,deleted_at=NULL WHERE id=$3", [payload.sub, payload.email, userID]);
    } else {
      const created = await pool.query<{ id: string }>(
        "INSERT INTO users(google_subject,email) VALUES($1,$2) RETURNING id",
        [payload.sub, payload.email]
      );
      userID = created.rows[0]!.id;
    }
    return { token: await createSession(userID) };
  });

  app.delete("/v1/account", { preHandler: requireUser }, async (request) => {
    const plaidConnections = await pool.query<{ encrypted_token: string }>(
      "SELECT encrypted_token FROM provider_connections WHERE user_id=$1 AND provider='plaid'",
      [request.userID]
    );
    await Promise.allSettled(plaidConnections.rows.map(({ encrypted_token }) => fetch(`https://${config.PLAID_ENV}.plaid.com/item/remove`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "PLAID-CLIENT-ID": config.PLAID_CLIENT_ID, "PLAID-SECRET": config.PLAID_SECRET },
      body: JSON.stringify({ access_token: decryptToken(encrypted_token) })
    })));
    await pool.query("DELETE FROM users WHERE id = $1", [request.userID]);
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
