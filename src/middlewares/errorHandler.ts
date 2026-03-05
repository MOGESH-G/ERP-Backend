import { Request, Response, NextFunction } from 'express';
import { AppError } from '../utils/appError';
import logger from '../utils/logger';
import config from '../config/env';

interface ErrorResponse {
  status: string;
  message: string;
  stack?: string;
  errors?: unknown;
}

const handleJWTError = (): AppError =>
  new AppError('Invalid token. Please log in again.', 401);

const handleJWTExpiredError = (): AppError =>
  new AppError('Your token has expired. Please log in again.', 401);

const handleDBError = (err: NodeJS.ErrnoException): AppError => {
  if (err.code === '23505') return new AppError('Duplicate field value. Please use a different value.', 400);
  if (err.code === '23503') return new AppError('Referenced resource not found.', 400);
  if (err.code === '22P02') return new AppError('Invalid input syntax.', 400);
  return new AppError('Database error occurred.', 500);
};

const sendErrorDev = (err: AppError, res: Response): void => {
  const response: ErrorResponse = {
    status: err.status,
    message: err.message,
    stack: err.stack,
  };
  res.status(err.statusCode).json(response);
};

const sendErrorProd = (err: AppError, res: Response): void => {
  if (err.isOperational) {
    res.status(err.statusCode).json({ status: err.status, message: err.message });
  } else {
    logger.error('UNEXPECTED ERROR:', err);
    res.status(500).json({ status: 'error', message: 'Something went wrong' });
  }
};

export const errorHandler = (
  err: Error,
  _req: Request,
  res: Response,
  _next: NextFunction
): void => {
  let error = err instanceof AppError
    ? err
    : new AppError(err.message || 'Internal Server Error', 500);

  const errCode = (err as NodeJS.ErrnoException).code;

  if (err.name === 'JsonWebTokenError') error = handleJWTError();
  if (err.name === 'TokenExpiredError') error = handleJWTExpiredError();
  if (errCode && ['23505', '23503', '22P02'].includes(errCode)) error = handleDBError(err as NodeJS.ErrnoException);

  logger.error(`[${error.statusCode}] ${error.message}`);

  if (config.nodeEnv === 'development') {
    sendErrorDev(error, res);
  } else {
    sendErrorProd(error, res);
  }
};

export const notFound = (req: Request, _res: Response, next: NextFunction): void => {
  next(new AppError(`Route ${req.originalUrl} not found`, 404));
};
