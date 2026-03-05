import { Request, Response, NextFunction } from 'express';
import { query } from '../config/database';
import { sendSuccess, sendCreated, sendNoContent } from '../utils/apiResponse';
import { NotFoundError } from '../utils/appError';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import config from '../config/env';

interface User {
  id: string;
  name: string;
  email: string;
  password?: string;
  role: string;
  created_at: Date;
}

export const register = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const { name, email, password, role } = req.body as User & { password: string };

    const hashedPassword = await bcrypt.hash(password, 12);

    const users = await query<User>(
      `INSERT INTO users (name, email, password, role) VALUES ($1, $2, $3, $4)
       RETURNING id, name, email, role, created_at`,
      [name, email, hashedPassword, role]
    );

    const user = users[0];
    const token = jwt.sign({ id: user.id, email: user.email, role: user.role }, config.jwt.secret, {
      expiresIn: config.jwt.expiresIn,
    } as jwt.SignOptions);

    sendCreated(res, { user, token }, 'User registered successfully');
  } catch (err) {
    next(err);
  }
};

export const login = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const { email, password } = req.body as { email: string; password: string };

    const users = await query<User>(
      'SELECT * FROM users WHERE email = $1',
      [email]
    );

    const user = users[0];

    if (!user || !user.password || !(await bcrypt.compare(password, user.password))) {
      throw new NotFoundError('Invalid email or password');
    }

    const token = jwt.sign({ id: user.id, email: user.email, role: user.role }, config.jwt.secret, {
      expiresIn: config.jwt.expiresIn,
    } as jwt.SignOptions);

    delete user.password;
    sendSuccess(res, { user, token }, 'Login successful');
  } catch (err) {
    next(err);
  }
};

export const getUsers = async (_req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const users = await query<User>('SELECT id, name, email, role, created_at FROM users ORDER BY created_at DESC');
    sendSuccess(res, users, 'Users retrieved');
  } catch (err) {
    next(err);
  }
};

export const getUserById = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const users = await query<User>(
      'SELECT id, name, email, role, created_at FROM users WHERE id = $1',
      [req.params.id]
    );

    if (!users[0]) throw new NotFoundError('User not found');

    sendSuccess(res, users[0], 'User retrieved');
  } catch (err) {
    next(err);
  }
};

export const deleteUser = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const users = await query<User>('DELETE FROM users WHERE id = $1 RETURNING id', [req.params.id]);

    if (!users[0]) throw new NotFoundError('User not found');

    sendNoContent(res);
  } catch (err) {
    next(err);
  }
};
