import express from "express";
import tenantRoutes from "./master/tenant.routes";
import usersRoutes from "./tenants/users.routes";
import authRoutes from "./tenants/auth.routes";
import { verifyTenant } from "../middlewares/auth";
import { resolveTenant } from "../middlewares/tenantResolver";

const router = express.Router();

router.get("/health", (_req, res) => res.status(200).json({ status: "ok" }));

router.use("/tenants", tenantRoutes);

// Tenant-scoped routes require a subdomain (tenant slug) to resolve the tenant context.
router.use("/auth", resolveTenant, authRoutes);
router.use("/users", resolveTenant, verifyTenant, usersRoutes);

export default router;
