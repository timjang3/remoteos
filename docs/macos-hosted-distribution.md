# Hosted macOS distribution

RemoteOS should support two separate macOS host flows:

- Hosted product flow: download a signed, notarized `.dmg` and connect to the hosted control plane.
- Open-source/local flow: run the host locally from source with `swift run --package-path apps/macos`.

Do not collapse those into one install path. The downloadable app should exist for the hosted product, while the source-based flow remains the OSS/local path.

## Public repo model

If the repository is public, keep the split explicit:

- Public:
  - source code
  - release workflow YAML
  - generic environment variable names
  - GitHub Releases metadata, version numbers, checksums, and the final `.dmg` / `.zip`
- Maintainer-only:
  - Apple signing certificate material
  - certificate passwords
  - notary credentials
  - any control-plane admin, database, or service secrets

Treat the hosted control-plane base URL as product configuration, not a secret. A shipped app can expose it through bundle inspection or normal network traffic, so do not rely on hiding it in the repository for security.

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
- `CODESIGN.txt`

## Required environment

- `REMOTEOS_CONTROL_PLANE_BASE_URL`
  - Required.
  - Should point at the hosted control plane.
  - Must use `https://` unless you intentionally override with `REMOTEOS_ALLOW_INSECURE_BASE_URL=1` for testing.
- `REMOTEOS_SIGNING_IDENTITY`
  - Optional for local verification.
  - Required for public distribution.
  - If omitted, the packaging script auto-detects a local signing identity for verification builds, preferring `Developer ID Application:` when available.
  - Public builds must keep the same bundle identifier and Developer ID designated requirement across releases. If those change, macOS TCC can treat the update as a different app and users may see Accessibility / Screen Recording enabled in Settings while the new build still fails permission checks.
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

- `workflow_dispatch` to build, notarize, and create or update a draft GitHub Release tagged `vX.Y.Z`
- GitHub `release.published` to attach artifacts to a published tagged release automatically

Recommended public distribution flow:

1. Keep the repo public.
2. Store signing and notary material only in GitHub Secrets.
3. Run the hosted release workflow from GitHub Actions.
4. Review the draft release notes and attached artifacts.
5. Publish the GitHub Release and link users to that release or its `.dmg`.

That gives end users a clean download surface without exposing maintainer-only credentials in the repo.

## Update behavior and privacy permissions

For normal drag-install updates and Sparkle updates, users should not need to re-grant Accessibility or Screen Recording as long as the new build is signed like the previous one. Apple’s code signing guidance treats a new version as the same program when it keeps the same identifier and designated requirement.

If users report that macOS still shows RemoteOS enabled but the app reports the permissions as missing, compare the old and new `codesign -dr -` output. The generated `CODESIGN.txt` artifact captures that information for each build.

## Local OSS run

The source-based local flow remains:

```bash
swift run --package-path apps/macos
```

That path is for open-source and local development. It intentionally stays separate from the hosted downloadable build.
