import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { createRuntimeApp } from "../src/index.js";

test("the deployed entrypoint only reads provider configuration after authenticating", async () => {
  const token = "runtime-fixture-token";
  const app = createRuntimeApp({ LENSCAP_DEVICE_TOKEN_SHA256: createHash("sha256").update(token).digest("hex") });
  assert.equal((await app.request("/health")).status, 200);
  assert.equal((await app.request("/v1/usage")).status, 401);
  const authorized = await app.request("/v1/usage", { headers: { authorization: `Bearer ${token}` } });
  assert.equal(authorized.status, 503);
  assert.deepEqual(await authorized.json(), { error: { code: "configuration_error", message: "Cloud database or storage is not configured." } });
});
