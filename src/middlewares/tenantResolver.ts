import { masterQuery } from "../config/database";
import { UnauthorizedError } from "../utils/appError";
import { RequestHandler } from "express";

export const resolveTenant: RequestHandler = async (req, _res, next) => {
  try {
    const hostHeader = req.headers.host;

    if (!hostHeader) {
      return next(new UnauthorizedError("Invalid host"));
    }

    const host = hostHeader.split(":")[0].toLowerCase();

    const parts = host.split(".");
    if (parts.length < 2) {
      return next(new UnauthorizedError("Invalid tenant host"));
    }

    const tenantSlug = parts[0];

    const tenants = await masterQuery<{ id: string; slug: string }>(
      "SELECT id, slug FROM tenants WHERE slug = $1",
      [tenantSlug],
    );

    if (!tenants.length) {
      return next(new UnauthorizedError("Tenant not found"));
    }

    req.tenant = tenants[0];

    next();
  } catch (error) {
    next(error);
  }
};
