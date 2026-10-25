FetchDock: segmented parallel transfers.

- Four connections per supported file by default; choose 1 through 8 in Settings independently of the number of simultaneous files.
- Validates exact Content-Range, byte counts, identity encoding and strong ETag before joining chunks. Unsupported ranges, changed validators and bad range replies fall back to a fresh single connection.
- Completed segments survive pause and restart. Unfinished segments restart when resumed.
- Segments use system background URLSession downloads; assembly streams to disk.
- Existing queues, browser sessions, Live Activities and single-connection share-sheet transfers remain supported.

FetchDock 1.1: browser session handling across websites.

- Address-bar navigation and Reload establish the destination's first-party context. WebKit uses its persistent cookie store for each request and redirect, including HTTP-only login cookies.
- Native file transfers read matching cookies from that same browser store, with no GitHub-specific URL interception.
- File detection uses the server response, supporting extensionless download links and redirects.
- HTTP error pages stay visible in the browser rather than being saved as file attachments.
- Regression coverage for authenticated extensionless links, cross-host redirect isolation, cookie scope/expiry, and native download integrity. Real account sessions still need device verification.

- Download with FetchDock in the iOS share sheet, using system background transfers
- Safari Companion: file-link discovery and optional capture on chosen websites
- Gecko/Reynard companion developer package, with bundled fork integration
- Existing queues, pause/resume, Files sharing and Live Activities

Requires iOS 18+. Keep Activity, Share and Safari extensions enabled when signing. The app and Share extension need compatible App Group signing. Open FetchDock to start the Live Activity after a share. iOS controls background refresh frequency.

Remote transfers use HTTPS. Browser cookies aren't exported by external companions. This release uses one connection per file.
