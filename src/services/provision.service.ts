import bcrypt from "bcryptjs";
import {
  masterPool,
  masterQuery,
  registerTenantPool,
  removeTenantPool,
  runTenantSchema,
  tenantQuery,
} from "../config/database";
import logger from "../utils/logger";

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ProvisionTenantInput {
  name: string;
  email: string;
  phone?: string;
  address?: string;
  gst_number?: string;
  pan_number?: string;
  currency?: string;
  plan?: "trial" | "starter" | "growth" | "enterprise";
  admin: {
    name: string;
    email: string;
    password: string;
  };
}

export interface ProvisionResult {
  tenant: {
    id: string;
    name: string;
    slug: string;
    db_name: string;
    plan: string;
    status: string;
  };
  admin: {
    id: string;
    name: string;
    email: string;
  };
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const generateSlug = (name: string): string =>
  name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .substring(0, 30);

const generateDbName = async (slug: string): Promise<string> => {
  // let dbName = `erp_${slug}`;
  let dbName = `${slug}`;
  let suffix = 1;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const existing = await masterQuery<{ db_name: string }>(
      "SELECT db_name FROM tenants WHERE db_name = $1",
      [dbName],
    );
    if (existing.length === 0) break;
    dbName = `erp_${slug}_${suffix++}`;
  }
  return dbName;
};

const logStep = async (
  tenantId: string,
  step: string,
  status: "pending" | "success" | "failed",
  error?: string,
): Promise<void> => {
  await masterPool.query(
    `INSERT INTO provisioning_log (tenant_id, event, status, error_detail)
     VALUES ($1, $2, $3, $4)`,
    [tenantId, step, status, error || null],
  );
};

// ─── Provision ────────────────────────────────────────────────────────────────

// export const provisionTenant = async (input: ProvisionTenantInput): Promise<ProvisionResult> => {
//   const slug = generateSlug(input.name);
//   const dbName = await generateDbName(slug);
//   const plan = input.plan || "trial";

//   logger.info(`🚀 Provisioning tenant: ${input.name} → ${dbName}`);

//   // ── 1. Insert tenant row (status = provisioning) ────────────────────────────
//   const tenants = await masterQuery<{ id: string }>(
//     `INSERT INTO tenants (name, slug, db_name, email, plan, status)
//      VALUES ($1, $2, $3, $4, $5, 'provisioning')
//      RETURNING id`,
//     [input.name, slug, dbName, input.email, plan],
//   );
//   const tenantId = tenants[0].id;

//   try {
//     // ── 2. Create physical PostgreSQL database ──────────────────────────────
//     // NOTE: CREATE DATABASE cannot run inside a transaction
//     await logStep(tenantId, "create_db", "pending");
//     await masterPool.query(`CREATE DATABASE "${dbName}"`);
//     await logStep(tenantId, "create_db", "success");
//     logger.info(`✅ [${tenantId}] DB created: ${dbName}`);

//     // ── 3. Register pool for the new DB ────────────────────────────────────
//     registerTenantPool(tenantId, dbName);

//     // ── 4. Run tenant.init.sql — creates all tables, triggers, seed data ────
//     await logStep(tenantId, "run_schema", "pending");
//     await runTenantSchema(tenantId); // ← uses database.ts
//     await logStep(tenantId, "run_schema", "success");

//     // ── 5. Seed tenant_profile in the new DB ───────────────────────────────
//     await logStep(tenantId, "seed_profile", "pending");
//     const { tenantQuery } = await import("../config/database");
//     await tenantQuery(
//       tenantId,
//       `INSERT INTO tenant_profile (name, gst_number, pan_number, phone, email, address, currency)
//        VALUES ($1, $2, $3, $4, $5, $6, $7)`,
//       [
//         input.name,
//         input.gst_number || null,
//         input.pan_number || null,
//         input.phone || null,
//         input.email,
//         input.address || null,
//         input.currency || "INR",
//       ],
//     );
//     await logStep(tenantId, "seed_profile", "success");
//     logger.info(`✅ [${tenantId}] tenant_profile seeded`);

