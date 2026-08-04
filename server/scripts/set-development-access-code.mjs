import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const envPath = resolve(process.cwd(), ".env");
const temporaryPath = `${envPath}.development-code`;
let contents = await readFile(envPath, "utf8");
const developmentAccessCode = randomBytes(18).toString("base64url");

if (/^DEVELOPMENT_ACCESS_CODE=.*$/m.test(contents)) {
  contents = contents.replace(/^DEVELOPMENT_ACCESS_CODE=.*$/m, `DEVELOPMENT_ACCESS_CODE=${developmentAccessCode}`);
} else {
  contents = contents.replace(/^PLAID_CLIENT_ID=/m, `DEVELOPMENT_ACCESS_CODE=${developmentAccessCode}\nPLAID_CLIENT_ID=`);
}

await writeFile(temporaryPath, contents, { encoding: "utf8", mode: 0o600 });
await rename(temporaryPath, envPath);
await chmod(envPath, 0o600);
const clipboard = spawnSync("pbcopy", [], { input: developmentAccessCode, encoding: "utf8" });
console.log(`Updated the development access code in server/.env.${clipboard.status === 0 ? " The new code was copied to the clipboard." : ""}`);
