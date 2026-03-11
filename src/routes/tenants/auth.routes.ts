import { Router } from "express";
import { Login } from "../../controllers/tenants/auth.controller";
import { validate } from "../../middlewares/validate";
import { loginSchema } from "../../validators/tenant/auth.validation";

const router = Router();

router.post("/login", validate(loginSchema), Login);

export default router;
