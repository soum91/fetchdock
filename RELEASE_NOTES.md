FetchDock 1.1: browser session handling across websites.

- Address-bar navigation and Reload read the browser's current cookies, including HTTP-only session cookies, and attach only cookies valid for the destination.
- Shared cookie handling for webpage requests and file transfers, with no GitHub-specific URL interception.
- File detection uses the server response, supporting extensionless download links and redirects.
- HTTP error pages stay visible in the browser rather than being saved as file attachments.
- Regression coverage for authenticated extensionless links, cross-host redirect isolation, cookie scope/expiry, and native download integrity. Real account sessions still need device verification.

- Download with FetchDock in the iOS share sheet, using system background transfers
- Safari Companion: file-link discovery and optional capture on chosen websites
- Gecko/Reynard companion developer package, with bundled fork integration
- Existing queues, pause/resume, Files sharing and Live Activities

Requires iOS 18+. Keep Activity, Share and Safari extensions enabled when signing. The app and Share extension need compatible App Group signing. Open FetchDock to start the Live Activity after a share. iOS controls background refresh frequency.

Remote transfers use HTTPS. Browser cookies aren't exported by external companions. This release uses one connection per file.
