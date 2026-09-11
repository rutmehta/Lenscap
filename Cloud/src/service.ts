import { randomUUID } from "node:crypto";
import type { Capture, CaptureRecord, CaptureRepository, CaptureStorage, CloudAPI, UploadInput } from "./contracts.js";
import { APIError } from "./errors.js";
import { ACCOUNT_OBJECT_STORAGE_BYTES, DATABASE_LIMIT_BYTES, DOWNLOAD_TTL_SECONDS, MAX_FILE_BYTES, SHARE_TTL_SECONDS, UPLOAD_TTL_SECONDS } from "./limits.js";
import { encodeCursor } from "./validation.js";

export interface ServiceOptions {
  repository: CaptureRepository;
  storage: CaptureStorage;
  now?: () => Date;
}

function wireCapture({ objectKey: _key, uploadExpiresAt: _expiry, ...capture }: CaptureRecord): Capture {
  return capture;
}

function matchesInput(record: CaptureRecord, input: UploadInput): boolean {
  return record.id === input.id && record.sha256 === input.sha256 && record.filename === input.filename &&
    record.byteCount === input.byteCount && record.contentType === input.contentType && record.kind === input.kind &&
    record.createdAt === input.createdAt;
}

export function createCloudService({ repository, storage, now = () => new Date() }: ServiceOptions): CloudAPI {
  const at = (seconds = 0) => new Date(now().getTime() + seconds * 1000).toISOString();

  async function validateObject(record: CaptureRecord, missingStatus: 404 | 409) {
    const object = await storage.head(record.objectKey);
    if (!object) {
      throw new APIError(missingStatus, missingStatus === 404 ? "object_missing" : "upload_missing",
        "The cloud object is missing. Keep the local file and retry the upload.");
    }
    if (object.byteCount !== record.byteCount || object.contentType !== record.contentType ||
        object.metadata["capture-id"] !== record.id || object.metadata.sha256 !== record.sha256 || object.metadata.kind !== record.kind) {
      throw new APIError(409, "upload_mismatch", "The uploaded object does not match the reserved capture.");
    }
  }

  const link = (id: string, seconds: number) => repository.withCapture(id, async (tx) => {
    const record = await tx.get();
    if (!record) throw new APIError(404, "capture_not_found", "The cloud capture was not found.");
    if (record.status !== "uploaded") throw new APIError(409, "upload_pending", "This capture has not finished uploading.");
    await validateObject(record, 404);
    const expiresAt = at(seconds);
    const url = await storage.signDownload(record, seconds);
    return { url, expiresAt };
  });

  return {
    createUpload(input) {
      return repository.withCapture(input.id, async (tx) => {
        if (await tx.getDeleted()) throw new APIError(410, "capture_deleted", "This capture was deleted from the cloud and cannot be retried.");
        let record = await tx.get();
        if (record && !matchesInput(record, input)) {
          throw new APIError(409, "capture_conflict", "This capture id already belongs to different metadata.");
        }
        if (record?.status === "uploaded") return { capture: wireCapture(record), alreadyUploaded: true };
        if (!record) {
          if (await tx.databaseBytes() >= DATABASE_LIMIT_BYTES) {
            throw new APIError(507, "database_quota_exceeded", "The free database allowance is full. Keep local files and free cloud space before retrying.");
          }
          record = { ...input, objectKey: `captures/${input.id}/${randomUUID()}`, status: "pending", uploadedAt: null, uploadExpiresAt: at(UPLOAD_TTL_SECONDS) };
          await tx.insert(record);
        } else {
          // Every signed grant must be included in the later deletion cleanup window.
          record.uploadExpiresAt = at(UPLOAD_TTL_SECONDS) > record.uploadExpiresAt ? at(UPLOAD_TTL_SECONDS) : record.uploadExpiresAt;
          await tx.update(record);
        }
        const upload = await storage.signUpload(record, UPLOAD_TTL_SECONDS);
        return { capture: wireCapture(record), alreadyUploaded: false, upload };
      });
    },

    completeUpload(id) {
      return repository.withCapture(id, async (tx) => {
        const deleted = await tx.getDeleted();
        if (deleted) {
          // A late direct PUT can outlive DELETE. Never publish it again.
          await storage.delete(deleted.objectKey);
          throw new APIError(410, "capture_deleted", "This capture was deleted from the cloud and cannot be completed.");
        }
        const record = await tx.get();
        if (!record) throw new APIError(404, "capture_not_found", "The cloud capture was not found.");
        await validateObject(record, 409);
        if (record.status === "pending") {
          record.status = "uploaded";
          record.uploadedAt = at();
          await tx.update(record);
        }
        return { capture: wireCapture(record) };
      });
    },

    async listCaptures(options) {
      const records = await repository.list({ ...options, limit: options.limit + 1 });
      const page = records.slice(0, options.limit);
      const last = page.at(-1);
      return {
        captures: page.map(wireCapture),
        nextCursor: records.length > options.limit && last ? encodeCursor({ createdAt: last.createdAt, id: last.id }) : null,
      };
    },

    download: (id) => link(id, DOWNLOAD_TTL_SECONDS),
    share: (id) => link(id, SHARE_TTL_SECONDS),

    async usage() {
      const [counts, databaseBytes] = await Promise.all([repository.usage(), repository.databaseBytes()]);
      return {
        ...counts, databaseBytes,
        limits: {
          databaseBytes: DATABASE_LIMIT_BYTES, maxFileBytes: MAX_FILE_BYTES,
          objectStorageBytes: ACCOUNT_OBJECT_STORAGE_BYTES, objectStorageScope: "account",
        },
        provider: "Neon", plan: "free", beta: true,
      };
    },

    deleteCapture(id) {
      return repository.withCapture(id, async (tx) => {
        const record = await tx.get();
        if (!record) {
          const deleted = await tx.getDeleted();
          if (deleted) await storage.delete(deleted.objectKey);
          return;
        }
        await tx.remove({ id, objectKey: record.objectKey, deletedAt: at(), cleanupAfter: record.uploadExpiresAt, lastCleanupAt: null });
        // Keep the transaction open: failures roll back metadata, preserving a retry target.
        await storage.delete(record.objectKey);
      });
    },

    async cleanupDeleted() {
      const time = at();
      const due = await repository.deletionsDue(time, 10);
      for (const entry of due) {
        try {
          await repository.withCapture(entry.id, async (tx) => {
            const deleted = await tx.getDeleted();
            if (!deleted || deleted.cleanupAfter > time) return;
            await storage.delete(deleted.objectKey);
            await tx.markCleaned(time);
          });
        } catch {
          // Keep its tombstone due. A later authenticated request retries cleanup.
          // Never log provider errors, which may contain signed URLs or credentials.
        }
      }
    },
  };
}
