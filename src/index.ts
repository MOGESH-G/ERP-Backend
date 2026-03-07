import app from "./app";
import { connectMasterDB, loadAllTenantPools } from "./config/database";
import logger from "./utils/logger";

const PORT = parseInt(process.env.PORT || "3000", 10);

const startServer = async (): Promise<void> => {
  try {
    await connectMasterDB();

    await loadAllTenantPools();

    const server = app.listen(PORT, () => {
      logger.info(`🚀 Server running on port ${PORT}`);
      logger.info(`📡 API: http://localhost:${PORT}/api/v1`);
    });

    const shutdown = (signal: string): void => {
      logger.info(`${signal} received. Shutting down...`);
      server.close(() => {
        logger.info("Server closed");
        process.exit(0);
      });
    };

    process.on("SIGTERM", () => shutdown("SIGTERM"));
    process.on("SIGINT", () => shutdown("SIGINT"));

    process.on("unhandledRejection", (reason) => {
      logger.error("Unhandled Rejection:", reason);
      server.close(() => process.exit(1));
    });

    process.on("uncaughtException", (error) => {
      logger.error("Uncaught Exception:", error);
      process.exit(1);
    });
  } catch (error) {
    logger.error("Failed to start server:", error);
    process.exit(1);
  }
};

startServer();

