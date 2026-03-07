import express from "express";
import tenantRoutes from "./master/tenant.routes";
import usersRoutes from "./tenants/users.routes";
import { verifyAdmin, verifyTenant } from "../middlewares/auth";

const router = express.Router();

router.get("/health", (_req, res) => res.status(200).json({ status: "ok" }));
router.use("/tenants", verifyAdmin, tenantRoutes);

router.use("/users", verifyTenant, usersRoutes);

export default router;
