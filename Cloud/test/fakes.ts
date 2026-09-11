import type { CaptureRecord, CaptureRepository, CaptureStorage, CaptureTransaction, DeletedCapture, ListOptions, ObjectInfo } from "../src/contracts.js";

export class MemoryRepository implements CaptureRepository {
  records = new Map<string, CaptureRecord>();
  deleted = new Map<string, DeletedCapture>();
  bytes = 8_192;
  private tail: Promise<unknown> = Promise.resolve();

  async withCapture<T>(id: string, operation: (tx: CaptureTransaction) => Promise<T>): Promise<T> {
    const result = this.tail.then(async () => {
      const savedRecords = structuredClone(this.records);
      const savedDeleted = structuredClone(this.deleted);
      const tx: CaptureTransaction = {
        get: async () => structuredClone(this.records.get(id) ?? null),
        getDeleted: async () => structuredClone(this.deleted.get(id) ?? null),
        databaseBytes: async () => this.bytes,
        insert: async (record) => { this.records.set(id, structuredClone(record)); },
        update: async (record) => { this.records.set(id, structuredClone(record)); },
        remove: async (tombstone) => { this.records.delete(id); this.deleted.set(id, structuredClone(tombstone)); },
        markCleaned: async (at) => { this.deleted.get(id)!.lastCleanupAt = at; },
      };
      try { return await operation(tx); } catch (error) {
        this.records = savedRecords;
        this.deleted = savedDeleted;
        throw error;
      }
    });
    this.tail = result.catch(() => {});
    return result;
  }

  async list({ limit, cursor }: ListOptions) {
    return [...this.records.values()]
      .filter((record) => record.status === "uploaded" && (!cursor || record.createdAt < cursor.createdAt || (record.createdAt === cursor.createdAt && record.id < cursor.id)))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id))
      .slice(0, limit);
  }

  async usage() {
    const uploaded = [...this.records.values()].filter((row) => row.status === "uploaded");
    return { captureCount: uploaded.length, storageBytes: uploaded.reduce((sum, row) => sum + row.byteCount, 0), pendingUploadCount: this.records.size - uploaded.length };
  }
  async databaseBytes() { return this.bytes; }
  async deletionsDue(at: string, limit: number) {
    const rescanBefore = new Date(Date.parse(at) - 24 * 60 * 60 * 1000).toISOString();
    return [...this.deleted.values()].filter((row) => row.cleanupAfter <= at && (row.lastCleanupAt === null || row.lastCleanupAt <= rescanBefore)).slice(0, limit);
  }
}

export class MemoryStorage implements CaptureStorage {
  objects = new Map<string, ObjectInfo>();
  uploadGrants: { capture: CaptureRecord; seconds: number }[] = [];
  downloadGrants: { capture: CaptureRecord; seconds: number }[] = [];
  failDelete = false;

  async signUpload(capture: CaptureRecord, seconds: number) {
    this.uploadGrants.push({ capture: structuredClone(capture), seconds });
    return { url: `https://storage.invalid/lenscap/${capture.objectKey}?upload=signed`, method: "PUT" as const, headers: { "Content-Type": capture.contentType } };
  }
  async head(key: string) { return this.objects.get(key) ?? null; }
  async signDownload(capture: CaptureRecord, seconds: number) {
    this.downloadGrants.push({ capture: structuredClone(capture), seconds });
    return `https://storage.invalid/lenscap/${capture.objectKey}?download=signed&ttl=${seconds}`;
  }
  async delete(key: string) {
    if (this.failDelete) throw new Error("storage network unavailable");
    this.objects.delete(key);
  }
  put(capture: CaptureRecord, patch: Partial<ObjectInfo> = {}) {
    this.objects.set(capture.objectKey, {
      byteCount: capture.byteCount,
      contentType: capture.contentType,
      metadata: { "capture-id": capture.id, sha256: capture.sha256, kind: capture.kind },
      ...patch,
    });
  }
}
