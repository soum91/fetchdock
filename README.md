# FetchDock

Native SwiftUI download manager for iPhone and iPad. Minimum iOS 18.0.

- Paste multiple HTTPS file links into a persistent download queue.
- One to six simultaneous files, pause/resume, retry, speed, byte counts and estimated remaining time.
- Background URLSession transfers with relaunch reconciliation and protected queue/resume storage.
- Lock Screen and Dynamic Island Live Activity showing the current file and active transfer count.
- Built-in WebKit browser with file download interception and applicable browser cookies for authenticated links.
- Quick Look previews, sharing, and Files > On My iPhone > FetchDock > Downloads.
- Stable application ID `com.soum91.fetchdock`; activity extension `com.soum91.fetchdock.activity`.

## Install

GitHub Actions tests and builds each main-branch change, then publishes an **ad-hoc signed IPA** in Releases. Sign/install it using your sideloading tool. Keep the same signing identity and bundle identifier for subsequent updates to preserve app data. Keep the Live Activity extension included when signing.

The AltStore / SideStore / FlareStore source is `https://raw.githubusercontent.com/soum91/fetchdock/main/source.json`. It becomes installable after the first successful release. Each source version and both bundled Info.plist versions include the build number so installers recognize updates.

## Background behavior

Downloads use Apple's background transfer service, not a foreground timer. iOS can suspend the app and coalesce progress callbacks, so the Live Activity can lag until the next callback or app activation. It does not promise continuous second-by-second refresh while suspended. No audio/location workaround or remote push server is used. Force-quitting the app cancels its system-managed transfers; reopening retries interrupted downloads. Resume data is used when the server supports it; otherwise a transfer may restart.

This first version uses **one connection per file**, not segmented range acceleration. It handles regular HTTPS files, not arbitrary video-site extraction, blob URLs or DRM streams. The browser hands a GET URL and its applicable cookies to the background session; POST-only exports and some one-time links require the site's own export flow. Deleting an entry deletes its local file. Unknown-size transfers show bytes without an invented percentage.

Cellular preference applies when creating new requests. Existing resume data may retain the previous network policy.

Remote file transfers require HTTPS. HTTP browsing remains available inside WebKit; HTTP loopback downloads are permitted for local tools and simulator tests. The native transfer session has no broad ATS exception. Browser download headers and links are stored locally with file protection and cleared from completed entries. No credentials or signing keys are included in this repository.

## Build and test

On macOS with Xcode and XcodeGen:

```sh
brew install xcodegen
xcodegen generate
python3 Tests/server.py
# In another terminal, select an installed iPhone simulator:
xcodebuild test -project FetchDock.xcodeproj -scheme FetchDock -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

The test suite validates URL handling, filename sanitization, queue serialization, real HTTP file integrity, HTTP failures, and pause/relaunch-reconciliation/resume behavior using the local server. Integration tests inject a regular delegate URLSession and isolated temporary storage because the hosted simulator cannot reliably connect to nsurlsessiond. Production initialization always uses a background session. Device testing remains necessary for system-managed background transfer scheduling, actual Lock Screen refreshes and sideload signing.

## Share sheet and browser companions (1.1)

Keep **all three extensions** (Activity, Share, Safari) when signing. The app and Share extension must retain the same `group.com.soum91.fetchdock` App Group entitlement. FetchDock Settings reports whether shared storage is available. Existing app and Activity bundle identifiers stay unchanged for upgrades.

- **Share sheet:** long-press a file link in Safari/Chrome/Reynard, Share, then **Download with FetchDock**. Choose Download in the sheet. Transfers start through the system background service without an unsupported attempt to launch the parent app. Open FetchDock to see progress and start its Live Activity. Normal webpage URLs save HTML, not a file hidden behind the page.
- **Safari:** Settings > Apps > Safari > Extensions > FetchDock Companion. Enable it and allow it on your chosen websites. Open its menu to see detected file/media links or send the current URL. Enable **Catch file links on this site** to show a FetchDock choice when clicking ordinary file links. This is off by default and stored per origin.
- **Reynard:** `FetchDock-Reynard.xpi` is built from the same companion source. The fork's bundled integration is used because its normal add-on installer requires Mozilla-signed packages; the release XPI is an unsigned developer package, not a claim that AMO signing has been completed.

The companions send only the file URL through `fetchdock://download?url=...`. They do not export browser cookies or history. Login-only downloads may need FetchDock's built-in browser. Blob URLs, DRM streams, POST-only exports and arbitrary JavaScript download buttons aren't intercepted. This integration runs on the same iPhone/iPad; it does not transfer a TV browser's downloads to a phone.

Run `node --test ExtensionTests/*.test.cjs` for companion URL policy tests and `python3 scripts/package_extensions.py` to regenerate Safari resources and the Reynard XPI before running XcodeGen.
