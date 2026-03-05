import { Pool, PoolClient } from "pg";
import config from "@/config/env";
import logger from "@/utils/logger";

const pool = new Pool({
  host: config.db.host,
  port: config.db.port,
  database: config.db.name,
  user: config.db.user,
  password: config.db.password,
  min: config.db.poolMin,
  max: config.db.poolMax,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

pool.on("connect", () => {
  logger.info("New database connection established");
});

pool.on("error", (err: Error) => {
  logger.error("Unexpected database error:", err);
  process.exit(-1);
});

export const connectDB = async (): Promise<void> => {
  try {
    const client: PoolClient = await pool.connect();
    logger.info(`✅ PostgreSQL connected: ${config.db.host}:${config.db.port}/${config.db.name}`);
    client.release();
  } catch (error) {
    logger.error("❌ Database connection failed:", error);
    throw error;
  }
};

export const query = async <T>(
  text: string,
  params?: (string | number | boolean | null)[],
): Promise<T[]> => {
  const start = Date.now();
  const result = await pool.query(text, params);
  const duration = Date.now() - start;
  logger.debug(`Query executed in ${duration}ms: ${text}`);
  return result.rows as T[];
};

export const getClient = async (): Promise<PoolClient> => {
  return pool.connect();
};

export default pool;

