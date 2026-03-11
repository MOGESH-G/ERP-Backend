import { Request, Response, NextFunction } from "express";
import jwt from "jsonwebtoken";
import config from "../config/env";
import { UnauthorizedError } from "../utils/appError";

export interface JwtPayload {
  id: string;
  email: string;
  role: string;
  tenantId?: string;
  iat: number;
  exp: number;
}

// Extend Express Request
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: JwtPayload;
      tenant?: {
        id: string;
        slug: string;
      };
    }
  }
}

export const validateToken = (req: Request, _res: Response, next: NextFunction): void => {
  const authHeader = req.headers.authorization;

  if (!authHeader?.startsWith("Bearer ")) {
    return next(new UnauthorizedError("No token provided"));
  }

  const token = authHeader.split(" ")[1];

  try {
    const decoded = jwt.verify(token, config.jwt.secret) as JwtPayload;

    req.user = decoded;
    next();
  } catch {
    next(new UnauthorizedError("Invalid or expired token"));
  }
};

export const verifyTenant = (req: Request, _res: Response, next: NextFunction): void => {
  validateToken(req, _res, () => {
    if (!req.tenant?.id) {
      return next(new UnauthorizedError("Tenant not resolved"));
    }

    if (req.user?.tenantId && req.user.tenantId !== req.tenant.id) {
      return next(new UnauthorizedError("Invalid token: tenant mismatch"));
    }

    // Ensure tenantId is always available for downstream handlers
    if (req.user) {
      req.user.tenantId = req.tenant.id;
    }

    next();
  });
};

export const verifyAdmin = (req: Request, _res: Response, next: NextFunction): void => {
  validateToken(req, _res, () => {
    if (!req.user || req.user.role !== "admin") {
      return next(new UnauthorizedError("You do not have permission to perform this action"));
    }
    next();
  });
};

