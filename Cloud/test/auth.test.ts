import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { createApp } from "../src/app.js";

const token = "test-device-token-that-is-not-a-deployment-secret";
const tokenSha256 = createHash("sha256").update(token).digest("hex");

test("all capture routes reject missing or wrong bearer tokens before accessing services", async () => {
  let starts = 0;
  const app = createApp({ tokenSha256, service: () => { starts++; throw new Error("must not start"); } });
  const routes = [
    ["POST", "/v1/uploads"],
    ["POST", "/v1/uploads/11111111-1111-4111-8111-111111111111/complete"],
    ["GET", "/v1/captures"],
    ["GET", "/v1/captures/11111111-1111-4111-8111-111111111111/download"],
    ["POST", "/v1/captures/11111111-1111-4111-8111-111111111111/share"],
    ["DELETE", "/v1/captures/11111111-1111-4111-8111-111111111111"],
    ["GET", "/v1/usage"],
  ];
  for (const [method, path] of routes) {
    for (const authorization of [undefined, "Bearer wrong", "Basic dXNlcjpwYXNz"]) {
      const response = await app.request(path!, {
        method: method!,
        headers: authorization ? { authorization } : {},
      });
      assert.equal(response.status, 401, `${method} ${path}`);
      assert.equal((await response.json()).error.code, "unauthorized");
      assert.equal(response.headers.get("cache-control"), "no-store");
    }
  }
  assert.equal(starts, 0);
});

test("missing or malformed server token hash fails closed", async () => {
  for (const configuredHash of [undefined, "", "not-a-sha256"]) {
    let starts = 0;
    const app = createApp({ tokenSha256: configuredHash, service: () => { starts++; throw new Error("must not start"); } });
    const response = await app.request("/v1/usage", { headers: { authorization: `Bearer ${token}` } });
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error.code, "configuration_error");
    assert.equal(starts, 0);
  }
});

test("public health does not connect to the database or object storage", async () => {
  const app = createApp({ tokenSha256, service: () => { throw new Error("must not start"); } });
  const response = await app.request("/health");
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});
