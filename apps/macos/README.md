# RemoteOSHost

This package contains the initial macOS host shell for RemoteOS.

Run it locally with:

```bash
swift run --package-path apps/macos
```

Build the downloadable hosted app with:

```bash
REMOTEOS_CONTROL_PLANE_BASE_URL=https://your-hosted-control-plane.example.com \
apps/macos/scripts/package_hosted_app.sh
```

That packaged `.app` / `.dmg` flow is for the hosted product. The `swift run` flow remains the open-source and local-development path.

Default connection settings are bundled in
`Sources/RemoteOSHost/Resources/DefaultConfiguration.plist`.
Editing that file changes the app-wide default control-plane target and mode.
Saving from the Settings window creates a Mac-local override; use `Reset connection to app defaults`
in Settings to go back to the plist values.

The host currently provides:

- permission onboarding for Screen Recording and Accessibility
- broker registration and pairing code generation
- visible-window publication
- screenshot-backed frame publishing
- local audit traces and a hard-stop control
