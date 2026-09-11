import { S3Client } from "@aws-sdk/client-s3";
import { attachDatabasePool } from "@neon/functions";
import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import { parseRuntimeConfig } from "./config.js";
import { createCaptureRepository } from "./db/repository.js";
import * as schema from "./db/schema.js";
import { createCloudService } from "./service.js";
import { createS3Storage } from "./storage.js";

export function createRuntimeService(environment: Record<string, string | undefined>) {
  const config = parseRuntimeConfig(environment);
  const pool = new pg.Pool({
    connectionString: config.databaseUrl, max: 5,
    connectionTimeoutMillis: 10_000, idleTimeoutMillis: 30_000, query_timeout: 20_000,
  });
  attachDatabasePool(pool, {
    // Provider errors can include connection strings. Never log them verbatim.
    onUnexpectedError: () => { console.error("Cloud database connection failed."); },
  });
  const storageClient = new S3Client({
    endpoint: config.storageEndpoint, region: config.storageRegion, forcePathStyle: true,
    credentials: { accessKeyId: config.storageAccessKeyId, secretAccessKey: config.storageSecretAccessKey },
    // Presigning has no Body. An automatic checksum would describe an empty body.
    requestChecksumCalculation: "WHEN_REQUIRED", responseChecksumValidation: "WHEN_REQUIRED",
  });
  return createCloudService({
    repository: createCaptureRepository(drizzle(pool, { schema })),
    storage: createS3Storage(storageClient),
  });
}
