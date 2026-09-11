import { z } from "zod";
import type { CaptureCursor, ListOptions, UploadInput } from "./contracts.js";
import { invalidRequest } from "./errors.js";
import { MAX_FILE_BYTES } from "./limits.js";

const uuid = z.uuid().transform((value) => value.toLowerCase());
const dateTime = z.iso.datetime({ offset: true }).transform((value) => new Date(value).toISOString());

const uploadSchema = z.object({
  id: uuid,
  filename: z.string().min(1).refine((value) =>
    value.trim().length > 0 && Buffer.byteLength(value, "utf8") <= 255 &&
    value !== "." && value !== ".." && !/[\\/\u0000-\u001f\u007f]/.test(value)),
  kind: z.enum(["screenshot", "video", "gif"]),
  contentType: z.enum(["image/png", "image/jpeg", "image/gif", "video/mp4"]),
  byteCount: z.number().int().min(1).max(MAX_FILE_BYTES),
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
  createdAt: dateTime,
}).strict().refine((value) => (
  (value.kind === "screenshot" && ["image/png", "image/jpeg"].includes(value.contentType)) ||
  (value.kind === "gif" && value.contentType === "image/gif") ||
  (value.kind === "video" && value.contentType === "video/mp4")
));

export function parseUpload(value: unknown): UploadInput {
  const result = uploadSchema.safeParse(value);
  if (!result.success) throw invalidRequest();
  return result.data;
}

export function parseID(value: string): string {
  const result = uuid.safeParse(value);
  if (!result.success) throw invalidRequest();
  return result.data;
}

const cursorSchema = z.object({ v: z.literal(1), id: uuid, createdAt: dateTime }).strict();

export function encodeCursor(cursor: CaptureCursor): string {
  return Buffer.from(JSON.stringify({ v: 1, createdAt: cursor.createdAt, id: cursor.id })).toString("base64url");
}

export function parseListOptions(url: URL): ListOptions {
  if (url.searchParams.getAll("limit").length > 1 || url.searchParams.getAll("cursor").length > 1) throw invalidRequest();
  const rawLimit = url.searchParams.get("limit") ?? "50";
  if (!/^[1-9][0-9]{0,2}$/.test(rawLimit)) throw invalidRequest();
  const limit = Number(rawLimit);
  if (limit > 100) throw invalidRequest();
  const rawCursor = url.searchParams.get("cursor");
  if (rawCursor === null) return { limit };
  if (rawCursor.length > 512 || !/^[A-Za-z0-9_-]+$/.test(rawCursor)) throw invalidRequest();
  try {
    const parsed = cursorSchema.parse(JSON.parse(Buffer.from(rawCursor, "base64url").toString("utf8")));
    return { limit, cursor: { createdAt: parsed.createdAt, id: parsed.id } };
  } catch {
    throw invalidRequest();
  }
}
