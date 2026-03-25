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

For the hosted product download flow, package a signed macOS app bundle separately:

```bash
REMOTEOS_CONTROL_PLANE_BASE_URL=https://your-hosted-control-plane.example.com \
apps/macos/scripts/package_hosted_app.sh
```

## Downloads

If you keep this repository public, the clean split is:

- open-source users run the stack from source
- hosted-product users download the signed `.dmg` from GitHub Releases or your own download page

Do not commit packaged binaries into the repository. Publish the notarized artifacts from CI instead.

## Control-plane modes

RemoteOS keeps the open-source and hosted flows in the same repo.

- Default OSS/local mode: leave `AUTH_MODE` unset or set it to `none`. The control-plane runs without auth and uses the in-memory store unless you also provide `DATABASE_URL`.
- Persistent OSS/local mode: set `DATABASE_URL` to use Postgres with the same control-plane API, keep `AUTH_MODE=none`, and also set `TOKEN_HASH_SECRET`.
- Hosted mode: set `AUTH_MODE=required` and provide `DATABASE_URL`, `BETTER_AUTH_SECRET`, and `ALLOWED_ORIGINS`. For non-local deployments, `PUBLIC_PAIR_BASE_URL`, `PUBLIC_HTTP_BASE_URL`, `PUBLIC_WS_BASE_URL`, and every `ALLOWED_ORIGINS` entry must use HTTPS/WSS. Google sign-in uses `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.

Hosted mode uses Better Auth for the web app and a one-time browser approval flow for new Macs. Sign in on the web, approve the Mac enrollment page that opens from the app, and then let the Mac reconnect with its saved device identity.

The control-plane binds to `127.0.0.1` by default in every mode. Expose it off-host only by setting `HOST` explicitly, for example `HOST=0.0.0.0` for a LAN test box or the address your reverse proxy should listen on.

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

- Hosted macOS distribution is outside the Mac App Store and should be shipped as a signed, notarized download.
- In a public repo, keep signing certificates, notary credentials, and other release secrets only in GitHub Secrets.
- The hosted control-plane URL is product configuration, not a secret. Once you ship the app, users can inspect it from the bundle or network traffic.
- The open-source/local macOS flow remains source-based through `swift run --package-path apps/macos`.
- Screen Recording and Accessibility are baseline permissions.
- Hosted and direct OSS modes share the same protocol; the direct path can run the control-plane locally for development.
