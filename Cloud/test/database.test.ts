import assert from "node:assert/strict";
import { after, before, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { migrate } from "drizzle-orm/pglite/migrator";
import { createCaptureRepository } from "../src/db/repository.js";
import * as schema from "../src/db/schema.js";
import { createCloudService } from "../src/service.js";
import { createApp } from "../src/app.js";
import { MemoryStorage } from "./fakes.js";
import type { CaptureRecord } from "../src/contracts.js";
import { createHash } from "node:crypto";

const client = new PGlite();
const db = drizzle(client, { schema });
const repository = createCaptureRepository(db);
const record: CaptureRecord = {
  id: "11111111-1111-4111-8111-111111111111", filename: "Capture 'quoted'.png", kind: "screenshot", contentType: "image/png",
  byteCount: 3, sha256: "a".repeat(64), createdAt: "2026-08-27T10:00:00.000Z", uploadedAt: null, status: "pending",
  objectKey: "captures/test/immutable", uploadExpiresAt: "2026-08-27T12:15:00.000Z",
};

before(async () => {
  await client.waitReady;
  const migrationsFolder = fileURLToPath(new URL("../drizzle", import.meta.url));
  await migrate(db, { migrationsFolder });
  await migrate(db, { migrationsFolder });
});
beforeEach(async () => { await client.exec("TRUNCATE lenscap_captures, lenscap_deleted_captures"); });
after(async () => { await client.close(); });

test("Drizzle repository stores typed metadata and timestamps using the actual migration", async () => {
  await repository.withCapture(record.id, async (tx) => { await tx.insert(record); });
  const restored = await repository.withCapture(record.id, (tx) => tx.get());
  assert.deepEqual(restored, record);
  assert.ok(await repository.databaseBytes() > 0);
});

test("transaction errors roll back capture writes and leave a usable connection", async () => {
  await assert.rejects(repository.withCapture(record.id, async (tx) => {
    await tx.insert(record);
    throw new Error("injected failure");
  }), /injected failure/);
  assert.equal(await repository.withCapture(record.id, (tx) => tx.get()), null);
  await repository.withCapture(record.id, (tx) => tx.insert(record));
  assert.equal((await repository.usage()).pendingUploadCount, 1);
});

test("SQL pagination and counts exclude pending rows and support equal timestamps", async () => {
  const ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"];
  for (const id of ids) await repository.withCapture(id, (tx) => tx.insert({ ...record, id, objectKey: `captures/${id}`, status: "uploaded", uploadedAt: "2026-08-27T12:00:00.000Z" }));
  const pendingId = "44444444-4444-4444-8444-444444444444";
  await repository.withCapture(pendingId, (tx) => tx.insert({ ...record, id: pendingId, objectKey: "captures/pending" }));
  assert.deepEqual((await repository.list({ limit: 2 })).map((row) => row.id), [ids[2], ids[1]]);
  assert.deepEqual((await repository.list({ limit: 2, cursor: { id: ids[1]!, createdAt: record.createdAt } })).map((row) => row.id), [ids[0]]);
  assert.deepEqual(await repository.usage(), { captureCount: 3, storageBytes: 9, pendingUploadCount: 1 });
});

test("failed storage deletion rolls back the real database tombstone and row deletion", async () => {
  await repository.withCapture(record.id, (tx) => tx.insert(record));
  const storage = new MemoryStorage();
  storage.failDelete = true;
  const api = createCloudService({ repository, storage });
  await assert.rejects(api.deleteCapture(record.id));
  assert.deepEqual(await repository.withCapture(record.id, (tx) => tx.get()), record);
  assert.equal(await repository.withCapture(record.id, (tx) => tx.getDeleted()), null);
  storage.failDelete = false;
  await api.deleteCapture(record.id);
  assert.equal(await repository.withCapture(record.id, (tx) => tx.get()), null);
  assert.equal((await repository.withCapture(record.id, (tx) => tx.getDeleted()))?.objectKey, record.objectKey);
});

test("deletion cleanup selection retries failures and revisits old grants without deleting tombstones", async () => {
  await repository.withCapture(record.id, (tx) => tx.insert(record));
  const api = createCloudService({ repository, storage: new MemoryStorage(), now: () => new Date("2026-08-27T12:00:00.000Z") });
  await api.deleteCapture(record.id);
  assert.deepEqual(await repository.deletionsDue("2026-08-27T12:00:00.000Z", 10), []);
  assert.equal((await repository.deletionsDue("2026-08-27T12:16:00.000Z", 10)).length, 1);
  await repository.withCapture(record.id, (tx) => tx.markCleaned("2026-08-27T12:16:00.000Z"));
  assert.deepEqual(await repository.deletionsDue("2026-08-27T13:00:00.000Z", 10), []);
  assert.equal((await repository.deletionsDue("2026-08-28T13:00:00.000Z", 10)).length, 1);
});

test("authenticated HTTP upload/complete/list/delete flow persists through the real repository", async () => {
  const storage = new MemoryStorage();
  const service = createCloudService({ repository, storage, now: () => new Date("2026-08-27T12:00:00.000Z") });
  const token = "integration-fixture-token";
  const app = createApp({ tokenSha256: createHash("sha256").update(token).digest("hex"), service: () => service });
  const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
  const { objectKey: _key, uploadExpiresAt: _expiry, uploadedAt: _uploaded, status: _status, ...metadata } = record;
  const reserved = await app.request("/v1/uploads", { method: "POST", headers, body: JSON.stringify(metadata) });
  assert.equal(reserved.status, 200);
  assert.equal((await reserved.json()).capture.status, "pending");
  storage.put((await repository.withCapture(record.id, (tx) => tx.get()))!);
  const completed = await app.request(`/v1/uploads/${record.id}/complete`, { method: "POST", headers });
  assert.equal(completed.status, 200);
  assert.equal((await completed.json()).capture.uploadedAt, "2026-08-27T12:00:00.000Z");
  const listed = await app.request("/v1/captures", { headers });
  assert.equal((await listed.json()).captures[0].id, record.id);
  const removed = await app.request(`/v1/captures/${record.id}`, { method: "DELETE", headers });
  assert.equal(removed.status, 204);
  assert.deepEqual(await repository.usage(), { captureCount: 0, storageBytes: 0, pendingUploadCount: 0 });
});
