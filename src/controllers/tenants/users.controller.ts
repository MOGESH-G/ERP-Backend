import { Request, Response, NextFunction } from "express";
import bcrypt from "bcryptjs";
import { NotFoundError } from "../../utils/appError";
import { tenantQuery } from "../../config/database";

const SALT_ROUNDS = 10;

/**
 * POST /api/v1/users
 * Create user inside tenant
 */
export const createUser = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const { name, email, password, role, shop_id } = req.body;

    const passwordHash = await bcrypt.hash(password, SALT_ROUNDS);

    if (!req.tenant?.id) {
      throw new Error("Tenant not resolved");
    }

    const result = await tenantQuery(
      req.tenant.id,
      `
      INSERT INTO users (name,email,password,role,shop_id)
      VALUES ($1,$2,$3,$4,$5)
      RETURNING id,name,email,role,shop_id,created_at
      `,
      [name, email, passwordHash, role || "cashier", shop_id || null],
    );

    res.status(201).json({
      status: "success",
      data: result,
      message: "User created successfully",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * GET /api/v1/users
 */
export const getUsers = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    if (!req.tenant?.id) {
      throw new Error("Tenant not resolved");
    }

    const users = await tenantQuery(
      req.tenant.id,
      `
      SELECT 
        id,
        name,
        email,
        role,
        shop_id,
        is_active,
        created_at
      FROM users
      ORDER BY created_at DESC
      `,
    );

    res.status(200).json({
      status: "success",
      data: users,
      message: "Users retrieved",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * GET /api/v1/users/:id
 */
export const getUserById = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    if (!req.tenant?.id) {
      throw new Error("Tenant not resolved");
    }

    const user = await tenantQuery(
      req.tenant.id,
      `
      SELECT 
        id,
        name,
        email,
        role,
        shop_id,
        is_active,
        created_at
      FROM users
      WHERE id = $1
      `,
      [req.params.id],
    );

    if (!user.length) {
      throw new NotFoundError("User not found");
    }

    res.status(200).json({
      status: "success",
      data: user[0],
      message: "User retrieved",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * PATCH /api/v1/users/:id
 */
export const updateUser = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    const { name, role, shop_id, is_active } = req.body;

    if (!req.tenant?.id) {
      throw new Error("Tenant not resolved");
    }

    const result = await tenantQuery(
      req.tenant.id,
      `
      UPDATE users
      SET
        name = COALESCE($1,name),
        role = COALESCE($2,role),
        shop_id = COALESCE($3,shop_id),
        is_active = COALESCE($4,is_active),
        updated_at = NOW()
      WHERE id = $5
      RETURNING id,name,email,role,shop_id,is_active,updated_at
      `,
      [name, role, shop_id, is_active, req.params.id],
    );

    if (!result.length) {
      throw new NotFoundError("User not found");
    }

    res.status(200).json({
      status: "success",
      data: result[0],
      message: "User updated",
    });
  } catch (err) {
    next(err);
  }
};

/**
 * DELETE /api/v1/users/:id
 */
export const deleteUser = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  try {
    if (!req.tenant?.id) {
      throw new Error("Tenant not resolved");
    }

    const result = await tenantQuery(
      req.tenant.id,
      `DELETE FROM users WHERE id=$1 RETURNING id`,
      [req.params.id],
    );

    if (!result.length) {
      throw new NotFoundError("User not found");
    }

    res.status(200).json({
      status: "success",
      data: null,
      message: "User deleted",
    });
  } catch (err) {
    next(err);
  }
};
