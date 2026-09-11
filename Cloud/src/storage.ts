import { DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, PutObjectCommand, type S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import type { CaptureStorage } from "./contracts.js";
import { APIError } from "./errors.js";

const BUCKET = "lenscap";

function missing(error: unknown): boolean {
  const value = error as { name?: string; $metadata?: { httpStatusCode?: number } };
  return value?.$metadata?.httpStatusCode === 404 || value?.name === "NotFound" || value?.name === "NoSuchKey";
}

function storageError(error: unknown): APIError {
  const value = error as { name?: string; $metadata?: { httpStatusCode?: number } };
  if (value?.$metadata?.httpStatusCode === 507 || /Quota|InsufficientStorage/.test(value?.name ?? "")) {
    return new APIError(507, "storage_quota_exceeded", "Neon's free 5 GB Object Storage allowance is shared across your account. Free space before retrying.");
  }
  return new APIError(503, "storage_unavailable", "Cloud storage is temporarily unavailable. Keep local files and retry.");
}

function disposition(filename: string): string {
  const fallback = filename.replace(/[^\x20-\x7e]|["\\]/g, "_");
  const encoded = encodeURIComponent(filename).replace(/[!'()*]/g, (value) => `%${value.charCodeAt(0).toString(16).toUpperCase()}`);
  return `inline; filename="${fallback}"; filename*=UTF-8''${encoded}`;
}

export function createS3Storage(client: S3Client): CaptureStorage {
  return {
    async signUpload(capture, expiresIn) {
      const headers = {
        "Content-Type": capture.contentType,
        "Content-Length": String(capture.byteCount),
        "Content-Disposition": disposition(capture.filename),
        "Cache-Control": "private, no-store",
        "If-None-Match": "*",
        "x-amz-meta-capture-id": capture.id,
        "x-amz-meta-sha256": capture.sha256,
        "x-amz-meta-kind": capture.kind,
      };
      try {
        const url = await getSignedUrl(client, new PutObjectCommand({
          Bucket: BUCKET, Key: capture.objectKey,
          ContentType: capture.contentType, ContentLength: capture.byteCount,
          ContentDisposition: headers["Content-Disposition"], CacheControl: headers["Cache-Control"],
          IfNoneMatch: "*",
          Metadata: { "capture-id": capture.id, sha256: capture.sha256, kind: capture.kind },
        }), {
          expiresIn,
          signableHeaders: new Set(Object.keys(headers).map((name) => name.toLowerCase())),
          unhoistableHeaders: new Set(["x-amz-meta-capture-id", "x-amz-meta-sha256", "x-amz-meta-kind"]),
        });
        return { url, method: "PUT", headers };
      } catch (error) { throw storageError(error); }
    },

    async signDownload(capture, expiresIn) {
      try {
        return await getSignedUrl(client, new GetObjectCommand({ Bucket: BUCKET, Key: capture.objectKey }), { expiresIn });
      } catch (error) { throw storageError(error); }
    },

    async head(key) {
      try {
        const object = await client.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }));
        return { byteCount: object.ContentLength ?? -1, contentType: object.ContentType, metadata: object.Metadata ?? {} };
      } catch (error) {
        if (missing(error)) return null;
        throw storageError(error);
      }
    },

    async delete(key) {
      try { await client.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: key })); }
      catch (error) { if (!missing(error)) throw storageError(error); }
    },
  };
}
