# FetchDock

Native SwiftUI download manager for iPhone and iPad. Minimum iOS 18.0.

- Paste multiple HTTP/HTTPS file links into a persistent download queue.
- One to six simultaneous files, pause/resume, retry, speed, byte counts and estimated remaining time.
- Background URLSession transfers with relaunch reconciliation and protected queue/resume storage.
- Lock Screen and Dynamic Island Live Activity showing the current file and active transfer count.
- Built-in WebKit browser with file download interception and applicable browser cookies for authenticated links.
- Quick Look previews, sharing, and Files > On My iPhone > FetchDock > Downloads.
- Stable application ID `com.soum91.fetchdock`; activity extension `com.soum91.fetchdock.activity`.

## Install

GitHub Actions tests and builds each main-branch change, then publishes an **unsigned IPA** in Releases. Sign/install it using your sideloading tool. Keep the same signing identity and bundle identifier for subsequent updates to preserve app data. Keep the Live Activity extension included when signing.

The AltStore / SideStore / FlareStore source is `https://raw.githubusercontent.com/soum91/fetchdock/main/source.json`. It becomes installable after the first successful release. Each source version includes the build number so installers recognize updates.

## Background behavior

Downloads use Apple's background transfer service, not a foreground timer. iOS can suspend the app and coalesce progress callbacks, so the Live Activity can lag until the next callback or app activation. It does not promise continuous second-by-second refresh while suspended. No audio/location workaround or remote push server is used. Force-quitting the app cancels its system-managed transfers; reopening retries interrupted downloads. Resume data is used when the server supports it; otherwise a transfer may restart.

This first version uses **one connection per file**, not segmented range acceleration. It handles regular HTTP files, not arbitrary video-site extraction, blob URLs or DRM streams. The browser hands a GET URL and its applicable cookies to the background session; POST-only exports and some one-time links require the site's own export flow. Deleting an entry deletes its local file. Unknown-size transfers show bytes without an invented percentage.

Cellular preference applies when creating new requests. Existing resume data may retain the previous network policy.

HTTP links are allowed for local devices and older servers, but are unencrypted. Browser download headers and links are stored locally with file protection and cleared from completed entries. No credentials or signing keys are included in this repository.

## Build and test

On macOS with Xcode and XcodeGen:

```sh
brew install xcodegen
xcodegen generate
python3 Tests/server.py
# In another terminal, select an installed iPhone simulator:
xcodebuild test -project FetchDock.xcodeproj -scheme FetchDock -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

The test suite validates URL handling, filename sanitization, queue serialization, real HTTP file integrity, HTTP failures, and pause/relaunch-reconciliation/resume behavior using the local server. Device testing remains necessary for actual Lock Screen background scheduling and sideload signing.
