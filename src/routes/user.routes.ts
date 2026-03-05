import { Router } from "express";
import { register, login, getUsers, getUserById, deleteUser } from "@/controllers/user.controller";
import { validate } from "@/middlewares/validate";
import { authenticate, authorize } from "@/middlewares/auth";
import { registerSchema, loginSchema } from "@/validators/user.validator";

const router = Router();

// Public routes
router.post("/register", validate(registerSchema), register);
router.post("/login", validate(loginSchema), login);

// Protected routes
router.use(authenticate);
router.get("/", authorize("admin"), getUsers);
router.get("/:id", getUserById);
router.delete("/:id", authorize("admin"), deleteUser);

export default router;

