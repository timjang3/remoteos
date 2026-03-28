# RemoteOS

Control your Mac from your phone

## About

RemoteOS lets you control your Mac from your phone. A native macOS host app streams your screen to a mobile web client, connected through a lightweight control-plane broker. AI agents (currently supports Codex) can analyze what's on screen and execute actions on your behalf.

- **Remote input** — tap, drag, scroll, and type into any Mac window
- **Live streaming** — real-time screen capture sent to your phone
- **AI agent** — Codex reads your screen, plans actions, and executes them with human approval
- **Device pairing** — QR code or 6-digit code, with optional Google sign-in for hosted setups
- **PWA support** — installable as a progressive web app

## Download

### Hosted (recommended)

Download the latest signed and notarized `.dmg` from [GitHub Releases](https://github.com/timjang3/remoteos/releases). Open the disk image and drag RemoteOS into your Applications folder.

**Requirements:** macOS 14+ (Sonoma or later). You will be prompted to grant Screen Recording and Accessibility permissions on first launch.

### From source

If you prefer to build from source or want to run the full stack locally:

```bash
# Clone the repo
git clone https://github.com/timjang3/remoteos.git
cd remoteos

# Install dependencies and build
pnpm install
pnpm build

# Start the control plane and web client
pnpm --filter @remoteos/control-plane dev
pnpm --filter @remoteos/web dev
```

Then run the macOS host:

```bash
swift run --package-path apps/macos
```

## Architecture

```
apps/
  control-plane/   Fastify API + JSON-RPC WebSocket broker
  web/             Mobile-first React + Vite PWA client
  macos/           SwiftUI/AppKit host app

packages/
  contracts/       Shared protocol and domain schemas
  ui-web/          Shared React UI primitives

swift-packages/
  AppCore/         Shared macOS host services and models
```

## Control-plane modes

RemoteOS keeps the open-source and hosted flows in the same repo.

| Mode                 | Config                                                                        | Description                                                                                 |
| -------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Local (default)**  | `AUTH_MODE` unset or `none`                                                   | No auth, in-memory store. Good for development.                                             |
| **Local + Postgres** | `DATABASE_URL` + `TOKEN_HASH_SECRET`, `AUTH_MODE=none`                        | Persistent storage, no auth.                                                                |
| **Hosted**           | `AUTH_MODE=required`, `DATABASE_URL`, `BETTER_AUTH_SECRET`, `ALLOWED_ORIGINS` | Full auth with Google sign-in. Non-local deployments require HTTPS/WSS for all public URLs. |

Hosted mode uses Better Auth for the web app and a one-time browser approval flow for new Macs. Sign in on the web, approve the Mac enrollment page that opens from the app, and then let the Mac reconnect with its saved device identity.

The control-plane binds to `127.0.0.1` by default. Set `HOST=0.0.0.0` to expose it on the LAN.

For local Google OAuth, configure the redirect URI as `http://localhost:8787/api/auth/callback/google`.

**Database helpers:**

```bash
pnpm --filter @remoteos/control-plane db:generate
pnpm --filter @remoteos/control-plane db:migrate
pnpm --filter @remoteos/control-plane db:push
```

## Packaging a hosted build

To produce a signed `.dmg` for distribution:

```bash
REMOTEOS_CONTROL_PLANE_BASE_URL=https://your-hosted-control-plane.example.com \
apps/macos/scripts/package_hosted_app.sh
```

CI handles code signing, notarization, and publishing to GitHub Releases automatically. Keep signing certificates and notary credentials in GitHub Secrets — never commit them to the repo.

## License

See [LICENSE](LICENSE) for details.
