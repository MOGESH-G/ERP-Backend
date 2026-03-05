# Express TypeScript App

Production-ready Express.js API with TypeScript, security middleware, PostgreSQL, and JWT auth.

## Stack

| Category | Package |
|---|---|
| Framework | Express 4 + TypeScript 5 |
| Database | PostgreSQL via `pg` + `pg-pool` |
| Validation | Joi |
| Auth | JWT (`jsonwebtoken`) + bcrypt |
| Security | Helmet, CORS, HPP, express-mongo-sanitize, express-rate-limit |
| Logging | Winston + Morgan |
| Dev | Nodemon + ts-node |

## Project Structure

```
src/
├── config/
│   ├── env.ts          # Environment variables
│   ├── database.ts     # PostgreSQL pool
│   └── init.sql        # DB schema
├── controllers/
│   └── user.controller.ts
├── middlewares/
│   ├── auth.ts         # JWT authenticate + authorize
│   ├── validate.ts     # Joi validation middleware
│   └── errorHandler.ts # Global error handler
├── routes/
│   ├── index.ts
│   └── user.routes.ts
├── utils/
│   ├── appError.ts     # Custom error classes
│   ├── apiResponse.ts  # Response helpers
│   └── logger.ts       # Winston logger
├── validators/
│   └── user.validator.ts
├── app.ts              # Express app setup
└── index.ts            # Entry point
```

## Getting Started

```bash
# 1. Install dependencies
npm install

# 2. Set up environment
cp .env.example .env
# Edit .env with your values

# 3. Set up PostgreSQL database
psql -U postgres -d mydb -f src/config/init.sql

# 4. Start development server
npm run dev

# 5. Build for production
npm run build
npm start
```

## API Endpoints

```
GET    /api/v1/health          - Health check (public)

POST   /api/v1/users/register  - Register user (public)
POST   /api/v1/users/login     - Login (public)
GET    /api/v1/users           - List users (admin only)
GET    /api/v1/users/:id       - Get user (authenticated)
DELETE /api/v1/users/:id       - Delete user (admin only)
```

## Security Features

- **Helmet** – Sets secure HTTP headers
- **CORS** – Configurable origin whitelist
- **Rate Limiting** – 100 requests / 15 min per IP (configurable)
- **HPP** – HTTP Parameter Pollution prevention
- **express-mongo-sanitize** – NoSQL injection sanitization
- **Body size limit** – 10kb max request body
- **JWT Auth** – Bearer token authentication
- **bcrypt** – Password hashing (salt rounds: 12)
- **Joi** – Request validation with schema enforcement