//     // ── 6. Create admin account in master DB ────────────────────────────────
//     await logStep(tenantId, "create_admin", "pending");
//     const passwordHash = await bcrypt.hash(input.admin.password, 12);
//     const admins = await masterQuery<{ id: string; name: string; email: string }>(
//       `INSERT INTO admin_accounts (tenant_id, name, email, password)
//        VALUES ($1, $2, $3, $4)
//        RETURNING id, name, email`,
//       [tenantId, input.admin.name, input.admin.email, passwordHash],
//     );
//     await logStep(tenantId, "create_admin", "success");
//     logger.info(`✅ [${tenantId}] Admin created: ${input.admin.email}`);

//     // ── 7. Create admin account in tenant DB ────────────────────────────────
//     const admin = admins[0];

//     await tenantQuery(
//       tenantId,
//       `INSERT INTO users (name, email, password, is_active)
//       VALUES ($1, $2, $3, 'admin', true)`,
//       [admin.name, admin.email, passwordHash],
//     );

//     // ── 8. Apply plan features to tenant ────────────────────────────────────
//     await masterPool.query(`SELECT fn_apply_plan_to_tenant($1, $2)`, [tenantId, plan]);

//     // ── 9. Mark tenant active ───────────────────────────────────────────────
//     await masterPool.query(
//       `UPDATE tenants SET status = 'active', updated_at = NOW() WHERE id = $1`,
//       [tenantId],
//     );
//     await logStep(tenantId, "provision", "success");

//     logger.info(`🎉 Tenant fully provisioned: ${input.name} [${tenantId}]`);

//     const tenant = (
//       await masterQuery<{
//         id: string;
//         name: string;
//         slug: string;
//         db_name: string;
//         plan: string;
//         status: string;
//       }>("SELECT id, name, slug, db_name, plan, status FROM tenants WHERE id = $1", [tenantId])
//     )[0];

//     return { tenant, admin: admins[0] };
//   } catch (error) {
//     // ── Rollback: log failure, mark suspended ───────────────────────────────
//     logger.error(`❌ Provisioning failed for ${tenantId}:`, error);
//     await logStep(tenantId, "provision", "failed", String(error));
//     await masterPool.query(`UPDATE tenants SET status = 'suspended' WHERE id = $1`, [tenantId]);
//     throw error;
//   }
// };

