import assert from "node:assert/strict";
import { test } from "node:test";
import { createCloudService } from "../src/service.js";
import { parseListOptions } from "../src/validation.js";
import type { UploadInput } from "../src/contracts.js";
import { MemoryRepository, MemoryStorage } from "./fakes.js";

const input: UploadInput = {
  id: "11111111-1111-4111-8111-111111111111", filename: "Capture.png", kind: "screenshot", contentType: "image/png",
  byteCount: 3, sha256: "a".repeat(64), createdAt: "2026-08-27T10:00:00.000Z",
};

function fixture() {
  const repository = new MemoryRepository();
  const storage = new MemoryStorage();
  let time = new Date("2026-08-27T12:00:00.000Z");
  const api = createCloudService({ repository, storage, now: () => time });
  const uploaded = async (patch: Partial<UploadInput> = {}) => {
    const metadata = { ...input, ...patch };
    await api.createUpload(metadata);
    storage.put(repository.records.get(metadata.id)!);
    return api.completeUpload(metadata.id);
  };
  return { api, repository, storage, uploaded, advance: (seconds: number) => { time = new Date(time.getTime() + seconds * 1000); } };
}

test("reserving an upload returns the frozen metadata contract without internal object keys", async () => {
  const { api, repository, storage } = fixture();
  const response = await api.createUpload(input);
  assert.deepEqual(response.capture, { ...input, uploadedAt: null, status: "pending" });
  assert.equal(response.alreadyUploaded, false);
  assert.equal(response.upload?.method, "PUT");
  assert.match(response.upload!.url, /^https:\/\/storage\.invalid\/lenscap\/captures\//);
  assert.equal(repository.records.size, 1);
  assert.equal(storage.uploadGrants[0]?.seconds, 900);
});

test("concurrent matching reservations reuse one immutable object key", async () => {
  const { api, repository, storage } = fixture();
  await Promise.all([api.createUpload(input), api.createUpload(input)]);
  assert.equal(repository.records.size, 1);
  assert.equal(storage.uploadGrants[0]?.capture.objectKey, storage.uploadGrants[1]?.capture.objectKey);
});

test("reusing an id with different immutable metadata returns conflict", async () => {
  const { api } = fixture();
  await api.createUpload(input);
  for (const patch of [{ sha256: "b".repeat(64) }, { byteCount: 4 }, { filename: "Other.png" }, { createdAt: "2026-08-27T11:00:00.000Z" }]) {
    await assert.rejects(api.createUpload({ ...input, ...patch }), { status: 409, code: "capture_conflict" });
  }
});

test("completion validates object length, type, id, kind, and hash metadata before publishing", async () => {
  const { api, storage, repository } = fixture();
  await api.createUpload(input);
  const record = repository.records.get(input.id)!;
  const invalid = [
    { byteCount: 2 }, { contentType: "text/html" }, { metadata: {} },
    { metadata: { "capture-id": input.id, sha256: "b".repeat(64), kind: "screenshot" } },
    { metadata: { "capture-id": "another-id", sha256: input.sha256, kind: "screenshot" } },
    { metadata: { "capture-id": input.id, sha256: input.sha256, kind: "video" } },
  ];
  for (const patch of invalid) {
    storage.put(record, patch);
    await assert.rejects(api.completeUpload(input.id), { status: 409, code: "upload_mismatch" });
    assert.equal(repository.records.get(input.id)!.status, "pending");
  }
  storage.put(record);
  assert.equal((await api.completeUpload(input.id)).capture.status, "uploaded");
});

test("missing uploads remain pending and are not listed", async () => {
  const { api, repository } = fixture();
  await api.createUpload(input);
  await assert.rejects(api.completeUpload(input.id), { status: 409, code: "upload_missing" });
  assert.equal(repository.records.get(input.id)!.status, "pending");
  assert.deepEqual(await api.listCaptures({ limit: 50 }), { captures: [], nextCursor: null });
});

test("completion retries preserve uploadedAt and completed reservations do not issue a new PUT", async () => {
  const { api, uploaded, advance, storage } = fixture();
  const first = await uploaded();
  advance(60);
  const second = await api.completeUpload(input.id);
  assert.deepEqual(second, first);
  const reservation = await api.createUpload(input);
  assert.equal(reservation.alreadyUploaded, true);
  assert.equal(reservation.upload, undefined);
  assert.equal(storage.uploadGrants.length, 1);
});

test("keyset pagination handles equal capture timestamps without duplicates or exposing pending rows", async () => {
  const { api, uploaded } = fixture();
  const ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"];
  for (const id of ids) await uploaded({ id });
  await api.createUpload({ ...input, id: "44444444-4444-4444-8444-444444444444" });
  const first = await api.listCaptures({ limit: 2 });
  assert.deepEqual(first.captures.map((row) => row.id), [ids[2], ids[1]]);
  assert.ok(first.nextCursor);
  const second = await api.listCaptures(parseListOptions(new URL(`https://api.invalid/v1/captures?limit=2&cursor=${first.nextCursor}`)));
  assert.deepEqual(second.captures.map((row) => row.id), [ids[0]]);
  assert.equal(second.nextCursor, null);
});

test("download and explicit sharing use separate short and seven-day expirations", async () => {
  const { api, uploaded, storage } = fixture();
  await uploaded();
  assert.equal(storage.downloadGrants.length, 0, "Uploads must not create a share grant.");
  const download = await api.download(input.id);
  const share = await api.share(input.id);
  assert.equal(download.expiresAt, "2026-08-27T12:05:00.000Z");
  assert.equal(share.expiresAt, "2026-09-03T12:00:00.000Z");
  assert.deepEqual(storage.downloadGrants.map((grant) => grant.seconds), [300, 604800]);
});

test("pending or missing objects cannot produce usable download or sharing grants", async () => {
  const { api, repository, storage } = fixture();
  await api.createUpload(input);
  await assert.rejects(api.download(input.id), { status: 409, code: "upload_pending" });
  await assert.rejects(api.share(input.id), { status: 409, code: "upload_pending" });
  storage.put(repository.records.get(input.id)!);
  await api.completeUpload(input.id);
  storage.objects.clear();
  await assert.rejects(api.download(input.id), { status: 404, code: "object_missing" });
  assert.equal(storage.downloadGrants.length, 0);
});

test("usage counts this library and labels the free storage allowance as account-wide", async () => {
  const { api, uploaded } = fixture();
  await uploaded();
  await api.createUpload({ ...input, id: "22222222-2222-4222-8222-222222222222", byteCount: 4 });
  assert.deepEqual(await api.usage(), {
    captureCount: 1, storageBytes: 3, pendingUploadCount: 1, databaseBytes: 8192,
    limits: { databaseBytes: 536870912, maxFileBytes: 5368709120, objectStorageBytes: 5000000000, objectStorageScope: "account" },
    provider: "Neon", plan: "free", beta: true,
  });
});

test("a full database rejects new reservations but permits an existing pending retry", async () => {
  const { api, repository } = fixture();
  await api.createUpload(input);
  repository.bytes = 536_870_912;
  await assert.rejects(api.createUpload({ ...input, id: "22222222-2222-4222-8222-222222222222" }), { status: 507, code: "database_quota_exceeded" });
  assert.equal((await api.createUpload(input)).alreadyUploaded, false);
  assert.equal(repository.records.size, 1);
});

test("delete removes the cloud object and row, remains idempotent, and prevents retry resurrection", async () => {
  const { api, uploaded, repository, storage } = fixture();
  await uploaded();
  await api.share(input.id);
  await api.deleteCapture(input.id);
  await api.deleteCapture(input.id);
  assert.equal(storage.objects.size, 0);
  assert.equal(repository.records.size, 0);
  assert.equal(repository.deleted.size, 1);
  await assert.rejects(api.createUpload(input), { status: 410, code: "capture_deleted" });
  await assert.rejects(api.download(input.id), { status: 404, code: "capture_not_found" });
  await assert.rejects(api.share(input.id), { status: 404, code: "capture_not_found" });
});

test("a failed object delete retains metadata so deleting can be retried safely", async () => {
  const { api, uploaded, repository, storage } = fixture();
  await uploaded();
  storage.failDelete = true;
  await assert.rejects(api.deleteCapture(input.id));
  assert.equal(repository.records.size, 1);
  assert.equal(repository.deleted.size, 0);
  storage.failDelete = false;
  await api.deleteCapture(input.id);
  assert.equal(repository.records.size, 0);
});

test("later authenticated cleanup removes objects recreated by a still-live deleted PUT grant", async () => {
  const { api, repository, storage, advance } = fixture();
  await api.createUpload(input);
  const record = repository.records.get(input.id)!;
  await api.deleteCapture(input.id);
  storage.put(record); // A direct PUT URL cannot be individually revoked.
  await api.cleanupDeleted();
  assert.equal(storage.objects.size, 1);
  advance(901);
  await api.cleanupDeleted();
  assert.equal(storage.objects.size, 0);
  assert.ok(repository.deleted.get(input.id)!.lastCleanupAt);
  await assert.rejects(api.completeUpload(input.id), { status: 410, code: "capture_deleted" });
});
