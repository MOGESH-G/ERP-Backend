import { Router } from "express";
import {
  createTenant,
  getAllTenants,
  getTenantById,
  getTenantLogs,
  deleteTenant,
} from "../../controllers/master/tenant.controller";
import { validate } from "../../middlewares/validate";
import { createTenantSchema } from "../../validators/master/tenant.validator";

const router = Router();

router.post("/", validate(createTenantSchema), createTenant);
router.get("/", getAllTenants);
router.get("/:id", getTenantById);
router.get("/:id/logs", getTenantLogs);
router.delete("/:id", deleteTenant);

export default router;
