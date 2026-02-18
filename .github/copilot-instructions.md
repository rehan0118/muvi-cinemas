# Muvi Cinemas - AI Assistant Instructions

## Project Overview
Muvi Cinemas is a Saudi Arabian cinema chain's digital platform with 7 microservices, 481 API endpoints, and 23 third-party integrations.

## Architecture
- **Gateway** (NestJS 8.4, port 3000) — HTTP API Gateway, REST→gRPC proxy
- **Identity** (NestJS 8.4, port 5001) — Users, auth, OTP, permissions
- **Main** (NestJS 8.4, port 5002) — Films, cinemas, sessions, bookings, orders
- **Payment** (NestJS 8.4, port 5003) — HyperPay, PayFort, Checkout.com, Tabby, wallets
- **FB** (NestJS 9.4, port 5004) — Food menu, kiosk, concessions
- **Notification** (NestJS 8.4, port 5005) — OneSignal push, SendGrid email, SMS
- **Offer** (Go 1.24, port 5006) — Promotions, vouchers, student discounts

## Communication Patterns
- All inter-service calls use **gRPC** (HTTP/2)
- Gateway is the only public entry point
- 6 Bull queues (Redis-backed) for async processing
- Redis Pub/Sub for real-time payment events

## Key Integrations
- **Vista Entertainment** — Core cinema management (CRITICAL)
- **Payment Gateways** — HyperPay, PayFort, Checkout.com, Tabby
- **SMS/OTP** — Unifonic (primary), Taqnyat (alternative)
- **Push** — OneSignal, Braze
- **Email** — SendGrid
- **Storage** — AWS S3 + CloudFront CDN
- **Compliance** — ZATCA (Saudi e-invoicing)

## Tech Stack
- **Backend**: NestJS 8.4/9.4, TypeScript 4.3-4.7, Sequelize ORM
- **Go Service**: Go 1.24, GORM, gRPC
- **Databases**: PostgreSQL 15 (per-service DBs), Redis 7
- **Frontend**: Next.js (website), Vite+React (CMS)
- **Infrastructure**: AWS ECS Fargate, RDS, ElastiCache, S3, CloudFront

## Code Conventions
- Use Sequelize models (NOT TypeORM or Prisma)
- Use `@nestjsx/crud` for CRUD endpoints
- ULID for primary keys (not UUID or auto-increment)
- gRPC clients via `@grpc/grpc-js`
- All services load config from AWS SSM (skipped locally with NODE_ENV=local)

## File Locations
- Controllers: `src/<domain>/controllers/*.controller.ts`
- Services: `src/<domain>/services/*.service.ts`
- DTOs: `src/<domain>/dto/*.dto.ts`
- Entities: `src/<domain>/entities/*.entity.ts`
- gRPC Protos: `@alpha.apps/muvi-proto`
- Migrations: `database/migrations/*.js`

## Testing Locally
```powershell
.\muvi-up.ps1              # Full bootstrap
.\muvi-up.ps1 up           # Start all services
.\muvi-up.ps1 logs         # Tail all logs
.\muvi-up.ps1 restart      # Restart services
```

## Critical Flows
1. **Booking**: Gateway → Main (reserve seats) → Payment (create intent) → Webhook → Main (confirm) → Notification
2. **Auth**: Gateway → Identity (OTP via Unifonic/Taqnyat) → JWT tokens
3. **Vista Sync**: 15 cron jobs sync films, sessions, concessions from Vista

## Known Constraints
- F&B service uses NestJS 9.4 (others use 8.4) — version mismatch risk
- No cross-service DB access — services own their data
- Rate limiting: 100 req/60s default, 5 req/60s for orders
- Kiosk platform bypasses rate limiting

## Documentation
For deep context, read: `documentation/MUVI_SYSTEM_DOCUMENTATION.md`

## AI Behavior
You are a Senior Staff Engineer. When given a vague problem:
1. Investigate autonomously — search code, trace flows, find the relevant files yourself
2. Don't ask for files — use grep_search, file_search, read_file to find them
3. Provide root cause analysis with specific file:line references
4. Suggest fixes with complexity analysis (Big O before/after)
