#!/usr/bin/env node
// App Store Connect TestFlight setup for the fork, through the ASC REST API (no Xcode account needed).
//   node scripts/asc.mjs ensure-beta-group   # the internal "Owner" group, all builds, with the account holder in it
// Uses the App Manager key at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8 (FORK-NOTES "TestFlight upload
// pipeline"). Idempotent. 2026-10-31: the app had no group at all, so a processed build reached nobody.
import { createPrivateKey, sign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// scripts/local.env, unless the environment already says.
const localEnv = join(dirname(fileURLToPath(import.meta.url)), "local.env");
if (existsSync(localEnv)) {
  for (const line of readFileSync(localEnv, "utf8").split("\n")) {
    const match = line.match(/^([A-Z_]+)=([^\s#]*)/);
    if (match) process.env[match[1]] ??= match[2];
  }
}
const BUNDLE_ID = process.env.APP_BUNDLE_ID;
const keyId = process.env.ASC_KEY_ID;
// The issuer id is an account identifier, not a secret (App Store Connect → Users and Access → Integrations).
const issuer = process.env.ASC_ISSUER;
if (!BUNDLE_ID || !keyId || !issuer) {
  console.error("asc: set APP_BUNDLE_ID, ASC_KEY_ID and ASC_ISSUER in scripts/local.env (see local.env.example)");
  process.exit(2);
}

function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: "ES256", kid: keyId, typ: "JWT" })}.${b64({ iss: issuer, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" })}`;
  const key = createPrivateKey(readFileSync(join(homedir(), ".appstoreconnect/private_keys", `AuthKey_${keyId}.p8`)));
  return `${body}.${sign("sha256", Buffer.from(body), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}

async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { authorization: `Bearer ${token()}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = res.status === 204 ? null : await res.json();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json?.errors ?? json)}`);
  return json;
}

async function ensureBetaGroup() {
  const appId = (await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data[0]?.id;
  if (!appId) throw new Error(`no App Store Connect app for ${BUNDLE_ID}`);
  const groups = await api("GET", `/v1/apps/${appId}/betaGroups`);
  let group = groups.data.find((g) => g.attributes.isInternalGroup && g.attributes.name === "Owner");
  if (!group) {
    group = (await api("POST", "/v1/betaGroups", {
      data: { type: "betaGroups", attributes: { name: "Owner", isInternalGroup: true, hasAccessToAllBuilds: true }, relationships: { app: { data: { type: "apps", id: appId } } } },
    })).data;
    console.error('created internal group "Owner" (all builds)');
  }
  const holder = (await api("GET", "/v1/users?limit=50")).data.find((u) => u.attributes.roles.includes("ACCOUNT_HOLDER"));
  const testers = await api("GET", `/v1/betaGroups/${group.id}/betaTesters?limit=200`);
  if (holder && !testers.data.some((t) => t.attributes.email === holder.attributes.username)) {
    await api("POST", "/v1/betaTesters", {
      data: {
        type: "betaTesters",
        attributes: { email: holder.attributes.username, firstName: holder.attributes.firstName, lastName: holder.attributes.lastName },
        relationships: { betaGroups: { data: [{ type: "betaGroups", id: group.id }] } },
      },
    });
    console.error(`added the account holder to "Owner"`);
  }
  console.log(group.id);
}

const commands = { "ensure-beta-group": ensureBetaGroup };
const run = commands[process.argv[2]];
if (!run) {
  console.error(`usage: asc.mjs <${Object.keys(commands).join("|")}>`);
  process.exit(2);
}
await run();
