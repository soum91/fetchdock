FetchDock 1.1: authenticated GitHub release links.

- Typed and tapped GitHub release asset links enter the download queue directly with matching cookies from FetchDock's browser, including HTTP-only login cookies.
- Address-bar webpage loads set the main document context and bypass stale local responses.
- HTTP error pages remain visible in the browser rather than being mistaken for file attachments.
- Regression coverage for saved browser session handoff, cookie scope, and an authenticated download redirect. Private GitHub account behavior still needs device verification.

- Download with FetchDock in the iOS share sheet, using system background transfers
- Safari Companion: file-link discovery and optional capture on chosen websites
- Gecko/Reynard companion developer package, with bundled fork integration
- Existing queues, pause/resume, Files sharing and Live Activities

Requires iOS 18+. Keep Activity, Share and Safari extensions enabled when signing. The app and Share extension need compatible App Group signing. Open FetchDock to start the Live Activity after a share. iOS controls background refresh frequency.

Remote transfers use HTTPS. Browser cookies aren't exported by external companions. This release uses one connection per file.
