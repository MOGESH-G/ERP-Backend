import { tenantQuery } from "../../config/database";
import { Request, Response } from "express";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import config from "../../config/env";
import { TenantUser } from "../../types/users.types";

export const Login = async (req: Request, res: Response): Promise<void> => {
  const { email, password } = req.body;

  if (!req.tenant?.id) {
    res.status(400).json({ message: "Tenant not resolved" });
    return;
  }

  // Fetch user + associated roles from tenant DB (RBAC stored in tenant schema)
  const query = `
    SELECT
      u.id,
      u.shop_id,
      u.name,
      u.email,
      u.password,
      u.is_active,
      COALESCE(json_agg(r.name) FILTER (WHERE r.name IS NOT NULL), '[]') AS roles
    FROM users u
    LEFT JOIN user_roles ur ON ur.user_id = u.id
    LEFT JOIN roles r ON r.id = ur.role_id
    WHERE u.email = $1
    GROUP BY u.id
  `;

  try {
    const values = [email];
    const result = await tenantQuery(req.tenant.id, query, values);

    if (result.length === 0) {
      res.status(401).json({ message: "Invalid email or password" });
      return;
    }

    const user = result[0] as TenantUser;

    const isMatch = await bcrypt.compare(password, user.password);

    if (!isMatch) {
      res.status(401).json({ message: "Invalid email or password" });
      return;
    }

    const roles: string[] = Array.isArray(user.roles)
      ? user.roles
      : typeof user.roles === "string"
      ? JSON.parse(user.roles)
      : [];

    const token = jwt.sign(
      {
        id: user.id,
        email: user.email,
        roles,
        tenantId: req.tenant.id,
      },
      config.jwt.secret,
      {
        expiresIn: config.jwt.expiresIn as any,
      }
    );

    res.status(200).json({
      status: "success",
      data: {
        id: user.id,
        name: user.name,
        email: user.email,
        roles,
        shop_id: user.shop_id,
      },
      token,
    });
  } catch (err) {
    res.status(500).json({ message: "Server error" });
  }
};
