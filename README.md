# Cornell Note for iPad

Cornell Note for iPad targets iPadOS 17+ as a local-first, on-device app. Mac integration, a cloud backend, and authentication are not initial requirements.

The initial version is in development with SwiftUI, PencilKit, and SwiftData. Local notebooks, drawing autosave with save/read protection, backup export and restore, and the startup recovery check are implemented. Editor color, line width, undo/redo, two-finger gestures, the settings/backup screen, thumbnail updates, and on-device acceptance remain.

Build and run the tests on an iPad simulator without signing:

```sh
xcodebuild -project CornellNote.xcodeproj -scheme CornellNote \
  -destination 'platform=iOS Simulator,name=iPad (A16)' \
  CODE_SIGNING_ALLOWED=NO test
```

## Product reference

The product specification source of truth is the private `Cornell-Note/product` repository:

- Exact specification path: `doc/ipados/requirements/IPADOS_HANDWRITING_APP_SPEC.md`
- Approved product commit: `4c8dde0b8fc65a40668807b81f8316f699fe0103`

The revision pin is defined by four fields: path, commit SHA, change/impact, and verification. The pinned path is read from the approved commit; the change/impact is the iPadOS reference-only boundary; verification requires the commit and path to be available as Git objects.

This repository has no package dependency, CI configuration, signing team, or App Store configuration.
