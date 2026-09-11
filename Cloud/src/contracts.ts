export type CaptureKind = "screenshot" | "video" | "gif";
export type CaptureContentType = "image/png" | "image/jpeg" | "image/gif" | "video/mp4";

export interface UploadInput {
  id: string;
  filename: string;
  kind: CaptureKind;
  contentType: CaptureContentType;
  byteCount: number;
  sha256: string;
  createdAt: string;
}

export interface Capture extends UploadInput {
  uploadedAt: string | null;
  status: "pending" | "uploaded";
}

export interface CaptureRecord extends Capture {
  objectKey: string;
  uploadExpiresAt: string;
}

export interface DeletedCapture {
  id: string;
  objectKey: string;
  deletedAt: string;
  cleanupAfter: string;
  lastCleanupAt: string | null;
}

export interface UploadGrant {
  url: string;
  method: "PUT";
  headers: Record<string, string>;
}

export interface UploadResponse {
  capture: Capture;
  alreadyUploaded: boolean;
  upload?: UploadGrant;
}

export interface CaptureCursor {
  createdAt: string;
  id: string;
}

export interface ListOptions {
  limit: number;
  cursor?: CaptureCursor;
}

export interface CaptureTransaction {
  get(): Promise<CaptureRecord | null>;
  getDeleted(): Promise<DeletedCapture | null>;
  databaseBytes(): Promise<number>;
  insert(record: CaptureRecord): Promise<void>;
  update(record: CaptureRecord): Promise<void>;
  remove(tombstone: DeletedCapture): Promise<void>;
  markCleaned(at: string): Promise<void>;
}

export interface CaptureRepository {
  withCapture<T>(id: string, operation: (tx: CaptureTransaction) => Promise<T>): Promise<T>;
  list(options: ListOptions): Promise<CaptureRecord[]>;
  usage(): Promise<{ captureCount: number; storageBytes: number; pendingUploadCount: number }>;
  databaseBytes(): Promise<number>;
  deletionsDue(at: string, limit: number): Promise<DeletedCapture[]>;
}

export interface ObjectInfo {
  byteCount: number;
  contentType: string | undefined;
  metadata: Record<string, string>;
}

export interface CaptureStorage {
  signUpload(capture: CaptureRecord, expiresIn: number): Promise<UploadGrant>;
  head(key: string): Promise<ObjectInfo | null>;
  signDownload(capture: CaptureRecord, expiresIn: number): Promise<string>;
  delete(key: string): Promise<void>;
}

export interface CloudAPI {
  createUpload(input: UploadInput): Promise<UploadResponse>;
  completeUpload(id: string): Promise<{ capture: Capture }>;
  listCaptures(options: ListOptions): Promise<{ captures: Capture[]; nextCursor: string | null }>;
  download(id: string): Promise<{ url: string; expiresAt: string }>;
  share(id: string): Promise<{ url: string; expiresAt: string }>;
  usage(): Promise<{
    captureCount: number;
    storageBytes: number;
    pendingUploadCount: number;
    databaseBytes: number;
    limits: { databaseBytes: number; maxFileBytes: number; objectStorageBytes: number; objectStorageScope: "account" };
    provider: "Neon";
    plan: "free";
    beta: true;
  }>;
  deleteCapture(id: string): Promise<void>;
  cleanupDeleted(): Promise<void>;
}