export const provisionTenant = async (input: ProvisionTenantInput): Promise<ProvisionResult> => {
  const slug = generateSlug(input.name);
  const dbName = await generateDbName(slug);
  const plan = input.plan || "trial";

  logger.info(`🚀 Provisioning tenant: ${input.name} → ${dbName}`);

  // Track completed steps
  let dbCreated = false;
  let poolRegistered = false;
  let tenantRowCreated = false;

  // ── 1. Insert tenant row ───────────────────────────────────────────────
  const tenants = await masterQuery<{ id: string }>(
    `INSERT INTO tenants (name, slug, db_name, email, plan, status)
     VALUES ($1, $2, $3, $4, $5, 'provisioning')
     RETURNING id`,
    [input.name, slug, dbName, input.email, plan],
  );

  const tenantId = tenants[0].id;
  tenantRowCreated = true;

  try {
    // ── 2. Create PostgreSQL database ────────────────────────────────────
    await logStep(tenantId, "create_db", "pending");

    await masterPool.query(`CREATE DATABASE "${dbName}"`);

    dbCreated = true;

    await logStep(tenantId, "create_db", "success");
    logger.info(`✅ [${tenantId}] DB created: ${dbName}`);

    // ── 3. Register tenant pool ──────────────────────────────────────────
    registerTenantPool(tenantId, dbName);
    poolRegistered = true;

    // ── 4. Run schema ────────────────────────────────────────────────────
    await logStep(tenantId, "run_schema", "pending");

    await runTenantSchema(tenantId);

    await logStep(tenantId, "run_schema", "success");

    // ── 5. Seed tenant profile ───────────────────────────────────────────
    await logStep(tenantId, "seed_profile", "pending");

    await tenantQuery(
      tenantId,
      `INSERT INTO tenant_profile
       (name, gst_number, pan_number, phone, email, address, currency)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [
        input.name,
        input.gst_number || null,
        input.pan_number || null,
        input.phone || null,
        input.email,
        input.address || null,
        input.currency || "INR",
      ],
    );

    await logStep(tenantId, "seed_profile", "success");

    // ── 6. Create admin in master DB ─────────────────────────────────────
    await logStep(tenantId, "create_admin", "pending");

    const passwordHash = await bcrypt.hash(input.admin.password, 12);

    const admins = await masterQuery<{
      id: string;
      name: string;
      email: string;
    }>(
      `INSERT INTO admin_accounts (tenant_id, name, email, password)
       VALUES ($1,$2,$3,$4)
       RETURNING id,name,email`,
      [tenantId, input.admin.name, input.admin.email, passwordHash],
    );

    await logStep(tenantId, "create_admin", "success");

    const admin = admins[0];

    // ── 7. Create admin in tenant DB ─────────────────────────────────────
    await tenantQuery(
      tenantId,
      `INSERT INTO users (name,email,password,is_active)
       VALUES ($1,$2,$3,true)`,
      [admin.name, admin.email, passwordHash],
    );

    // ── 8. Apply subscription plan ───────────────────────────────────────
    await masterPool.query(`SELECT fn_apply_plan_to_tenant($1,$2)`, [tenantId, plan]);

    // ── 9. Activate tenant ───────────────────────────────────────────────
    await masterPool.query(
      `UPDATE tenants
       SET status='active',updated_at=NOW()
       WHERE id=$1`,
      [tenantId],
    );

    await logStep(tenantId, "provision", "success");

    logger.info(`🎉 Tenant fully provisioned: ${input.name} [${tenantId}]`);

    const tenant = (
      await masterQuery<{
        id: string;
        name: string;
        slug: string;
        db_name: string;
        plan: string;
        status: string;
      }>(
        `SELECT id,name,slug,db_name,plan,status
         FROM tenants
         WHERE id=$1`,
        [tenantId],
      )
    )[0];

    return { tenant, admin };
  } catch (error) {
    logger.error(`❌ Provisioning failed for ${tenantId}`, error);

    await rollbackProvisioning({
      tenantId,
      dbName,
      dbCreated,
      poolRegistered,
      tenantRowCreated,
    });

    throw error;
  }
};

// Rollback helper to clean up resources on failure

const rollbackProvisioning = async ({
  tenantId,
  dbName,
  dbCreated,
  poolRegistered,
  tenantRowCreated,
}: {
  tenantId: string;
  dbName: string;
  dbCreated: boolean;
  poolRegistered: boolean;
  tenantRowCreated: boolean;
}) => {
  logger.warn(`🔁 Rolling back tenant ${tenantId}`);

  try {
    // remove tenant pool
    if (poolRegistered) {
      await removeTenantPool(tenantId);
    }

    // drop database
    if (dbCreated) {
      await masterPool.query(
        `SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE datname=$1`,
        [dbName],
      );

      await masterPool.query(`DROP DATABASE IF EXISTS "${dbName}"`);

      logger.warn(`🗑 Dropped tenant DB ${dbName}`);
    }

    // remove admin accounts
    await masterPool.query(`DELETE FROM admin_accounts WHERE tenant_id=$1`, [tenantId]);

    await masterPool.query(
      `DELETE FROM provisioning_log WHERE provisioning_log_tenant_id_fkey=$1`,
      [tenantId],
    );

    // remove tenant row
    if (tenantRowCreated) {
      await masterPool.query(`DELETE FROM tenants WHERE id=$1`, [tenantId]);
    }
  } catch (err) {
    logger.error("Rollback failed", err);
  }
};

// ─── Deprovision ─────────────────────────────────────────────────────────────

export const deprovisionTenant = async (tenantId: string): Promise<void> => {
  const tenants = await masterQuery<{ db_name: string }>(
    "SELECT db_name FROM tenants WHERE id = $1",
    [tenantId],
  );
  if (!tenants[0]) throw new Error(`Tenant not found: ${tenantId}`);

  const { db_name } = tenants[0];

  // Terminate all active connections first
  await masterPool.query(
    `SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE datname = $1 AND pid <> pg_backend_pid()`,
    [db_name],
  );

  await masterPool.query(`DROP DATABASE IF EXISTS "${db_name}"`);
  await removeTenantPool(tenantId);
  await masterPool.query(`UPDATE tenants SET status = 'deprovisioned' WHERE id = $1`, [tenantId]);

  logger.info(`🗑️  Tenant deprovisioned: ${tenantId} (${db_name})`);
};
