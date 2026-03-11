import Joi from "joi";

export const createTenantSchema = Joi.object({
  name: Joi.string().trim().min(2).max(100).required(),
  email: Joi.string().trim().email().lowercase().required(),
  phone: Joi.string().trim().max(20).optional(),
  address: Joi.string().trim().max(255).optional(),
  gst_number: Joi.string().trim().uppercase().max(15).optional(),
  pan_number: Joi.string().trim().uppercase().max(10).optional(),
  currency: Joi.string().length(3).uppercase().default("INR"),
  plan: Joi.string().valid("free", "starter", "professional", "enterprise").default("free"),
  admin: Joi.object({
    name: Joi.string().trim().min(2).max(50).required(),
    email: Joi.string().trim().email().lowercase().required(),
    password: Joi.string()
      .min(6)
      .pattern(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])/)
      .required()
      .messages({
        "string.pattern.base":
          "Password must contain uppercase, lowercase, number and special character",
      }),
  }).required(),
});
