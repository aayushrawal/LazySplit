import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireUser } from "./auth.js";
import { pool } from "./db.js";

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
  app.put("/v1/devices/current", { preHandler: requireUser }, async (request) => {
    const body = z.object({ token: z.string().min(16), timezone: z.string().min(1), digestHour: z.number().int().min(0).max(23).default(19), enabled: z.boolean().default(true) }).parse(request.body);
    await pool.query(
      `INSERT INTO devices(token,user_id,timezone,digest_hour,enabled) VALUES($1,$2,$3,$4,$5)
       ON CONFLICT(token) DO UPDATE SET user_id=EXCLUDED.user_id,timezone=EXCLUDED.timezone,digest_hour=EXCLUDED.digest_hour,enabled=EXCLUDED.enabled,updated_at=now()`,
      [body.token, request.userID, body.timezone, body.digestHour, body.enabled]);
    return {};
  });
}
