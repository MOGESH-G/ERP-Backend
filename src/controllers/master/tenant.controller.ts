import { Request, Response, NextFunction } from "express";
import { provisionTenant, deprovisionTenant } from "../../services/provision.service";
import { masterQuery } from "../../config/database";
import { NotFoundError } from "../../utils/appError";

/**
 * POST /api/v1/tenants
 * Create and provision a new tenant
 */
export const createTenant = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const result = await provisionTenant(req.body);
    res.status(201).json({
      status: "success",
      data: result,
      message: "Tenant provisioned successfully",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * GET /api/v1/tenants
 * Retrieve all tenants
 */
export const getAllTenants = async (
  _req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const tenants = await masterQuery(
      `SELECT 
        id,
        name,
        slug,
        db_name,
        plan,
        status,
        email,
        phone,
        created_at
       FROM tenants
       ORDER BY created_at DESC`,
    );

    res.status(200).json({
      status: "success",
      data: tenants,
      message: "Tenants retrieved",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * GET /api/v1/tenants/:id
 * Retrieve a single tenant
 */
export const getTenantById = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const tenants = await masterQuery(
      `SELECT 
        t.id,
        t.name,
        t.slug,
        t.db_name,
        t.plan,
        t.status,
        t.email,
        t.phone,
        t.country,
        t.timezone,
        t.created_at,
        t.updated_at,
        COUNT(aa.id) AS admin_count
       FROM tenants t
       LEFT JOIN admin_accounts aa 
         ON aa.tenant_id = t.id
       WHERE t.id = $1
       GROUP BY t.id`,
      [req.params.id],
    );

    if (!tenants[0]) {
      throw new NotFoundError("Tenant not found");
    }

    res.status(200).json({
      status: "success",
      data: tenants[0],
      message: "Tenant retrieved",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * GET /api/v1/tenants/:id/logs
 * Retrieve provisioning logs for a tenant
 */
export const getTenantLogs = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const logs = await masterQuery(
      `SELECT 
        id,
        tenant_id,
        event,
        status,
        db_name,
        triggered_by,
        error_detail,
        duration_ms,
        created_at
       FROM provisioning_log
       WHERE tenant_id = $1
       ORDER BY created_at DESC`,
      [req.params.id],
    );

    res.status(200).json({
      status: "success",
      data: logs,
      message: "Provisioning logs retrieved",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * DELETE /api/v1/tenants/:id
 * Deprovision a tenant
 */
export const deleteTenant = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const tenantId = req.params.id;

    const existingTenant = await masterQuery(`SELECT id FROM tenants WHERE id = $1`, [tenantId]);

    if (!existingTenant[0]) {
      throw new NotFoundError("Tenant not found");
    }

    await deprovisionTenant(tenantId);

    res.status(200).json({
      status: "success",
      data: null,
      message: "Tenant deprovisioned successfully",
    });
  } catch (err) {
    next(err);
  }
};
