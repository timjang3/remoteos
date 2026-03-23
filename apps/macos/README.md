# RemoteOSHost

This package contains the initial macOS host shell for RemoteOS.

Run it locally with:

```bash
swift run --package-path apps/macos
```

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
