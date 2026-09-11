import assert from "node:assert/strict";
import { test } from "node:test";
import { Readable } from "node:stream";
import { S3Client } from "@aws-sdk/client-s3";
import { createS3Storage } from "../src/storage.js";
import type { CaptureRecord } from "../src/contracts.js";

const record: CaptureRecord = {
  id: "11111111-1111-4111-8111-111111111111", filename: "Capture résumé.png", kind: "screenshot", contentType: "image/png",
  byteCount: 3, sha256: "a".repeat(64), createdAt: "2026-08-27T10:00:00.000Z", uploadedAt: null, status: "pending",
  objectKey: "captures/test/immutable", uploadExpiresAt: "2026-08-27T12:15:00.000Z",
};

function client(reply?: { status: number; headers?: Record<string, string>; xml?: string }) {
  return new S3Client({
    endpoint: "https://storage.example.invalid", region: "us-east-2", forcePathStyle: true,
    credentials: { accessKeyId: "test-access-id", secretAccessKey: "test-signing-secret-never-use-outside-tests" },
    requestChecksumCalculation: "WHEN_REQUIRED", responseChecksumValidation: "WHEN_REQUIRED", maxAttempts: 1,
    requestHandler: {
      handle: async (request: { hostname: string; path: string }) => {
        assert.equal(request.hostname, "storage.example.invalid");
        assert.equal(request.path, "/lenscap/captures/test/immutable");
        if (!reply) throw new Error("Presigning must not perform network I/O");
        return { response: { statusCode: reply.status, headers: reply.headers ?? {}, body: Readable.from([reply.xml ?? ""]) } };
      },
    },
  });
}

test("SDK presigned PUT binds immutable key, length, type, metadata and conditional creation", async () => {
  const s3 = client();
  try {
    const grant = await createS3Storage(s3).signUpload(record, 900);
    const url = new URL(grant.url);
    assert.equal(url.pathname, "/lenscap/captures/test/immutable");
    assert.equal(url.searchParams.get("X-Amz-Expires"), "900");
    assert.equal(grant.method, "PUT");
    const signed = url.searchParams.get("X-Amz-SignedHeaders")!.split(";");
    for (const name of ["content-length", "content-type", "if-none-match", "x-amz-meta-capture-id", "x-amz-meta-sha256", "x-amz-meta-kind"]) assert.ok(signed.includes(name), `${name} must be signed`);
    assert.equal(grant.headers["Content-Length"], "3");
    assert.equal(grant.headers["Content-Type"], "image/png");
    assert.equal(grant.headers["If-None-Match"], "*");
    assert.equal(grant.headers["x-amz-meta-sha256"], "a".repeat(64));
    assert.equal(grant.headers["x-amz-meta-capture-id"], record.id);
    assert.equal(grant.headers["x-amz-meta-kind"], "screenshot");
    assert.equal(grant.headers["Cache-Control"], "private, no-store");
    assert.match(grant.headers["Content-Disposition"]!, /^inline; filename=/, "Browser preview must work even when Neon ignores GET response header overrides.");
    assert.ok(grant.headers["Content-Disposition"]!.includes("filename*=UTF-8''Capture%20r%C3%A9sum%C3%A9.png"));
    assert.ok(!grant.url.includes("test-signing-secret"));
    assert.ok(![...url.searchParams.keys()].some((key) => key.toLowerCase().includes("checksum")), "Do not sign an automatic checksum for an absent request body.");
  } finally { s3.destroy(); }
});

test("signed GET uses the requested expiry and never makes a bucket public", async () => {
  const s3 = client();
  try {
    const storage = createS3Storage(s3);
    const url = new URL(await storage.signDownload(record, 604800));
    assert.equal(url.pathname, "/lenscap/captures/test/immutable");
    assert.equal(url.searchParams.get("X-Amz-Expires"), "604800");
    assert.ok(url.searchParams.get("X-Amz-Signature"));
  } finally { s3.destroy(); }
});

test("HEAD returns server-observed object properties and a missing object is explicit", async () => {
  const success = client({ status: 200, headers: {
    "content-length": "3", "content-type": "image/png", "x-amz-meta-capture-id": record.id,
    "x-amz-meta-sha256": record.sha256, "x-amz-meta-kind": "screenshot",
  } });
  const missing = client({ status: 404 });
  try {
    assert.deepEqual(await createS3Storage(success).head(record.objectKey), {
      byteCount: 3, contentType: "image/png", metadata: { "capture-id": record.id, sha256: record.sha256, kind: "screenshot" },
    });
    assert.equal(await createS3Storage(missing).head(record.objectKey), null);
    await createS3Storage(missing).delete(record.objectKey);
  } finally { success.destroy(); missing.destroy(); }
});

test("provider throttling and quota failures use safe actionable API errors", async () => {
  const throttled = client({ status: 503, xml: "<Error><Code>SlowDown</Code><Message>private provider request</Message></Error>" });
  const quota = client({ status: 507, xml: "<Error><Code>QuotaExceeded</Code><Message>private bucket/account internals</Message></Error>" });
  try {
    await assert.rejects(createS3Storage(throttled).delete(record.objectKey), { status: 503, code: "storage_unavailable" });
    await assert.rejects(createS3Storage(quota).delete(record.objectKey), (error: unknown) => {
      assert.equal((error as { status: number }).status, 507);
      assert.match((error as Error).message, /5 GB.*account/);
      assert.doesNotMatch((error as Error).message, /private/);
      return true;
    });
  } finally { throttled.destroy(); quota.destroy(); }
});
