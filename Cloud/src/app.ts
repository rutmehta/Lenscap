import { createHash, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { CloudAPI } from "./contracts.js";
import { APIError, invalidRequest, publicError } from "./errors.js";
import { parseID, parseListOptions, parseUpload } from "./validation.js";

export interface AppOptions {
  tokenSha256: string | undefined;
  service: () => CloudAPI;
}

export function createApp(options: AppOptions) {
  const app = new Hono();
  app.use("*", async (c, next) => {
    c.header("Cache-Control", "no-store");
    c.header("X-Content-Type-Options", "nosniff");
    await next();
  });
  app.get("/health", (c) => c.json({ ok: true }));
  app.use("*", async (c, next) => {
    if (!options.tokenSha256 || !/^[a-f0-9]{64}$/.test(options.tokenSha256)) {
      return c.json({ error: { code: "configuration_error", message: "Cloud authentication is not configured." } }, 503);
    }
    const match = /^Bearer ([^\s]{1,512})$/i.exec(c.req.header("authorization") ?? "");
    const digest = createHash("sha256").update(match?.[1] ?? "").digest();
    const expected = Buffer.from(options.tokenSha256, "hex");
    if (!match || !timingSafeEqual(digest, expected)) {
      c.header("WWW-Authenticate", "Bearer");
      return c.json({ error: { code: "unauthorized", message: "A valid device token is required." } }, 401);
    }
    await next();
  });
  app.use("/v1/*", bodyLimit({
    maxSize: 16 * 1024,
    onError: (c) => c.json({ error: { code: "request_too_large", message: "Upload metadata must be smaller than 16 KiB." } }, 413),
  }));

  const service = async () => {
    const api = options.service();
    await api.cleanupDeleted();
    return api;
  };

  app.post("/v1/uploads", async (c) => {
    if (c.req.header("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") {
      throw new APIError(415, "unsupported_media_type", "Upload metadata must use application/json.");
    }
    let input: unknown;
    try { input = await c.req.json(); } catch { throw invalidRequest(); }
    const metadata = parseUpload(input);
    return c.json(await (await service()).createUpload(metadata));
  });
  app.post("/v1/uploads/:id/complete", async (c) => {
    const id = parseID(c.req.param("id"));
    return c.json(await (await service()).completeUpload(id));
  });
  app.get("/v1/captures", async (c) => {
    const listOptions = parseListOptions(new URL(c.req.url));
    return c.json(await (await service()).listCaptures(listOptions));
  });
  app.get("/v1/captures/:id/download", async (c) => {
    const id = parseID(c.req.param("id"));
    return c.json(await (await service()).download(id));
  });
  app.post("/v1/captures/:id/share", async (c) => {
    const id = parseID(c.req.param("id"));
    return c.json(await (await service()).share(id));
  });
  app.get("/v1/usage", async (c) => c.json(await (await service()).usage()));
  app.delete("/v1/captures/:id", async (c) => {
    const id = parseID(c.req.param("id"));
    await (await service()).deleteCapture(id);
    return c.body(null, 204);
  });
  app.onError((error, c) => {
    const safe = publicError(error);
    return c.json({ error: { code: safe.code, message: safe.message } }, safe.status);
  });
  app.notFound((c) => c.json({ error: { code: "not_found", message: "This API route does not exist." } }, 404));
  return app;
}
