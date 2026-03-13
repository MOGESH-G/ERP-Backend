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

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

const generateSlug = (name: string): string =>
  name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .substring(0, 30);

const generateDbName = async (slug: string): Promise<string> => {
  let dbName = `${slug}`;
  let suffix = 1;

  // eslint-disable-next-line no-constant-condition
  while (true) {
    const existing = await masterQuery<{ db_name: string }>(
      "SELECT db_name FROM tenants WHERE db_name=$1",
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
    `INSERT INTO provisioning_log (tenant_id,event,status,error_detail)
     VALUES ($1,$2,$3,$4)`,
    [tenantId, step, status, error || null],
  );
};

// ─────────────────────────────────────────────────────────────
// Provision Tenant
// ─────────────────────────────────────────────────────────────

export const provisionTenant = async (input: ProvisionTenantInput): Promise<ProvisionResult> => {
  const slug = generateSlug(input.name);
  const dbName = await generateDbName(slug);
  const plan = input.plan || "trial";

  logger.info(`🚀 Provisioning tenant: ${input.name} → ${dbName}`);

  let dbCreated = false;
  let poolRegistered = false;
  let tenantRowCreated = false;

  const tenants = await masterQuery<{ id: string }>(
    `INSERT INTO tenants (name,slug,db_name,email,plan,status)
     VALUES ($1,$2,$3,$4,$5,'provisioning')
     RETURNING id`,
    [input.name, slug, dbName, input.email, plan],
  );

  const tenantId = tenants[0].id;
  tenantRowCreated = true;

  try {
    // ─────────────────────────────────────
    // Create DB
    // ─────────────────────────────────────

    await logStep(tenantId, "create_db", "pending");

    await masterPool.query(`CREATE DATABASE "${dbName}"`);
    dbCreated = true;

    await logStep(tenantId, "create_db", "success");

    // ─────────────────────────────────────
    // Register pool
    // ─────────────────────────────────────

    registerTenantPool(tenantId, dbName);
    poolRegistered = true;

    // ─────────────────────────────────────
    // Run schema
    // ─────────────────────────────────────

    await logStep(tenantId, "run_schema", "pending");
    await runTenantSchema(tenantId);
    await logStep(tenantId, "run_schema", "success");

    // ─────────────────────────────────────
    // Seed tenant profile
    // ─────────────────────────────────────

    await tenantQuery(
      tenantId,
      `INSERT INTO tenant_profile
       (name,gst_number,pan_number,phone,email,address,currency)
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

    // ─────────────────────────────────────
    // Create master admin
    // ─────────────────────────────────────

    const passwordHash = await bcrypt.hash(input.admin.password, 12);

    const admins = await masterQuery<{
      id: string;
      name: string;
      email: string;
    }>(
      `INSERT INTO admin_accounts (tenant_id,name,email,password)
       VALUES ($1,$2,$3,$4)
       RETURNING id,name,email`,
      [tenantId, input.admin.name, input.admin.email, passwordHash],
    );

    const admin = admins[0];

    // ─────────────────────────────────────
    // Create tenant user
    // ─────────────────────────────────────

    const users = await tenantQuery<{ id: string }>(
      tenantId,
      `INSERT INTO users (name,email,password,is_active)
       VALUES ($1,$2,$3,true)
       RETURNING id`,
      [admin.name, admin.email, passwordHash],
    );

    const tenantUserId = users[0].id;

    // ─────────────────────────────────────
    // Apply plan features
    // ─────────────────────────────────────

    await masterPool.query(`SELECT fn_apply_plan_to_tenant($1,$2)`, [tenantId, plan]);

    const tenantData = (
      await masterQuery<{ feature_ids: Record<string, any> }>(
        `SELECT feature_ids FROM tenants WHERE id=$1`,
        [tenantId],
      )
    )[0];

    // ─────────────────────────────────────
    // Generate admin permissions
    // ─────────────────────────────────────

    const permissions: Record<string, Record<string, boolean>> = {};

    for (const feature of Object.keys(tenantData.feature_ids)) {
      if (!feature.startsWith("feat_")) continue;

      const resource = feature.replace("feat_", "");

      permissions[resource] = {
        view: true,
        create: true,
        update: true,
        delete: true,
      };
    }

    // ─────────────────────────────────────
    // Create admin role
    // ─────────────────────────────────────

    const roles = await tenantQuery<{ id: string }>(
      tenantId,
      `INSERT INTO roles (name,description,permissions,is_system)
       VALUES ($1,$2,$3,true)
       RETURNING id`,
      ["admin", "Tenant Administrator", JSON.stringify(permissions)],
    );

    const roleId = roles[0].id;

    // ─────────────────────────────────────
    // Assign role
    // ─────────────────────────────────────

    await tenantQuery(
      tenantId,
      `INSERT INTO user_roles (user_id,role_id)
       VALUES ($1,$2)`,
      [tenantUserId, roleId],
    );

    // ─────────────────────────────────────
    // Activate tenant
    // ─────────────────────────────────────

    await masterPool.query(
      `UPDATE tenants
       SET status='active',updated_at=NOW()
       WHERE id=$1`,
      [tenantId],
    );

    await logStep(tenantId, "provision", "success");

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

    logger.info(`🎉 Tenant provisioned: ${tenant.name}`);

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

// ─────────────────────────────────────────────────────────────
// Rollback
// ─────────────────────────────────────────────────────────────

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
    if (poolRegistered) {
      await removeTenantPool(tenantId);
    }

    if (dbCreated) {
      await masterPool.query(
        `SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE datname=$1
         AND pid <> pg_backend_pid()`,
        [dbName],
      );

      await masterPool.query(`DROP DATABASE IF EXISTS "${dbName}"`);
      logger.warn(`🗑 Dropped DB ${dbName}`);
    }

    await masterPool.query(`DELETE FROM admin_accounts WHERE tenant_id=$1`, [tenantId]);

    await masterPool.query(`DELETE FROM provisioning_log WHERE tenant_id=$1`, [tenantId]);

    if (tenantRowCreated) {
      await masterPool.query(`DELETE FROM tenants WHERE id=$1`, [tenantId]);
    }
  } catch (err) {
    logger.error("Rollback failed", err);
  }
};

// ─────────────────────────────────────────────────────────────
// Deprovision Tenant
// ─────────────────────────────────────────────────────────────

export const deprovisionTenant = async (tenantId: string): Promise<void> => {
  const tenants = await masterQuery<{ db_name: string }>(
    "SELECT db_name FROM tenants WHERE id=$1",
    [tenantId],
  );

  if (!tenants[0]) {
    throw new Error(`Tenant not found: ${tenantId}`);
  }

  const { db_name } = tenants[0];

  await masterPool.query(
    `SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE datname=$1
     AND pid <> pg_backend_pid()`,
    [db_name],
  );

  await masterPool.query(`DROP DATABASE IF EXISTS "${db_name}"`);

  await removeTenantPool(tenantId);

  await masterPool.query(
    `UPDATE tenants
     SET status='deprovisioned'
     WHERE id=$1`,
    [tenantId],
  );

  logger.info(`🗑 Tenant deprovisioned: ${tenantId}`);
};
