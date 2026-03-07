import { Request, Response, NextFunction } from "express";
import { AppError } from "../utils/appError";
import logger from "../utils/logger";
import config from "../config/env";
import { DatabaseError } from "pg";

interface ErrorResponse {
  status: string;
  message: string;
}

const handleJWTError = (): AppError => new AppError("Invalid token. Please log in again.", 401);

const handleJWTExpiredError = (): AppError =>
  new AppError("Your token has expired. Please log in again.", 401);

const handleDBError = (err: DatabaseError): AppError => {
  // Unique constraint violation
  if (err.code === "23505") {
    const columnMatch = err.detail?.match(/\((.*?)\)=/);
    const column = columnMatch?.[1];

    return new AppError(
      column ? `${column} already exists. Please use a different value.` : "Duplicate field value.",
      400,
    );
  }

  // Foreign key violation
  if (err.code === "23503") {
    const columnMatch = err.detail?.match(/\((.*?)\)=/);
    const column = columnMatch?.[1];

    return new AppError(
      column
        ? `Invalid reference for "${column}". Resource not found.`
        : "Referenced resource not found.",
      400,
    );
  }

  // Invalid input syntax
  if (err.code === "22P02") {
    return new AppError("Invalid input syntax.", 400);
  }

  // Undefined column
  if (err.code === "42703") {
    const columnMatch = err.message.match(/column "(.+?)"/);
    const column = columnMatch?.[1];

    return new AppError(
      column ? `Column "${column}" does not exist.` : "Invalid column in query.",
      400,
    );
  }

  // SQL syntax error
  if (err.code === "42601") {
    return new AppError("Database query syntax error.", 400);
  }

  return new AppError("Database error occurred.", 500);
};

const sendErrorDev = (err: AppError, res: Response): void => {
  const response: ErrorResponse = {
    status: err.status,
    message: err.message,
  };

  res.status(err.statusCode).json({
    ...response,
    stack: err.stack,
  });
};

const sendErrorProd = (err: AppError, res: Response): void => {
  if (err.isOperational) {
    res.status(err.statusCode).json({
      status: err.status,
      message: err.message,
    });
  } else {
    logger.error("UNEXPECTED ERROR:", err);

    res.status(500).json({
      status: "error",
      message: "Internal server error",
    });
  }
};

export const errorHandler = (
  err: Error,
  _req: Request,
  res: Response,
  _next: NextFunction,
): void => {
  let error =
    err instanceof AppError ? err : new AppError(err.message || "Internal Server Error", 500);

  const dbError = err as DatabaseError;

  if (err.name === "JsonWebTokenError") error = handleJWTError();
  if (err.name === "TokenExpiredError") error = handleJWTExpiredError();

  if (dbError.code && ["23505", "23503", "22P02", "42703", "42601"].includes(dbError.code)) {
    error = handleDBError(dbError);
  }

  logger.error(`[${error.statusCode}] ${error.message}`);
  if (config.nodeEnv === "development") {
    sendErrorDev(error, res);
  } else {
    sendErrorProd(error, res);
  }
};

export const notFound = (req: Request, _res: Response, next: NextFunction): void => {
  next(new AppError(`Route ${req.originalUrl} not found`, 404));
};

