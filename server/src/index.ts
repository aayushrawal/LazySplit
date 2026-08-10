import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import Fastify from "fastify";
import { ZodError } from "zod";
import { authRoutes } from "./auth.js";
import { config } from "./config.js";
import { deviceRoutes } from "./devices.js";
import { friendRoutes } from "./friends.js";
import { sendDueDigests } from "./digest.js";
import { parseJSONBody } from "./http.js";
import { plaidRoutes } from "./plaid.js";
import { splitwiseRoutes } from "./splitwise.js";
import { transactionRoutes } from "./transactions.js";

const app = Fastify({ logger: { redact: [
  "req.headers.authorization", "req.body.identityToken", "req.body.publicToken", "req.body.public_token",
  "req.body.public_tokens", "req.body.link_token", "access_token", "encrypted_token", "encrypted_link_token"
] } });
app.removeContentTypeParser("application/json");
app.addContentTypeParser("application/json", { parseAs: "buffer" }, (request, body, done) => {
  request.rawBody = Buffer.isBuffer(body) ? body : Buffer.from(body);
  try { done(null, parseJSONBody(request.rawBody)); }
  catch (error) { done(error as Error, undefined); }
});
await app.register(cors, { origin: false });
await app.register(rateLimit, { max: 120, timeWindow: "1 minute" });
app.get("/health", async () => ({ status: "ok" }));
app.get("/.well-known/apple-app-site-association", async (_request, reply) => {
  reply.type("application/json");
  return {
    applinks: {
      details: [{
        appIDs: [`${config.APPLE_TEAM_ID}.${config.APPLE_CLIENT_ID}`],
        components: [{ "/": "/plaid/*", comment: "Plaid OAuth redirect" }]
      }]
    }
  };
});
app.get("/plaid/callback", async (_request, reply) => {
  return reply.type("text/html; charset=utf-8").send(`<!doctype html>
<html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Return to LazySplit</title></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:48px 24px;text-align:center;background:#f2f2f7;color:#1c1c1e">
<main style="max-width:420px;margin:auto;background:white;padding:32px 24px;border-radius:20px">
<h1 style="font-size:24px">Return to LazySplit</h1>
<p style="color:#636366;line-height:1.45">Your bank authorization is complete. Return to the LazySplit app to finish connecting this account.</p>
</main></body></html>`);
});
await app.register(authRoutes); await app.register(plaidRoutes); await app.register(splitwiseRoutes); await app.register(friendRoutes); await app.register(transactionRoutes); await app.register(deviceRoutes);
app.post("/internal/digests/run", async (request, reply) => {
  if (request.headers.authorization !== `Bearer ${config.SESSION_SECRET}`) return reply.code(401).send({ message: "Unauthorized" });
  return { sent: await sendDueDigests() };
});
app.setErrorHandler((error, _request, reply) => {
  if (error instanceof ZodError) return reply.code(400).send({ message: "Invalid request", issues: error.issues });
  const normalized = error instanceof Error ? error : new Error("Unknown server error");
  const status = "statusCode" in normalized && typeof normalized.statusCode === "number" ? normalized.statusCode : 500;
  app.log.error({ err: normalized }, "Request failed");
  return reply.code(status).send({ message: status >= 500 ? "An unexpected server error occurred." : normalized.message });
});
await app.listen({ host: "0.0.0.0", port: config.PORT });
