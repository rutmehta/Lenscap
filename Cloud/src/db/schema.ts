import { sql } from "drizzle-orm";
import { bigint, check, index, pgEnum, pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core";

export const captureKind = pgEnum("lenscap_capture_kind", ["screenshot", "video", "gif"]);
export const captureContentType = pgEnum("lenscap_capture_content_type", ["image/png", "image/jpeg", "image/gif", "video/mp4"]);
export const captureStatus = pgEnum("lenscap_capture_status", ["pending", "uploaded"]);

export const captures = pgTable("lenscap_captures", {
  id: uuid("id").primaryKey(),
  filename: text("filename").notNull(),
  kind: captureKind("kind").notNull(),
  contentType: captureContentType("content_type").notNull(),
  byteCount: bigint("byte_count", { mode: "number" }).notNull(),
  sha256: text("sha256").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true, precision: 3 }).notNull(),
  uploadedAt: timestamp("uploaded_at", { withTimezone: true, precision: 3 }),
  status: captureStatus("status").notNull().default("pending"),
  objectKey: text("object_key").notNull().unique(),
  uploadExpiresAt: timestamp("upload_expires_at", { withTimezone: true, precision: 3 }).notNull(),
}, (table) => [
  index("lenscap_captures_library_idx").on(table.status, table.createdAt.desc(), table.id.desc()),
  check("lenscap_capture_bytes", sql`${table.byteCount} > 0 AND ${table.byteCount} <= 5368709120`),
  check("lenscap_capture_hash", sql`${table.sha256} ~ '^[a-f0-9]{64}$'`),
  check("lenscap_capture_filename", sql`octet_length(${table.filename}) BETWEEN 1 AND 255`),
  check("lenscap_capture_published", sql`(${table.status} = 'pending' AND ${table.uploadedAt} IS NULL) OR (${table.status} = 'uploaded' AND ${table.uploadedAt} IS NOT NULL)`),
  check("lenscap_capture_media", sql`(${table.kind} = 'screenshot' AND ${table.contentType} IN ('image/png', 'image/jpeg')) OR (${table.kind} = 'video' AND ${table.contentType} = 'video/mp4') OR (${table.kind} = 'gif' AND ${table.contentType} = 'image/gif')`),
]);

// Tombstones prevent a delayed retry from resurrecting a deliberately deleted id.
// No capture bytes or filename are retained here.
export const deletedCaptures = pgTable("lenscap_deleted_captures", {
  id: uuid("id").primaryKey(),
  objectKey: text("object_key").notNull(),
  deletedAt: timestamp("deleted_at", { withTimezone: true, precision: 3 }).notNull(),
  cleanupAfter: timestamp("cleanup_after", { withTimezone: true, precision: 3 }).notNull(),
  lastCleanupAt: timestamp("last_cleanup_at", { withTimezone: true, precision: 3 }),
}, (table) => [index("lenscap_deleted_cleanup_idx").on(table.cleanupAfter, table.lastCleanupAt)]);
