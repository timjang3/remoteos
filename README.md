# RemoteOS

RemoteOS is a local-first remote-control stack for a Mac, with a phone-first web client and an experimental selected-window delegate.

## Workspace

- `apps/control-plane`: Fastify bootstrap API and JSON-RPC WebSocket broker
- `apps/web`: mobile-first React + Vite PWA client
- `apps/macos`: SwiftUI/AppKit host app package
- `packages/contracts`: shared protocol and domain schemas
- `packages/ui-web`: shared React UI primitives
- `swift-packages/AppCore`: shared macOS host services and models

## Quick start

```bash
pnpm install
pnpm build
pnpm --filter @remoteos/control-plane dev
pnpm --filter @remoteos/web dev
```

For the macOS host:

```bash
swift run --package-path apps/macos
```

## Control-plane modes

RemoteOS keeps the open-source and hosted flows in the same repo.

- Default OSS/local mode: leave `AUTH_MODE` unset or set it to `none`. The control-plane runs without auth and uses the in-memory store unless you also provide `DATABASE_URL`.
- Persistent OSS/local mode: set `DATABASE_URL` to use Postgres with the same control-plane API, but keep `AUTH_MODE=none`.
- Hosted mode: set `AUTH_MODE=required` and provide `DATABASE_URL`, `BETTER_AUTH_SECRET`, and `ALLOWED_ORIGINS`. Google sign-in uses `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.

Hosted mode uses Better Auth for the web app and a one-time browser approval flow for new Macs. Sign in on the web, approve the Mac enrollment page that opens from the app, and then let the Mac reconnect with its saved device identity.

For local Google OAuth, configure the Google redirect URI as `http://localhost:8787/api/auth/callback/google`.

Database helpers for the control-plane:

```bash
pnpm --filter @remoteos/control-plane db:generate
pnpm --filter @remoteos/control-plane db:migrate
pnpm --filter @remoteos/control-plane db:push
```

The initial implementation supports:

- pairing-based device registration through the control-plane
- a mobile-first deck and selected-window view
- shared JSON-RPC contracts for manual input, semantic snapshots, approvals, and delegation
- a Swift host foundation for permissions, window inventory, screenshots, and broker connectivity

## Notes

- The macOS host is distributed outside the Mac App Store.
- Screen Recording and Accessibility are baseline permissions.
- Hosted and direct OSS modes share the same protocol; the direct path can run the control-plane locally for development.
