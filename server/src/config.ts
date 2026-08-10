import "dotenv/config";
import { z } from "zod";

const schema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: z.coerce.number().int().positive().default(3000),
  PUBLIC_BASE_URL: z.string().url().default("http://localhost:3000"),
  DATABASE_URL: z.string().min(1),
  SESSION_SECRET: z.string().min(16),
  TOKEN_ENCRYPTION_KEY: z.string().min(1),
  APPLE_CLIENT_ID: z.string().min(1),
  APPLE_TEAM_ID: z.string().min(1),
  GOOGLE_CLIENT_ID: z.string().default(""),
  DEVELOPMENT_ACCESS_CODE: z.string().default(""),
  PLAID_CLIENT_ID: z.string().default(""),
  PLAID_SECRET: z.string().default(""),
  PLAID_ENV: z.enum(["sandbox", "development", "production"]).default("production"),
  PLAID_REDIRECT_URI: z.string().url(),
  SPLITWISE_CLIENT_ID: z.string().default(""),
  SPLITWISE_CLIENT_SECRET: z.string().default(""),
  SPLITWISE_REDIRECT_URI: z.string().url(),
  APNS_TEAM_ID: z.string().default(""), APNS_KEY_ID: z.string().default(""), APNS_PRIVATE_KEY: z.string().default(""), APNS_TOPIC: z.string().default("")
});

export const config = schema.parse(process.env);
