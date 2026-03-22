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

The initial implementation supports:

- pairing-based device registration through the control-plane
- a mobile-first deck and selected-window view
- shared JSON-RPC contracts for manual input, semantic snapshots, approvals, and delegation
- a Swift host foundation for permissions, window inventory, screenshots, and broker connectivity

## Notes

- The macOS host is distributed outside the Mac App Store.
- Screen Recording and Accessibility are baseline permissions.
- Hosted and direct OSS modes share the same protocol; the direct path can run the control-plane locally for development.
