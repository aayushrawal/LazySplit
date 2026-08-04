import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const envPath = resolve(process.cwd(), ".env");
const temporaryPath = `${envPath}.rotating`;
let contents = await readFile(envPath, "utf8");

const replace = (name, value) => {
  const pattern = new RegExp(`^${name}=.*$`, "m");
  if (!pattern.test(contents)) throw new Error(`${name} is missing from .env`);
  contents = contents.replace(pattern, `${name}=${value}`);
};

replace("SESSION_SECRET", randomBytes(48).toString("base64url"));
replace("TOKEN_ENCRYPTION_KEY", randomBytes(32).toString("base64"));
const developmentAccessCode = randomBytes(18).toString("base64url");
if (/^DEVELOPMENT_ACCESS_CODE=.*$/m.test(contents)) replace("DEVELOPMENT_ACCESS_CODE", developmentAccessCode);
else contents = contents.replace(/^PLAID_CLIENT_ID=/m, `DEVELOPMENT_ACCESS_CODE=${developmentAccessCode}\nPLAID_CLIENT_ID=`);

const databasePassword = randomBytes(36).toString("base64url");
const databaseURLMatch = contents.match(/^DATABASE_URL=(.+)$/m);
if (!databaseURLMatch) throw new Error("DATABASE_URL is missing from .env");
const databaseURL = new URL(databaseURLMatch[1]);
databaseURL.password = databasePassword;
replace("DATABASE_URL", databaseURL.toString());
if (/^POSTGRES_PASSWORD=.*$/m.test(contents)) replace("POSTGRES_PASSWORD", databasePassword);
else contents = contents.replace(/^DATABASE_URL=/m, `POSTGRES_PASSWORD=${databasePassword}\nDATABASE_URL=`);

const escapedPassword = databasePassword.replaceAll("'", "''");
const passwordUpdate = spawnSync(
  "docker",
  ["exec", "-i", "lazy-split-postgres", "psql", "-U", "postgres", "-d", "lazysplit", "-v", "ON_ERROR_STOP=1"],
  { input: `ALTER ROLE postgres WITH PASSWORD '${escapedPassword}';\n`, encoding: "utf8" }
);
if (passwordUpdate.status !== 0) {
  throw new Error(`Could not rotate the PostgreSQL password: ${passwordUpdate.stderr.trim()}`);
}

await writeFile(temporaryPath, contents, { encoding: "utf8", mode: 0o600 });
await rename(temporaryPath, envPath);
await chmod(envPath, 0o600);
const clipboard = spawnSync("pbcopy", [], { input: developmentAccessCode, encoding: "utf8" });
console.log(`Rotated application encryption, session, and PostgreSQL secrets in server/.env.${clipboard.status === 0 ? " Development access code copied to clipboard." : ""}`);
