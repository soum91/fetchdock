FetchDock's first native iOS build.

- Persistent download queue, pause/resume and retry
- Background file transfers, speed and remaining time
- Lock Screen and Dynamic Island Live Activity
- Built-in browser with file download detection
- Files access, preview and sharing

Requires iOS 18+. This IPA must be signed with your sideloading tool. Keep the activity extension enabled. Reuse the same signing identity and bundle ID for updates.

iOS controls progress refreshes while the app is suspended. Server support determines whether a paused download resumes or restarts. This release uses one connection per file.
