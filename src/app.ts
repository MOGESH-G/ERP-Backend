import express, { Application } from "express";
import helmet from "helmet";
import cors from "cors";
import morgan from "morgan";
import compression from "compression";
import rateLimit from "express-rate-limit";
import hpp from "hpp";
import config from "./config/env";
import routes from "./routes";
import { errorHandler, notFound } from "./middlewares/errorHandler";
import logger from "./utils/logger";

const app: Application = express();

// ─── Security Middlewares ────────────────────────────────────────────────────
// Set security HTTP headers
app.use(helmet());

// Enable CORS
// app.use(
//   cors({
//     origin: config.cors.origin,
//     methods: ["GET", "POST", "PUT", "PATCH", "DELETE"],
//     allowedHeaders: ["Content-Type", "Authorization"],
//     credentials: true,
//   }),
// );

app.use(
  cors({
    origin: true,
    credentials: true,
  }),
);

// Rate limiting
const limiter = rateLimit({
  windowMs: config.rateLimit.windowMs,
  max: config.rateLimit.max,
  standardHeaders: true,
  legacyHeaders: false,
  message: { status: "fail", message: "Too many requests, please try again later." },
});

app.use("/api", limiter);

// ─── Body Parsing ────────────────────────────────────────────────────────────
app.use(express.json({ limit: "10kb" }));
app.use(express.urlencoded({ extended: true, limit: "10kb" }));

// Prevent HTTP parameter pollution
app.use(hpp());

// ─── Compression ─────────────────────────────────────────────────────────────
app.use(compression());

// ─── Logging ─────────────────────────────────────────────────────────────────
if (config.nodeEnv === "development") {
  app.use(morgan("dev"));
} else {
  app.use(
    morgan("combined", {
      stream: { write: (message: string) => logger.info(message.trim()) },
    }),
  );
}

// ─── Routes ──────────────────────────────────────────────────────────────────
app.use(config.apiPrefix, routes);

// ─── Error Handling ──────────────────────────────────────────────────────────
app.use(notFound);
app.use(errorHandler);

export default app;

