# Personal cloud

Lenscap's personal cloud stores new screenshots, videos, and GIFs in a private Neon Object Storage bucket, with a Postgres index and an authenticated HTTP API. It is intended for one person's devices, not multiple unrelated users. There is no Lenscap-operated backend: you deploy this function to your own Neon project, under your own account, and the app never ships with a Neon key or any other provider credential. The native app owns capture creation, the local retry queue, and consent to automatic uploads. The backend never scans a Mac or imports historical files.

Captures have no automatic expiry. Deleting a capture removes its cloud copy and library entry in the current Neon branch, not the original local file. Quitting or uninstalling the app does not delete existing cloud captures or revoke previously issued links. Keep local originals; this beta service is not a replacement for a backup.

## Open the library

Click the Lenscap menu-bar icon normally to open its native menu, then choose **Cloud Library** directly or **Settings… → Cloud → Open Cloud Library…**. The same menu offers **Check for Updates…** and capture commands.

If the icon is hidden, reopen **Lenscap** from Applications or Spotlight. When no Lenscap windows are visible, reopening shows the capture-controls window titled **Lenscap**. Choose its explicit **Settings** button, then **Cloud → Open Cloud Library…**. Reopening never automatically opens Settings and leaves any already-visible window in place. Starting a capture hides Settings and the capture controls before activating the capture UI; neither window is automatically restored afterward.

The library's **New Capture** menu starts a new screenshot or recording. If Cloud is not connected yet, Settings shows **Import Connection…** instead; connection files contain a private device token and must not be committed or shared.

Once connected, all new normal screenshots, finalized videos, GIFs, and explicitly saved image edits upload automatically. Existing history is not scanned or backfilled. OCR-only selections, clipboard copies, and temporary drag files do not create cloud captures. A saved edit is a separate cloud version; it does not replace or redact an earlier upload. Automatic cloud uploads can run even when automatic local screenshot saving is disabled, so keep a separate local copy if you need one.

## Verified private build

**Historical 1.1.0 verification record.** The results below were recorded on a pre-release 1.1.0 build; they do not re-verify the 1.1.1 and 1.1.2 menu or Settings changes.

A privately installed **1.1.0** build successfully uploaded an actual PNG screenshot, MP4 recording, and GIF recording to the main backend; that verification run showed **3 captures, approximately 10.2 MB**. Each downloaded file matched its local original by SHA-256, and the MP4 and GIF parsed successfully with their expected codecs and frame counts. That verification build was a private, non-notarized build. The cloud feature ships publicly starting with 1.1.2.

Live development and main checks passed authentication and private object access, conditional PUT replay rejection (`412`), downloaded-body SHA-256 comparisons against fixtures, inline media responses, explicit shares, and deletion cleanup. These are verification results for those deployments, not a promise of future provider behavior or proof that HEAD independently verifies a payload checksum. The integrity and deletion limitations below still apply.

The Free Object Storage allowance is **5 GB shared across the Neon account**, not per project. Lenscap does not automatically upgrade to a paid plan. The library's byte count covers Lenscap captures only and cannot show remaining capacity across other projects.

## Components and access

`Cloud/neon.ts` declares one private bucket, `lenscap`, and one Neon Function with slug `lenscap`. `Cloud/src/index.ts` exports the Hono app. There is no hosted frontend, public bucket, anonymous library, or unauthenticated upload route.

The function uses Drizzle with a small, persistent `pg.Pool` and Neon's injected branch credentials. Database and S3 clients are created lazily after authentication. All routes except `GET /health` require:

```http
Authorization: Bearer <device-token>
```

The server stores only `LENSCAP_DEVICE_TOKEN_SHA256`, a lowercase SHA-256 digest of a high-entropy device token. It hashes the supplied token and uses a constant-time comparison. A missing or malformed configured digest fails closed. The same token grants full access to this personal library; there are no user accounts or separate reader permissions. Use different tokens for development and main.

Keep the raw device token in the native client's Keychain. Never embed it or provider credentials in source, the app bundle, a URL, logs, screenshots, or a committed environment file. Neon supplies `DATABASE_URL`, `DATABASE_URL_UNPOOLED`, `AWS_ENDPOINT_URL_S3`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` on the server. Only the token digest is an application deployment variable. Provider credentials are not returned to the native app; presigned URLs contain the normal public signing identifier and a temporary signature, not the signing secret.

