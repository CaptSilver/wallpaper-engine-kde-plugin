# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for security bugs in:

- The QtWebEngine wallpaper sandbox (web wallpapers can load arbitrary
  author HTML/JS — see `src/WebUrlInterceptor.cpp` and
  `src/SafeWallpaperBridge.cpp`).
- The SceneScript JavaScript engine (`src/backend_scene/qml_helper/SceneBackend.cpp`),
  including the per-origin `LocalStorage` quota enforced by
  `src/backend_scene/qml_helper/LocalStorageQuota.hpp`.
- Symlink / path-traversal in `src/FileHelper.cpp` (wallpaper config
  CRUD, HTML patching).
- Any in-process crash that could be triggered by a malicious workshop
  wallpaper.

Instead, please use GitHub's **Private vulnerability reporting** feature:

1. Go to https://github.com/CaptSilver/wallpaper-engine-kde-plugin/security
2. Click *Report a vulnerability*.
3. Fill in the form. GitHub encrypts the report in transit and the
   contents are only visible to repository maintainers.

We commit to:

- Acknowledging receipt within 7 days.
- Reproducing or rejecting (with reasoning) within 30 days.
- Crediting reporters in the release notes for the fix, unless they
  prefer anonymity.

## Supported versions

| Version | Supported                                    |
|---------|----------------------------------------------|
| 1.3.x   | Yes (current)                                |
| 1.2.x   | No — please upgrade (auto-migrates to 1.3)   |
| < 1.2   | No — catsout fork; unmaintained              |
