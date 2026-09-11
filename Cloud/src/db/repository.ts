import { and, desc, eq, isNull, lt, lte, or, sql } from "drizzle-orm";
import type { PgDatabase, PgQueryResultHKT } from "drizzle-orm/pg-core";
import type { CaptureRecord, CaptureRepository, CaptureTransaction, DeletedCapture } from "../contracts.js";
import * as schema from "./schema.js";

const { captures, deletedCaptures } = schema;

function captureRecord(row: typeof captures.$inferSelect): CaptureRecord {
  return { ...row, createdAt: row.createdAt.toISOString(), uploadedAt: row.uploadedAt?.toISOString() ?? null, uploadExpiresAt: row.uploadExpiresAt.toISOString() };
}

function captureValues(record: CaptureRecord): typeof captures.$inferInsert {
  return { ...record, createdAt: new Date(record.createdAt), uploadedAt: record.uploadedAt ? new Date(record.uploadedAt) : null, uploadExpiresAt: new Date(record.uploadExpiresAt) };
}

function deletedRecord(row: typeof deletedCaptures.$inferSelect): DeletedCapture {
  return { ...row, deletedAt: row.deletedAt.toISOString(), cleanupAfter: row.cleanupAfter.toISOString(), lastCleanupAt: row.lastCleanupAt?.toISOString() ?? null };
}

export function createCaptureRepository<T extends PgQueryResultHKT>(db: PgDatabase<T, typeof schema>): CaptureRepository {
  async function databaseBytes(executor: PgDatabase<T, typeof schema>): Promise<number> {
    const result = await executor.execute(sql`SELECT pg_database_size(current_database())::text AS bytes`);
    const rows = (result as { rows: { bytes: string }[] }).rows;
    const size = Number(rows[0]?.bytes);
    if (!Number.isSafeInteger(size) || size < 0) throw new Error("Invalid database size result");
    return size;
  }

  function transaction(executor: PgDatabase<T, typeof schema>, id: string): CaptureTransaction {
    return {
      async get() {
        const [row] = await executor.select().from(captures).where(eq(captures.id, id)).limit(1);
        return row ? captureRecord(row) : null;
      },
      async getDeleted() {
        const [row] = await executor.select().from(deletedCaptures).where(eq(deletedCaptures.id, id)).limit(1);
        return row ? deletedRecord(row) : null;
      },
      databaseBytes: () => databaseBytes(executor),
      async insert(record) { await executor.insert(captures).values(captureValues(record)); },
      async update(record) { await executor.update(captures).set(captureValues(record)).where(eq(captures.id, id)); },
      async remove(tombstone) {
        await executor.insert(deletedCaptures).values({
          ...tombstone,
          deletedAt: new Date(tombstone.deletedAt), cleanupAfter: new Date(tombstone.cleanupAfter),
          lastCleanupAt: tombstone.lastCleanupAt ? new Date(tombstone.lastCleanupAt) : null,
        }).onConflictDoNothing();
        await executor.delete(captures).where(eq(captures.id, id));
      },
      async markCleaned(at) { await executor.update(deletedCaptures).set({ lastCleanupAt: new Date(at) }).where(eq(deletedCaptures.id, id)); },
    };
  }

  return {
    withCapture(id, operation) {
      return db.transaction(async (tx) => {
        // Transaction-level advisory locks work through PgBouncer and also protect
        // an id before its first row exists or after it has become a tombstone.
        await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${id}, 0))`);
        return operation(transaction(tx, id));
      });
    },
    async list({ limit, cursor }) {
      const older = cursor ? or(
        lt(captures.createdAt, new Date(cursor.createdAt)),
        and(eq(captures.createdAt, new Date(cursor.createdAt)), lt(captures.id, cursor.id)),
      ) : undefined;
      const rows = await db.select().from(captures)
        .where(and(eq(captures.status, "uploaded"), older))
        .orderBy(desc(captures.createdAt), desc(captures.id)).limit(limit);
      return rows.map(captureRecord);
    },
    async usage() {
      const [row] = await db.select({
        captureCount: sql<string>`count(*) filter (where ${captures.status} = 'uploaded')::text`,
        storageBytes: sql<string>`coalesce(sum(${captures.byteCount}) filter (where ${captures.status} = 'uploaded'), 0)::text`,
        pendingUploadCount: sql<string>`count(*) filter (where ${captures.status} = 'pending')::text`,
      }).from(captures);
      return { captureCount: Number(row?.captureCount ?? 0), storageBytes: Number(row?.storageBytes ?? 0), pendingUploadCount: Number(row?.pendingUploadCount ?? 0) };
    },
    databaseBytes: () => databaseBytes(db),
    async deletionsDue(at, limit) {
      const rescanBefore = new Date(Date.parse(at) - 24 * 60 * 60 * 1000);
      const rows = await db.select().from(deletedCaptures).where(and(
        lte(deletedCaptures.cleanupAfter, new Date(at)),
        or(isNull(deletedCaptures.lastCleanupAt), lte(deletedCaptures.lastCleanupAt, rescanBefore)),
      )).orderBy(deletedCaptures.cleanupAfter).limit(limit);
      return rows.map(deletedRecord);
    },
  };
}
