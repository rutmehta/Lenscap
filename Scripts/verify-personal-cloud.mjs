// Integration smoke test against a dedicated test branch. Only deletes the
// random capture IDs created by this run. Never prints credentials or URLs
// containing signatures. Usage: node Scripts/verify-personal-cloud.mjs <private-client.json>
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, stat } from "node:fs/promises";

const setupPath = process.argv[2];
assert.ok(setupPath, "Pass a private test connection JSON file.");
const setupStat = await stat(setupPath);
assert.equal(setupStat.mode & 0o077, 0, "The test connection file must be private.");
const { apiURL, deviceToken } = JSON.parse(await readFile(setupPath, "utf8"));
const base = new URL(apiURL);
assert.equal(base.protocol, "https:");
assert.ok(typeof deviceToken === "string" && deviceToken.length >= 32);
const created = [];

async function request(path, { method = "GET", body, authorized = true } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (authorized) headers.Authorization = `Bearer ${deviceToken}`;
  return fetch(new URL(path, base), {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "error", signal: AbortSignal.timeout(60000),
  });
}

async function json(path, options) {
  const response = await request(path, options);
  assert.ok(response.ok, `${options?.method ?? "GET"} ${path.split("?")[0]} failed (${response.status})`);
  return response.json();
}

const fixtures = [
  { filename: "Lenscap cloud smoke.png", kind: "screenshot", contentType: "image/png",
    bytes: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==", "base64") },
  { filename: "Lenscap cloud smoke.gif", kind: "gif", contentType: "image/gif",
    bytes: Buffer.from("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "base64") },
];

try {
  assert.equal((await request("/v1/captures", { authorized: false })).status, 401);
  assert.equal((await request("/v1/uploads", { method: "POST", authorized: false, body: {} })).status, 401);
  console.log("PASS: unauthenticated library and upload access rejected");

  for (const fixture of fixtures) {
    const id = randomUUID();
    const metadata = { id, filename: fixture.filename, kind: fixture.kind, contentType: fixture.contentType,
      byteCount: fixture.bytes.length, sha256: createHash("sha256").update(fixture.bytes).digest("hex"),
      createdAt: new Date().toISOString() };
    created.push(id);
    const grant = await json("/v1/uploads", { method: "POST", body: metadata });
    assert.equal(grant.alreadyUploaded, false);
    assert.ok(grant.upload?.url && grant.upload?.headers);
    const put = await fetch(grant.upload.url, { method: "PUT", headers: grant.upload.headers,
      body: fixture.bytes, redirect: "error", signal: AbortSignal.timeout(60000) });
    assert.ok(put.ok, `Object PUT failed (${put.status})`);

    // Simulate losing the first PUT/complete response: a new grant must not
    // overwrite the existing object, and the client can still complete it.
    const retryGrant = await json("/v1/uploads", { method: "POST", body: metadata });
    const replay = await fetch(retryGrant.upload.url, { method: "PUT", headers: retryGrant.upload.headers,
      body: Buffer.alloc(fixture.bytes.length, 0x41), redirect: "error", signal: AbortSignal.timeout(60000) });
    assert.equal(replay.status, 412, "Neon must enforce conditional PUT before immutable uploads can ship.");
    const completed = await json(`/v1/uploads/${id}/complete`, { method: "POST" });
    assert.equal(completed.capture.id, id);
    assert.equal(completed.capture.status, "uploaded");
    const repeated = await json("/v1/uploads", { method: "POST", body: metadata });
    assert.equal(repeated.alreadyUploaded, true);
    assert.equal(repeated.upload, undefined);

    const conflict = await request("/v1/uploads", { method: "POST", body: { ...metadata, filename: "different.png" } });
    assert.equal(conflict.status, 409);
    const link = await json(`/v1/captures/${id}/download`);
    const download = await fetch(link.url, { redirect: "error", signal: AbortSignal.timeout(60000) });
    assert.ok(download.ok);
    assert.equal(download.headers.get("content-type"), fixture.contentType);
    assert.ok(download.headers.get("content-disposition")?.startsWith("inline;"), "Shared media should preview in the browser.");
    assert.equal(createHash("sha256").update(Buffer.from(await download.arrayBuffer())).digest("hex"), metadata.sha256);
    const unsigned = new URL(link.url);
    unsigned.search = "";
    const privateResponse = await fetch(unsigned, { redirect: "error", signal: AbortSignal.timeout(60000) });
    assert.ok([401, 403].includes(privateResponse.status), "Object bytes must require a signed URL.");
    const shared = await json(`/v1/captures/${id}/share`, { method: "POST" });
    const lifetime = Date.parse(shared.expiresAt) - Date.now();
    assert.equal(new URL(shared.url).searchParams.get("X-Amz-Expires"), "604800");
    assert.ok(Math.abs(lifetime - 7 * 86400000) < 60000, "Reported share expiry should match the seven-day grant (allowing clock skew).");
    assert.ok((await fetch(shared.url, { redirect: "error", signal: AbortSignal.timeout(60000) })).ok);
    console.log(`PASS: ${fixture.kind} upload, conditional replay, completion, hash, private access, and seven-day share`);
  }

  const firstPage = await json("/v1/captures?limit=1");
  assert.equal(firstPage.captures.length, 1);
  assert.ok(firstPage.nextCursor);
  const secondPage = await json(`/v1/captures?limit=1&cursor=${encodeURIComponent(firstPage.nextCursor)}`);
  assert.equal(secondPage.captures.length, 1);
  assert.notEqual(firstPage.captures[0].id, secondPage.captures[0].id);
  const usage = await json("/v1/usage");
  assert.ok(usage.captureCount >= 2);
  assert.ok(usage.storageBytes >= fixtures.reduce((sum, fixture) => sum + fixture.bytes.length, 0));
  assert.equal(usage.limits.objectStorageScope, "account");
  assert.ok(usage.databaseBytes > 0);
  console.log("PASS: pagination and account-scoped usage");
} finally {
  for (const id of created) {
    const result = await request(`/v1/captures/${id}`, { method: "DELETE" });
    assert.equal(result.status, 204, "Only this run's test capture should be removed.");
    assert.equal((await request(`/v1/captures/${id}/download`)).status, 404);
  }
  console.log(`Cleaned up ${created.length} captures created by this test.`);
}
