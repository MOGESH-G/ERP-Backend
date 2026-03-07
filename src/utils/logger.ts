import winston from "winston";
import config from "../config/env";

const { combine, timestamp, errors, colorize, printf } = winston.format;

const logFormat = printf(({ level, message, timestamp, stack }) => {
  return `[${level}] ${timestamp} ${stack || message}`;
});

const logger = winston.createLogger({
  level: config.nodeEnv === "development" ? "debug" : "info",
  format: combine(timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), errors({ stack: true }), logFormat),
  defaultMeta: { service: "express-ts-app" },
  transports: [
    new winston.transports.File({ filename: "logs/error.log", level: "error" }),
    new winston.transports.File({ filename: "logs/combined.log" }),
  ],
});

if (config.nodeEnv !== "production") {
  logger.add(
    new winston.transports.Console({
      format: combine(colorize(), timestamp({ format: "YYYY-MM-DD HH:mm:ss" }), logFormat),
    }),
  );
}

export default logger;