Storage endpoints must use HTTPS. Both pooled runtime and direct migration database URLs are normalized to `sslmode=verify-full`, including certificate and hostname verification. The current storage region is Ohio, `us-east-2`. Browser CORS access to the API is not enabled; the native client uses bearer authentication directly.

Files are private at the bucket level, but are not encrypted end to end with a device-only key. The account owner and provider can access stored data. Anyone holding a presigned read URL can read that one object until the URL expires or the object becomes unavailable. Treat links as sensitive.

## Upload protocol

1. The native client finalizes a local file, computes its SHA-256, and retains a stable UUID and immutable metadata for retries. It should verify that the spool file still matches its size and hash before sending it.
2. `POST /v1/uploads` reserves metadata and returns a 15-minute presigned `PUT`. The object key is generated by the server and cannot be supplied by the client.
3. The client sends the file directly to S3 using **all returned headers exactly**. No file bytes pass through the Function.
4. On a successful PUT, call `POST /v1/uploads/:id/complete`. If the PUT response is lost, reserve again with identical metadata; if PUT returns `412 Precondition Failed`, also call complete. The existing object is validated before the row can become visible.
5. Completion checks S3 HEAD content length, content type, and signed custom metadata, then marks the row uploaded. Pending captures never appear in the library. Do not remove the local retry item merely because PUT returned success.

The PUT signature binds `Content-Type`, `Content-Length`, `Content-Disposition`, `Cache-Control`, `If-None-Match: *`, and `x-amz-meta-capture-id`, `x-amz-meta-sha256`, `x-amz-meta-kind`. Content disposition is stored as `inline` with a safe filename so images and videos can open in a browser. GET response-header overrides are not required; Neon did not apply the disposition override during development probes. `Cache-Control: private, no-store` discourages caches but cannot recall copies someone already saved.

Conditional PUT prevents an existing object at the same key from being overwritten. Keep the UUID, filename, kind, type, size, hash, and capture time identical on a retry. Any difference for an existing UUID returns `409 capture_conflict`. A completed matching reservation returns `alreadyUploaded: true` without another PUT. Completion can be repeated without changing `uploadedAt`.

**Integrity boundary:** `sha256` is currently a client-supplied value bound into the signed metadata. HEAD verifies that metadata; it does not independently hash the object body. The backend does not claim to detect same-length byte corruption when matching metadata was supplied. The AWS SDK is configured with `requestChecksumCalculation: "WHEN_REQUIRED"` so presigning without a body does not accidentally sign an empty-body CRC checksum. Adding provider-validated `ChecksumSHA256` requires an explicit Neon compatibility test. Until then, clients must retain local originals and hash their immutable spool before upload; a download can be independently hashed against the original.

Missing or mismatched objects remain unpublished. A malformed/mismatched existing object cannot be overwritten by another conditional PUT: delete that cloud reservation and retry as a new capture UUID after retaining the local file. A deleted UUID returns `410 capture_deleted` rather than silently recreating it.

## HTTP contract, v1

