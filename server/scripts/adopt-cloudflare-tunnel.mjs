import { spawnSync } from "node:child_process";
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const inspected = spawnSync("docker", ["inspect", "lazysplit-cloudflared"], { encoding: "utf8" });
if (inspected.status !== 0) throw new Error("The lazysplit-cloudflared container is unavailable.");
const [container] = JSON.parse(inspected.stdout);
const command = container?.Config?.Cmd;
const tokenIndex = Array.isArray(command) ? command.indexOf("--token") : -1;
const token = tokenIndex >= 0 ? command[tokenIndex + 1] : undefined;
if (!token || typeof token !== "string") throw new Error("The Cloudflare tunnel token could not be found.");

const envPath = resolve(process.cwd(), ".env");
const temporaryPath = `${envPath}.cloudflare`;
let contents = await readFile(envPath, "utf8");
if (/^CLOUDFLARE_TUNNEL_TOKEN=.*$/m.test(contents)) {
  contents = contents.replace(/^CLOUDFLARE_TUNNEL_TOKEN=.*$/m, `CLOUDFLARE_TUNNEL_TOKEN=${token}`);
} else {
  contents = `${contents.trimEnd()}\nCLOUDFLARE_TUNNEL_TOKEN=${token}\n`;
}
await writeFile(temporaryPath, contents, { encoding: "utf8", mode: 0o600 });
await rename(temporaryPath, envPath);
await chmod(envPath, 0o600);
console.log("Stored the existing Cloudflare tunnel token in the ignored server/.env file.");
