# Privacy Policy

BackDesk is a local macOS menu bar utility. Its core behavior runs on your Mac and does not require an account or a custom backend service.

## What BackDesk Accesses

- Accessibility permission is used to observe mouse clicks and decide whether a click landed on empty desktop wallpaper.
- Window metadata may be inspected locally to avoid interfering with normal apps, Dock, menus, screenshots, and overlays.
- Local settings are stored in macOS UserDefaults.
- Diagnostic logs are written locally to `~/Library/Application Support/BackDesk/backdesk.log`.

## Network Access

BackDesk may request GitHub Releases metadata to check whether a newer version is available. This request is only used for update prompts and does not upload logs, settings, window titles, or personal files.

BackDesk does not run its own analytics service and does not send diagnostic logs automatically.

## Feedback

The feedback menu opens GitHub Issues in your browser. If you choose to submit an issue, only the text you submit on GitHub is shared.

Please review logs before pasting them into public issues. Logs can include timing, coordinates, process names, or other context useful for debugging.
