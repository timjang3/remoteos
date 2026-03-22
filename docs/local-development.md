# Local Development

## Prerequisites

- Node.js 18+
- pnpm 10+
- Swift 6.0+ / Xcode (for the macOS host app)

## Setup

```bash
pnpm install
pnpm build
```

## Running Locally

Start all three services in separate terminals:

```bash
# Terminal 1 — Control-plane (API + WebSocket broker, port 8787)
pnpm --filter @remoteos/control-plane dev

# Terminal 2 — Web client (Vite, port 5173)
pnpm --filter @remoteos/web dev

# Terminal 3 — macOS host app
swift run --package-path apps/macos
```

The macOS app will prompt for **Screen Recording** and **Accessibility** permissions on first launch.

## Testing from Your Phone (LAN)

To test the web client on a physical phone without deploying anything:

### 1. Find your Mac's local IP

```bash
ipconfig getifaddr en0
```

This gives you something like `192.168.x.x`.

### 2. Start services with your LAN IP

```bash
# Terminal 1 — Control-plane
PUBLIC_PAIR_BASE_URL=http://<YOUR_IP>:5173 pnpm --filter @remoteos/control-plane dev

# Terminal 2 — Web client (--host exposes it on your network)
cd apps/web && npx vite --host

# Terminal 3 — macOS host app
swift run --package-path apps/macos
```

### 3. Open on your phone

Make sure your phone is on the **same Wi-Fi network** as your Mac, then open:

```
http://<YOUR_IP>:5173
```

The web client auto-detects the control-plane at `<YOUR_IP>:8787` based on the hostname you're accessing from — no extra config needed.

### 4. Pair

1. The macOS host app displays a **6-digit pairing code**
2. Enter it in the web UI on your phone
3. You're connected

## Ports

| Service        | Port | Bind address |
| -------------- | ---- | ------------ |
| Control-plane  | 8787 | 0.0.0.0      |
| Web client     | 5173 | localhost (default) / 0.0.0.0 (with `--host`) |

## Environment Variables (Control-plane)

| Variable               | Default                    | Description                        |
| ---------------------- | -------------------------- | ---------------------------------- |
| `HOST`                 | `0.0.0.0`                 | Server bind address                |
| `PORT`                 | `8787`                     | Server port                        |
| `PUBLIC_PAIR_BASE_URL` | `http://localhost:5173`    | Base URL for pairing links         |
| `PUBLIC_HTTP_BASE_URL` | Inferred from pair URL     | Public HTTP URL for the API        |
| `PUBLIC_WS_BASE_URL`   | Inferred from pair URL     | Public WebSocket URL               |

## Useful Commands

```bash
pnpm build          # Build everything
pnpm dev            # Run all dev servers in parallel (localhost only)
pnpm test           # Run all tests
pnpm typecheck      # Type-check all packages
```
