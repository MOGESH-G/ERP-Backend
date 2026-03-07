import { Pool, PoolClient, QueryResult } from "pg";
import fs from "fs";
import path from "path";
import logger from "../utils/logger";

// ─── Resolve DB folder (works for both ts-node and compiled dist/) ─────────────
// src/config/database.ts  → ../../db
// dist/config/database.js → ../../db
const DB_DIR = path.resolve(__dirname, "../../db");

// ─── Master Pool ──────────────────────────────────────────────────────────────

export const masterPool = new Pool({
  host: process.env.DB_HOST || "localhost",
  port: parseInt(process.env.DB_PORT || "5432", 10),
  user: process.env.DB_USER || "postgres",
  password: process.env.DB_PASSWORD || "",
  database: process.env.DB_MASTER_NAME || "erp_master",
  min: parseInt(process.env.DB_POOL_MIN || "2", 10),
  max: parseInt(process.env.DB_POOL_MAX || "10", 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

masterPool.on("error", (err) => {
  logger.error("[master] Unexpected pool error:", err);
  process.exit(-1);
});

// ─── Tenant Pool Registry ─────────────────────────────────────────────────────

const tenantPools = new Map<string, Pool>();

const createTenantPool = (dbName: string): Pool => {
  return new Pool({
    host: process.env.DB_HOST || "localhost",
    port: parseInt(process.env.DB_PORT || "5432", 10),
    user: process.env.DB_USER || "postgres",
    password: process.env.DB_PASSWORD || "",
    database: dbName,
    min: 1,
    max: parseInt(process.env.DB_TENANT_POOL_MAX || "5", 10),
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  });
};

export const getTenantPool = (tenantId: string): Pool => {
  const pool = tenantPools.get(tenantId);
  if (!pool)
    throw new Error(`No pool found for tenant: ${tenantId}. Tenant may not be provisioned.`);
  return pool;
};

export const registerTenantPool = (tenantId: string, dbName: string): Pool => {
  if (tenantPools.has(tenantId)) return tenantPools.get(tenantId)!;

  const pool = createTenantPool(dbName);
  pool.on("error", (err) => {
    logger.error(`[tenant:${tenantId}] Unexpected pool error:`, err);
  });

  tenantPools.set(tenantId, pool);
  logger.info(`[tenant:${tenantId}] Pool registered → ${dbName}`);
  return pool;
};

export const removeTenantPool = async (tenantId: string): Promise<void> => {
  const pool = tenantPools.get(tenantId);
  if (pool) {
    await pool.end();
    tenantPools.delete(tenantId);
    logger.info(`[tenant:${tenantId}] Pool removed`);
  }
};

// ─── SQL File Runner ──────────────────────────────────────────────────────────

const runSqlFile = async (client: PoolClient, filename: string): Promise<void> => {
  const sqlPath = path.join(DB_DIR, filename);
  logger.info(`Running SQL: ${sqlPath}`);

  if (!fs.existsSync(sqlPath)) {
    throw new Error(`SQL file not found: ${sqlPath}`);
  }

  const sql = fs.readFileSync(sqlPath, "utf8");
  await client.query(sql);
};

// ─── Ensure Master DB Exists ──────────────────────────────────────────────────

const ensureMasterDbExists = async (): Promise<void> => {
  const masterDbName = process.env.DB_MASTER_NAME || "erp_master";

  // Connect to postgres system DB (always exists) to CREATE master if needed
  const bootstrapPool = new Pool({
    host: process.env.DB_HOST || "localhost",
    port: parseInt(process.env.DB_PORT || "5432", 10),
    user: process.env.DB_USER || "postgres",
    password: process.env.DB_PASSWORD || "",
    database: "postgres",
    connectionTimeoutMillis: 5000,
  });

  try {
    const result = await bootstrapPool.query<{ exists: boolean }>(
      `SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1) AS exists`,
      [masterDbName],
    );

    if (!result.rows[0].exists) {
      logger.info(`Master DB "${masterDbName}" not found — creating...`);
      await bootstrapPool.query(`CREATE DATABASE "${masterDbName}"`);
      logger.info(`✅ Master DB "${masterDbName}" created`);
    } else {
      logger.info(`✅ Master DB "${masterDbName}" already exists`);
    }
  } finally {
    await bootstrapPool.end();
  }
};

// ─── Connect Master DB & Run Schema ──────────────────────────────────────────

export const connectMasterDB = async (): Promise<void> => {
  // Step 1: Ensure the physical DB exists
  await ensureMasterDbExists();

  // Step 2: Run master schema (000_master.sql)
  const client = await masterPool.connect();
  try {
    await runSqlFile(client, "/master/001_init.sql");
    logger.info("✅ [master] schema ready");
  } catch (error) {
    logger.error("❌ [master] schema initialization failed:", error);
    throw error;
  } finally {
    client.release();
  }
};

// ─── Load All Active Tenant Pools at Startup ──────────────────────────────────
// Called AFTER connectMasterDB — tenants table is guaranteed to exist.

export const loadAllTenantPools = async (): Promise<void> => {
  const result = await masterPool.query<{ id: string; db_name: string }>(
    `SELECT id, db_name FROM tenants WHERE status = 'active'`,
  );

  for (const row of result.rows) {
    registerTenantPool(row.id, row.db_name);
  }

  logger.info(`✅ Loaded ${result.rows.length} active tenant pool(s)`);
};

// ─── Run Tenant Schema (called during provisioning) ───────────────────────────
// Creates all tables in a freshly provisioned tenant DB.

export const runTenantSchema = async (tenantId: string): Promise<void> => {
  const pool = getTenantPool(tenantId);
  const client = await pool.connect();
  try {
    await runSqlFile(client, "/tenant/001_init.sql");
    logger.info(`✅ [tenant:${tenantId}] schema applied`);
  } catch (error) {
    logger.error(`❌ [tenant:${tenantId}] schema failed:`, error);
    throw error;
  } finally {
    client.release();
  }
};

// ─── Query Helpers ────────────────────────────────────────────────────────────

export const masterQuery = async <T>(
  text: string,
  params?: (string | number | boolean | null)[],
): Promise<T[]> => {
  const result: QueryResult = await masterPool.query(text, params);
  return result.rows as T[];
};

export const tenantQuery = async <T>(
  tenantId: string,
  text: string,
  params?: (string | number | boolean | null)[],
): Promise<T[]> => {
  const pool = getTenantPool(tenantId);
  const result: QueryResult = await pool.query(text, params);
  return result.rows as T[];
};

// ─── Transaction Helpers ──────────────────────────────────────────────────────

export const withMasterTransaction = async <T>(
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> => {
  const client = await masterPool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
};

export const withTenantTransaction = async <T>(
  tenantId: string,
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> => {
  const pool = getTenantPool(tenantId);
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
};

