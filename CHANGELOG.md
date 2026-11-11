# Changelog

## [build-37] - 2026-11-11

## Verified changes since build-26

- Use supported macOS 15 Intel runner for release ([`cfa94d32`](https://github.com/soum91/fetchdock/commit/cfa94d32268762152f060964255140b05db5ed54); `.github/workflows/build.yml`)
- Bound nonblocking simulator test duration for releases ([`7c0e9553`](https://github.com/soum91/fetchdock/commit/7c0e9553b21f30a0c9f1eea7fda5ddffe66c24b1); `.github/workflows/build.yml`)
- Repair share extension fallback and UUID filenames ([`667b7582`](https://github.com/soum91/fetchdock/commit/667b7582f34fa3e3f72eb41dd03bc6a26f4b67ce); `FetchDock/ContentView.swift`, `FetchDock/DownloadManager.swift`, `FetchDockShare/ShareViewController.swift`, and 1 more)
- Enforce visible installed version/build across app releases ([`3402e4ba`](https://github.com/soum91/fetchdock/commit/3402e4bae8e84ba7f1aca8eee1cd098e8e269a62); `.github/workflows/build.yml`, `.github/workflows/version-ui.yml`, `scripts/check_version_ui.py`, and 1 more)
- CI: move release build off retired macOS 13 runner ([`cda8cabf`](https://github.com/soum91/fetchdock/commit/cda8cabf40dd52c5a36b9a8dab29bbf4f868c2f7); `.github/workflows/build.yml`)
- Use Intel macOS runner for release builds ([`4a1c732b`](https://github.com/soum91/fetchdock/commit/4a1c732b0faec7d8065f6f181194a72c999a2217); `.github/workflows/build.yml`)
- Remove escaped newline from row action ([`73f27e7d`](https://github.com/soum91/fetchdock/commit/73f27e7d6e2b3d46f55daefea4b15ced8b38ce7f); `FetchDock/ContentView.swift`)
- Complete tappable file actions ([`2ab6ea57`](https://github.com/soum91/fetchdock/commit/2ab6ea572c75a52e3536bf5edc0f4686053aec9e); `FetchDock/ContentView.swift`)
- Make completed files tappable ([`f1c22bda`](https://github.com/soum91/fetchdock/commit/f1c22bdafc526b4d58e7d807d4f498be913627c2); `FetchDock/ContentView.swift`)
- Save downloads with readable filenames ([`d7dfdc17`](https://github.com/soum91/fetchdock/commit/d7dfdc17ec90cc30cebbf61782fcef9706441a50); `FetchDock/DownloadManager.swift`)

[Inspect exact code changes](https://github.com/soum91/fetchdock/compare/build-26...build-37)

This log records verified, release-specific changes. The [Factual release changelog](.github/workflows/release-changelog.yml) GitHub Action adds entries based on the actual commits between published releases. Entries are not fabricated for older versions that have not been audited.


## Share-sheet and filename repair

FetchDock share-sheet and filename repair

- When App Group storage is unavailable after signing, Download now performs the transfer inside the share extension and presents the native Files export picker. Removed the failed app-launch handoff and its false success message.
- App Group installations retain background share transfers.
- Removed UUID prefixes from parallel, shared-import, and legacy completed-file destinations. Name collisions use readable numeric suffixes.
- Invoke the existing migration on startup and include older eight-character UUID prefixes.
- Restore missing actionItem state used by completed-file actions.

Validation: installed-version source contract passed locally. Device share-sheet and Files export behavior still require signed-device verification. Fallback downloads require keeping the share sheet open and save to Files rather than the app queue.
