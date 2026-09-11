import { APIError } from "./errors.js";

export interface RuntimeConfig {
  databaseUrl: string;
  storageEndpoint: string;
  storageRegion: string;
  storageAccessKeyId: string;
  storageSecretAccessKey: string;
}

function postgresURL(value: string | undefined): URL | null {
  try {
    const url = new URL(value ?? "");
    return ["postgres:", "postgresql:"].includes(url.protocol) && url.hostname && url.pathname.length > 1 ? url : null;
  } catch { return null; }
}

function verifiedConnectionString(url: URL): string {
  // Explicitly preserve certificate and hostname verification across pg releases.
  url.searchParams.set("sslmode", "verify-full");
  return url.toString();
}

export function parseRuntimeConfig(environment: Record<string, string | undefined>): RuntimeConfig {
  const invalid = () => new APIError(503, "configuration_error", "Cloud database or storage is not configured.");
  const databaseUrl = postgresURL(environment.DATABASE_URL);
  if (!databaseUrl) throw invalid();
  let storageEndpoint: URL;
  try { storageEndpoint = new URL(environment.AWS_ENDPOINT_URL_S3 ?? ""); }
  catch { throw invalid(); }
  if (storageEndpoint.protocol !== "https:" || storageEndpoint.username || storageEndpoint.password ||
      storageEndpoint.search || storageEndpoint.hash || environment.AWS_REGION !== "us-east-2" ||
      !environment.AWS_ACCESS_KEY_ID?.trim() || !environment.AWS_SECRET_ACCESS_KEY?.trim()) throw invalid();
  return {
    databaseUrl: verifiedConnectionString(databaseUrl), storageEndpoint: storageEndpoint.toString(),
    storageRegion: environment.AWS_REGION, storageAccessKeyId: environment.AWS_ACCESS_KEY_ID,
    storageSecretAccessKey: environment.AWS_SECRET_ACCESS_KEY,
  };
}

export function migrationConnectionString(environment: Record<string, string | undefined>): string {
  const url = postgresURL(environment.DATABASE_URL_UNPOOLED);
  if (!url || /-pooler(?:\.|$)/i.test(url.hostname)) {
    throw new Error("Use DATABASE_URL_UNPOOLED with a direct Postgres connection for migrations.");
  }
  return verifiedConnectionString(url);
}
