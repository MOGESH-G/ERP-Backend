import bcrypt from "bcryptjs";

const SALT_ROUNDS = 10;

export const Login = async (req: Request, res: Response) => {
  const { email, password } = req.body;

  const passwordHash = await bcrypt.hash(password, SALT_ROUNDS);
};
