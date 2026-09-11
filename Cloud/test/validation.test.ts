import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { createApp } from "../src/app.js";

const token = "test-device-token-that-is-not-a-deployment-secret";
const tokenSha256 = createHash("sha256").update(token).digest("hex");
const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
const valid = {
  id: "11111111-1111-4111-8111-111111111111",
  filename: "Capture.png", kind: "screenshot", contentType: "image/png",
  byteCount: 3, sha256: "a".repeat(64), createdAt: "2026-08-27T12:34:56.000Z",
};

test("invalid upload metadata is rejected before starting database or storage services", async () => {
  let starts = 0;
  const app = createApp({ tokenSha256, service: () => { starts++; throw new Error("must not start"); } });
  const invalid = [
    { id: "not-uuid" }, { filename: "../capture.png" }, { filename: "sub\\capture.png" },
    { filename: "bad\nfilename.png" }, { filename: " " }, { filename: "é".repeat(200) },
    { kind: "unknown" }, { contentType: "text/html" }, { kind: "video" },
    { byteCount: 0 }, { byteCount: -1 }, { byteCount: 1.5 }, { byteCount: 5_368_709_121 },
    { sha256: "A".repeat(64) }, { sha256: "a" }, { createdAt: "yesterday" },
    { createdAt: "2026-02-30T00:00:00Z" }, { objectKey: "someone-else" },
  ];
  for (const patch of invalid) {
    const response = await app.request("/v1/uploads", { method: "POST", headers, body: JSON.stringify({ ...valid, ...patch }) });
    assert.equal(response.status, 400, JSON.stringify(patch));
    assert.equal((await response.json()).error.code, "invalid_request");
  }
  assert.equal(starts, 0);
});

test("malformed or oversized JSON uses the error contract without touching services", async () => {
  let starts = 0;
  const app = createApp({ tokenSha256, service: () => { starts++; throw new Error("must not start"); } });
  const badJSON = await app.request("/v1/uploads", { method: "POST", headers, body: "{" });
  assert.equal(badJSON.status, 400);
  assert.equal((await badJSON.json()).error.code, "invalid_request");
  const wrongType = await app.request("/v1/uploads", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "text/plain" }, body: JSON.stringify(valid) });
  assert.equal(wrongType.status, 415);
  const tooLarge = await app.request("/v1/uploads", { method: "POST", headers, body: JSON.stringify({ ...valid, filename: "x".repeat(20_000) }) });
  assert.equal(tooLarge.status, 413);
  assert.equal((await tooLarge.json()).error.code, "request_too_large");
  assert.equal(starts, 0);
});

test("invalid ids and cursor/limit parameters are rejected before services", async () => {
  let starts = 0;
  const app = createApp({ tokenSha256, service: () => { starts++; throw new Error("must not start"); } });
  for (const path of ["/v1/captures/nope/download", "/v1/captures?limit=0", "/v1/captures?limit=101", "/v1/captures?limit=1.5", "/v1/captures?cursor=not-valid", "/v1/captures?limit=2&limit=3"]) {
    const response = await app.request(path, { headers });
    assert.equal(response.status, 400, path);
    assert.equal((await response.json()).error.code, "invalid_request");
  }
  assert.equal(starts, 0);
});

test("unexpected service failures do not expose provider credentials or internals", async () => {
  const app = createApp({ tokenSha256, service: () => { throw new Error("postgres://private-user:private-password@private-host/db"); } });
  const response = await app.request("/v1/usage", { headers });
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: { code: "internal_error", message: "The cloud request could not be completed. Please retry." } });
});
