# Hosted macOS distribution

RemoteOS should support two separate macOS host flows:

- Hosted product flow: download a signed, notarized `.dmg` and connect to the hosted control plane.
- Open-source/local flow: run the host locally from source with `swift run --package-path apps/macos`.

Do not collapse those into one install path. The downloadable app should exist for the hosted product, while the source-based flow remains the OSS/local path.

## Hosted release build

The hosted build is assembled from the existing Swift package and packaged into a standalone `.app` without changing the local developer workflow.

Run:

```bash
REMOTEOS_CONTROL_PLANE_BASE_URL=https://your-hosted-control-plane.example.com \
REMOTEOS_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
REMOTEOS_NOTARY_APPLE_ID="you@example.com" \
REMOTEOS_NOTARY_APPLE_PASSWORD="app-specific-password" \
REMOTEOS_NOTARY_TEAM_ID="TEAMID" \
apps/macos/scripts/package_hosted_app.sh
```

Artifacts land in `dist/macos-hosted/`:

- `RemoteOS.app`
- `RemoteOS.zip`
- `RemoteOS.dmg`
- `SHA256SUMS.txt`

## Required environment

- `REMOTEOS_CONTROL_PLANE_BASE_URL`
  - Required.
  - Should point at the hosted control plane.
  - Must use `https://` unless you intentionally override with `REMOTEOS_ALLOW_INSECURE_BASE_URL=1` for testing.
- `REMOTEOS_SIGNING_IDENTITY`
  - Optional for local verification.
  - Required for public distribution.
  - If omitted, the packaging script will auto-select a stable local signing identity when one is available.
  - If the script falls back to ad-hoc signing, macOS permissions like Accessibility and Screen Recording can be invalidated on every rebuild.
- `REMOTEOS_NOTARY_PROFILE` or `REMOTEOS_NOTARY_APPLE_ID` + `REMOTEOS_NOTARY_APPLE_PASSWORD` + `REMOTEOS_NOTARY_TEAM_ID`
  - Optional for local verification.
  - Required for public distribution.

## CI / GitHub Releases

The repository includes `.github/workflows/release-macos-hosted.yml` for hosted release builds.

Required GitHub secrets:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `MACOS_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

Required GitHub variable:

- `REMOTEOS_HOSTED_CONTROL_PLANE_BASE_URL`

Publish via:

- `workflow_dispatch` for manual releases
- GitHub `release.published` to attach artifacts to a tagged release automatically

## Local OSS run

The source-based local flow remains:

```bash
swift run --package-path apps/macos
```

That path is for open-source and local development. It intentionally stays separate from the hosted downloadable build.
