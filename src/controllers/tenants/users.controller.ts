import { Request, Response, NextFunction } from "express";
import bcrypt from "bcryptjs";
import { sendSuccess, sendCreated } from "../../utils/apiResponse";
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

    const result = await tenantQuery(
      req.user!.tenantId!,
      `
      INSERT INTO users (name,email,password_hash,role,shop_id)
      VALUES ($1,$2,$3,$4,$5)
      RETURNING id,name,email,role,shop_id,created_at
      `,
      [name, email, passwordHash, role || "cashier", shop_id || null],
    );

    sendCreated(res, result, "User created successfully");
  } catch (err) {
    next(err);
  }
};

/**
 * GET /api/v1/users
 */
export const getUsers = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const users = await tenantQuery(
      req.user!.tenantId!,
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

    sendSuccess(res, users, "Users retrieved");
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
    const user = await tenantQuery(
      req.user!.tenantId!,
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

    if (!user) {
      throw new NotFoundError("User not found");
    }

    sendSuccess(res, user, "User retrieved");
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

    const result = await tenantQuery(
      req.user!.tenantId!,
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

    if (!result) {
      throw new NotFoundError("User not found");
    }

    sendSuccess(res, result, "User updated");
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
    const result = await tenantQuery(req.user!.tenantId!, `DELETE FROM users WHERE id=$1 RETURNING id`, [
      req.params.id,
    ]);

    if (!result) {
      throw new NotFoundError("User not found");
    }

    sendSuccess(res, null, "User deleted");
  } catch (err) {
    next(err);
  }
};
