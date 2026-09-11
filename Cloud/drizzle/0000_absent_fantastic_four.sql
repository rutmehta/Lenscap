CREATE TYPE "public"."lenscap_capture_content_type" AS ENUM('image/png', 'image/jpeg', 'image/gif', 'video/mp4');--> statement-breakpoint
CREATE TYPE "public"."lenscap_capture_kind" AS ENUM('screenshot', 'video', 'gif');--> statement-breakpoint
CREATE TYPE "public"."lenscap_capture_status" AS ENUM('pending', 'uploaded');--> statement-breakpoint
CREATE TABLE "lenscap_captures" (
	"id" uuid PRIMARY KEY NOT NULL,
	"filename" text NOT NULL,
	"kind" "lenscap_capture_kind" NOT NULL,
	"content_type" "lenscap_capture_content_type" NOT NULL,
	"byte_count" bigint NOT NULL,
	"sha256" text NOT NULL,
	"created_at" timestamp (3) with time zone NOT NULL,
	"uploaded_at" timestamp (3) with time zone,
	"status" "lenscap_capture_status" DEFAULT 'pending' NOT NULL,
	"object_key" text NOT NULL,
	"upload_expires_at" timestamp (3) with time zone NOT NULL,
	CONSTRAINT "lenscap_captures_object_key_unique" UNIQUE("object_key"),
	CONSTRAINT "lenscap_capture_bytes" CHECK ("lenscap_captures"."byte_count" > 0 AND "lenscap_captures"."byte_count" <= 5368709120),
	CONSTRAINT "lenscap_capture_hash" CHECK ("lenscap_captures"."sha256" ~ '^[a-f0-9]{64}$'),
	CONSTRAINT "lenscap_capture_filename" CHECK (octet_length("lenscap_captures"."filename") BETWEEN 1 AND 255),
	CONSTRAINT "lenscap_capture_published" CHECK (("lenscap_captures"."status" = 'pending' AND "lenscap_captures"."uploaded_at" IS NULL) OR ("lenscap_captures"."status" = 'uploaded' AND "lenscap_captures"."uploaded_at" IS NOT NULL)),
	CONSTRAINT "lenscap_capture_media" CHECK (("lenscap_captures"."kind" = 'screenshot' AND "lenscap_captures"."content_type" IN ('image/png', 'image/jpeg')) OR ("lenscap_captures"."kind" = 'video' AND "lenscap_captures"."content_type" = 'video/mp4') OR ("lenscap_captures"."kind" = 'gif' AND "lenscap_captures"."content_type" = 'image/gif'))
);
--> statement-breakpoint
CREATE TABLE "lenscap_deleted_captures" (
	"id" uuid PRIMARY KEY NOT NULL,
	"object_key" text NOT NULL,
	"deleted_at" timestamp (3) with time zone NOT NULL,
	"cleanup_after" timestamp (3) with time zone NOT NULL,
	"last_cleanup_at" timestamp (3) with time zone
);
--> statement-breakpoint
CREATE INDEX "lenscap_captures_library_idx" ON "lenscap_captures" USING btree ("status","created_at" DESC NULLS LAST,"id" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "lenscap_deleted_cleanup_idx" ON "lenscap_deleted_captures" USING btree ("cleanup_after","last_cleanup_at");