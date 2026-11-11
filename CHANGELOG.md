# Changelog

This log records verified, release-specific changes. The [Factual release changelog](.github/workflows/release-changelog.yml) GitHub Action adds entries based on the actual commits between published releases. Entries are not fabricated for older versions that have not been audited.


## Share-sheet and filename repair

FetchDock share-sheet and filename repair

- When App Group storage is unavailable after signing, Download now performs the transfer inside the share extension and presents the native Files export picker. Removed the failed app-launch handoff and its false success message.
- App Group installations retain background share transfers.
- Removed UUID prefixes from parallel, shared-import, and legacy completed-file destinations. Name collisions use readable numeric suffixes.
- Invoke the existing migration on startup and include older eight-character UUID prefixes.
- Restore missing actionItem state used by completed-file actions.

Validation: installed-version source contract passed locally. Device share-sheet and Files export behavior still require signed-device verification. Fallback downloads require keeping the share sheet open and save to Files rather than the app queue.