Capture metadata:

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "filename": "Capture.png",
  "kind": "screenshot",
  "contentType": "image/png",
  "byteCount": 12345,
  "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "createdAt": "2026-08-27T12:00:00.000Z",
  "uploadedAt": null,
  "status": "pending"
}
```

Upload requests contain only the first seven fields. `uploadedAt` and `status` are server-owned. UUIDs normalize to lowercase and timestamps to UTC with millisecond precision. Filenames must be nonempty, at most 255 UTF-8 bytes, and contain no path separators or control characters. Metadata bodies are limited to 16 KiB. Accepted kind/type pairs are screenshot with PNG or JPEG, video with MP4, and GIF with GIF. Other MIME types, zero-byte files, noninteger sizes, invalid timestamps, unknown request fields, and non-lowercase hashes are rejected.

| Method and path | Result |
| --- | --- |
| `GET /health` | Public `{ "ok": true }`; no database or storage access. |
| `POST /v1/uploads` | `{capture, alreadyUploaded, upload?}`; `upload` contains `{url, method:"PUT", headers}`. |
| `POST /v1/uploads/:id/complete` | `{capture}` after HEAD validation. |
| `GET /v1/captures?limit=50&cursor=…` | `{captures, nextCursor}`; uploaded only; limit 1–100. |
| `GET /v1/captures/:id/download` | `{url, expiresAt}` for a 5-minute signed GET. |
| `POST /v1/captures/:id/share` | `{url, expiresAt}` for an explicitly requested 7-day signed GET. |
| `GET /v1/usage` | Library and database usage with published plan limits below. |
| `DELETE /v1/captures/:id` | `204` without a body, including repeated deletion or an unknown UUID. |

The library sorts by `createdAt` descending and UUID descending as a stable tie-breaker. Treat the cursor as opaque and URL-encode it. `nextCursor` is `null` at the end. Pages are not a database snapshot: a newly completed capture whose capture time precedes a cursor can appear on a later page, and refreshing from the first page is appropriate after uploads or deletes.

Read links are minted only on the download/share routes, never as an upload side effect. `expiresAt` is server time; client clock skew can make a local countdown differ. The signed URL includes the authoritative signing time and expiry duration. Share links are the signed URLs themselves, with no redirect page, password, custom short domain, or per-link revoke endpoint.

Errors use:

```json
{"error":{"code":"upload_missing","message":"The cloud object is missing. Keep the local file and retry the upload."}}
```

Important statuses are `400 invalid_request`, `401 unauthorized`, `404 capture_not_found`/`object_missing`, `409 capture_conflict`/`upload_pending`/`upload_missing`/`upload_mismatch`, `410 capture_deleted`, `413 request_too_large`, `415 unsupported_media_type`, `503 configuration_error`/`storage_unavailable`, and `507 database_quota_exceeded`/`storage_quota_exceeded`. Unexpected failures return a generic error without SQL, connection strings, signed URLs, or provider details. Direct S3 PUT failures are provider HTTP responses, not this JSON envelope. Preserve the queue on network, quota, and provider failures, and use bounded retries with backoff.

## Deletion and previously shared links

Deletion removes the current cloud object and metadata row under an advisory transaction lock. A storage error rolls back the row deletion, preserving a retry target. If storage deletion succeeds but a later database commit fails, the remaining row can point at a missing object; retrying DELETE repairs that state. Download/share then report the missing object instead of generating a misleading link.

A small tombstone retains only the deleted UUID, internal object key, and cleanup times. It prevents delayed retries from resurrecting a deleted capture. Tombstones retain no filename or file contents and are not expired automatically.

**Deletion is not an immediate revocation guarantee for issued links.** An already-issued PUT URL cannot be revoked individually. A PUT that is still valid, or an in-flight transfer, can recreate an object after DELETE; an existing signed GET may then read it. The API never republishes that UUID. A later authenticated request removes due tombstoned objects after the latest tracked upload window, up to ten per request. Old tombstones are rescanned no more than once per day to catch very late writes. Cleanup failures remain eligible for retry. Calling complete or DELETE for that tombstone also attempts to remove a late object.

There is no background cleanup scheduler. If no later authenticated request occurs, cleanup may not run, and a late object can remain stored. Previously downloaded/cached copies, other Neon branches, and provider backups are outside this endpoint's deletion scope. Do not promise instant link revocation or secure erasure. Rotating the device token prevents new API requests with the old token but does not revoke existing S3 signatures.

## Free plan and usage

The application never changes the Neon billing plan, automatically upgrades an account, or deletes captures to make room. It surfaces errors and leaves local retries to the client. Neon's beta terms and allowances can change; check the account console before relying on capacity.

Neon currently documents **5 GB of Object Storage across the entire account**, not per project, and a **5 GiB maximum single object**. The API represents the published decimal 5 GB allowance as `5000000000` bytes and the explicit 5 GiB object maximum as `5368709120` bytes. The provider is authoritative about enforcement; the documentation does not define a more precise billing calculation. A maximum-size object can exceed the account's free allowance even in an otherwise empty account. [Object Storage limits](https://neon.com/docs/storage/overview), [object size limit](https://neon.com/docs/storage/objects).

Example usage response:

```json
{
  "captureCount": 12,
  "storageBytes": 4567890,
  "pendingUploadCount": 1,
  "databaseBytes": 8388608,
  "limits": {
    "databaseBytes": 536870912,
    "maxFileBytes": 5368709120,
    "objectStorageBytes": 5000000000,
    "objectStorageScope": "account"
  },
  "provider": "Neon",
  "plan": "free",
  "beta": true
}
```

`captureCount` and `storageBytes` sum completed captures in this library only. They exclude pending objects, late deleted objects, other branches, and other projects. They are not a physical storage audit or an account-wide usage reading. **Do not subtract them from 5 GB to display remaining account storage.** The native UI should label Lenscap usage separately from the shared account allowance. The backend does not invent or enforce a separate 5 GB project cap.

`databaseBytes` uses `pg_database_size(current_database())`. The application guardrail is 512 MiB (`536870912` bytes); it rejects new reservations at that size while permitting existing retry paths. Neon publishes a Free database storage allowance of 0.5 GB per project and enforces its own limits, which can fail earlier and include resources beyond this one database. Deleting rows may not immediately reduce PostgreSQL allocated file size. Provider capacity and throttling errors should keep local files and queue items intact. [Neon plans](https://neon.com/docs/introduction/plans).

## Development, migrations, and deployment

Use Node 22 or newer for local checks; Neon Functions run Node 24. Install dependencies from the committed lockfile. Tests use fake storage and PGlite, with no live provider access or deployment secrets:

```sh
cd Cloud
npm ci --ignore-scripts
npm run check
npm audit
```

Schema lives in `Cloud/src/db/schema.ts`; committed SQL and Drizzle journal/snapshots live in `Cloud/drizzle/`. To change it, edit the schema, run `npm run db:generate`, review the generated SQL, run tests, and apply the migration to development first. Never modify an already-applied migration. No schema changes run during a Function request or cold start.

Migrations require an explicitly supplied **direct** `DATABASE_URL_UNPOOLED`. They reject a Neon `-pooler` host and never fall back to `DATABASE_URL`. With a private mode-0600 environment file containing the direct URL, run from `Cloud`:

```sh
node --env-file=/absolute/private/provider.env --import tsx scripts/migrate.ts
```

Or inject `DATABASE_URL_UNPOOLED` through a secret manager and run `npm run db:migrate`. Do not paste credentials into a command line, shell history, committed `.env`, or tool output. Migration failures print a redacted diagnostic; inspect private provider logs locally when more detail is necessary.

Link the Neon CLI to a dedicated Free Ohio project and explicitly select its development branch before deploying. The deployment environment file contains only `LENSCAP_DEVICE_TOKEN_SHA256`; do not overwrite the injected provider credentials in `neon.ts`. From `Cloud`, with the intended CLI project and branch already selected:

```sh
neon deploy --config neon.ts --env /absolute/private/development.env --no-env-pull
```

The config has no branch expiry, lifecycle deletion rule, paid-plan selection, or explicit compute suspend-timeout setting. Keep development and main deployment files separate. The CLI may otherwise write pulled secrets to disk, which is why the command explicitly uses `--no-env-pull`. For local Function development, `npm run dev` uses the selected Neon branch; it is not automatically an isolated throwaway database. [Config as code](https://neon.com/docs/reference/neon-ts), [Function environment variables](https://neon.com/docs/compute/functions/environment-variables).

Before changing the native endpoint to a deployment, verify using synthetic fixtures, then remove those fixtures:

1. `/health` succeeds without provider access; every data route rejects absent/wrong tokens.
2. PNG, JPEG, GIF, and MP4 upload and complete; downloads have identical bytes to the fixture, inline disposition, and the requested content type.
3. An unsigned object GET fails; a signed GET works only for its intended object.
4. Replaying a PUT to an existing key returns 412, including an altered same-length body. Retrying complete and reserving completed metadata are idempotent.
5. Metadata mismatches are rejected; missing objects never become visible. Test concurrent reservations for the same UUID in the deployed environment.
6. Share is explicit and signs a seven-day GET. Allow clock skew when comparing local time with `expiresAt`; check `X-Amz-Expires=604800` directly.
7. Pagination is complete and pending rows are absent. Usage is labeled as library usage and shared account allowance.
8. Delete is idempotent; late PUTs cannot republish a deleted UUID; later authenticated cleanup removes recreated bytes. Do not mistake this for immediate URL revocation.

Unit and integration tests cover auth ordering, validation, metadata conflicts, completion/retry state, pagination, quota guards, deletion rollback/cleanup, real SQL migrations and queries, safe error handling, TLS configuration, and AWS SDK signature construction. They cannot prove Neon's live S3 semantics, global quota behavior, or simultaneous database transactions across Function isolates. Repeat the live checks after provider or SDK changes. [S3 compatibility](https://neon.com/docs/storage/s3-compatibility).
