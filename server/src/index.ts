import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import Fastify from "fastify";
import { ZodError } from "zod";
import { authRoutes } from "./auth.js";
import { config } from "./config.js";
import { deviceRoutes } from "./devices.js";
import { sendDueDigests } from "./digest.js";
import { plaidRoutes } from "./plaid.js";
import { splitwiseRoutes } from "./splitwise.js";
import { transactionRoutes } from "./transactions.js";

const app = Fastify({ logger: { redact: ["req.headers.authorization", "req.body.identityToken", "req.body.publicToken", "access_token", "encrypted_token"] } });
await app.register(cors, { origin: false });
await app.register(rateLimit, { max: 120, timeWindow: "1 minute" });
app.get("/health", async () => ({ status: "ok" }));
await app.register(authRoutes); await app.register(plaidRoutes); await app.register(splitwiseRoutes); await app.register(transactionRoutes); await app.register(deviceRoutes);
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
