# RemoteOSHost

This package contains the initial macOS host shell for RemoteOS.

Run it locally with:

```bash
swift run --package-path apps/macos
```

The host currently provides:

- permission onboarding for Screen Recording and Accessibility
- broker registration and pairing code generation
- visible-window publication
- screenshot-backed frame publishing
- local audit traces and a hard-stop control
