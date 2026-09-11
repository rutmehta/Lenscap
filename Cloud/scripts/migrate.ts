import { fileURLToPath } from "node:url";
import { drizzle } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import pg from "pg";
import { migrationConnectionString } from "../src/config.js";

async function main() {
  // Never use the pooled runtime URL for schema migrations.
  const connectionString = migrationConnectionString(process.env);
  const pool = new pg.Pool({ connectionString, max: 1, connectionTimeoutMillis: 10_000 });
  try {
    await migrate(drizzle(pool), { migrationsFolder: fileURLToPath(new URL("../drizzle", import.meta.url)) });
    console.info("Lenscap cloud migrations applied.");
  } finally { await pool.end(); }
}

main().catch(() => {
  console.error("Cloud migration failed. Check DATABASE_URL_UNPOOLED, direct connectivity, and migration permissions; credentials were not logged.");
  process.exitCode = 1;
});
