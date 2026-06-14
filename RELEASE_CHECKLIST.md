# BackDesk Release Checklist

Use this checklist before publishing a public GitHub release.

## Version

- Update `VERSION` in `build.sh`.
- Update `CFBundleShortVersionString` in `Info.plist`.
- Update the version shown in `main.swift`.
- Add release notes to `CHANGELOG.md`.

## Build

- Run `swiftc -parse main.swift`.
- Run `./build.sh`.
- Confirm generated zip files exist for `universal`, `arm64`, and `x86_64`.
- Run `./Scripts/package-dmg.sh` when a drag-install DMG is needed.
- Install the universal build locally and re-enable Accessibility permission if macOS invalidates it.

## Smoke Test

- Single-click empty desktop wallpaper.
- Double-click empty desktop wallpaper.
- Click normal app UI and confirm BackDesk does not intercept.
- Click Dock icons and Dock side blank areas.
- Use a screenshot tool and confirm toolbar buttons are not penetrated.
- Open the BackDesk menu and run `检查更新...`.
- Run `复制诊断信息`.
- Run `反馈问题...`.

## Publish

- Commit source and documentation changes.
- Push `main`.
- Create and push an annotated tag matching the current version.
- Create a GitHub Release from the tag.
- Upload the generated zip files and DMG as release assets.
- Download the uploaded universal zip and launch it once to verify the asset.

## Future Signing

Before broad public distribution, add Developer ID signing and notarization so macOS Gatekeeper presents a trustworthy install experience.
