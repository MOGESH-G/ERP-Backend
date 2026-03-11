import Joi from "joi";

export const loginSchema = Joi.object({
  email: Joi.string().trim().email().lowercase().required(),
  password: Joi.string()
    .min(6)
    .pattern(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])/)
    .required()
    .messages({
      "string.pattern.base":
        "Password must contain uppercase, lowercase, number and special character",
    }),
});
