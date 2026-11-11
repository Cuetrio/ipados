# Cornell Note for iPad

Cornell Note for iPad targets iPadOS 17+ as a local-first, on-device app. Mac integration, a cloud backend, and authentication are not initial requirements.

The initial version is in development with SwiftUI, PencilKit, and SwiftData. The features in the specification are implemented: the library, the editor (tools, undo/redo, pinch zoom, landscape only), drawing autosave with save/read protection, the settings/backup screen with backup export and restore, thumbnail updates, and the startup recovery check. On-device acceptance on an iPad with Apple Pencil and the signing and release configuration remain.

Build and run the tests on an iPad simulator without signing:

```sh
xcodebuild -project CornellNote.xcodeproj -scheme CornellNote \
  -destination 'platform=iOS Simulator,name=iPad (A16)' \
  CODE_SIGNING_ALLOWED=NO test
```

## Unit-test fixture lifecycle

Unit tests retain SQLite fixtures while the test host can still have open handles. Each test-host process now uses its own `tmp/CornellNoteTestRuns/<run-id>/` inside the Simulator app container, with an `owner.json` record. The log prints `CornellNote fixture run: <run-id>`; save that ID for the following cleanup. Existing unowned temporary directories are not collected.

Use an explicit dedicated Simulator, not a device with notes you use normally. Keep it Booted while resolving the app container. If it is Shutdown, boot only that selected Simulator before testing:

```sh
TEST_DEVICE='<dedicated Simulator UDID>'
xcrun simctl boot "$TEST_DEVICE" # only when this device is Shutdown
xcodebuild -project CornellNote.xcodeproj -scheme CornellNote \
  -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -parallel-testing-enabled NO -only-testing:CornellNoteTests \
  CODE_SIGNING_ALLOWED=NO test
```

After `xcodebuild` exits, report the selected run's directory/file counts, logical file bytes and allocated bytes, then reclaim that run. Do this after each run on a long-lived Simulator or runner:

```sh
RUN_ID='<run-id printed by this test host>'
python3 -I scripts/unit_test_fixtures.py report --device "$TEST_DEVICE" --run-id "$RUN_ID"
python3 -I scripts/unit_test_fixtures.py cleanup --device "$TEST_DEVICE" --run-id "$RUN_ID"
```

`cleanup` requires a valid matching owner record, confirms the creating host PID no longer exists, and checks for remaining open files with `lsof`. It refuses removal if the PID is alive or reused, inspection fails, the run boundary is symlinked, or ownership is uncertain. It never stops a process, shuts down/erases a Simulator, scans for old runs to delete, or deletes Application Support. Do not edit the owner record or bypass a refusal; wait for the host/handles to close and retry. A successful cleanup reports reclaimed usage and zero remaining directories for that run. This is explicit post-run cleanup, not automatic reclamation by individual tests.

The helper uses Python's standard library and requires macOS `xcrun`, `lsof`, and fd-safe `shutil.rmtree`. Its filesystem/process safety tests run without a Simulator:

```sh
python3 -I -m unittest discover -s scripts -p test_unit_test_fixtures.py -v
```

## Product reference

The product specification source of truth is the private `Cornell-Note/product` repository:

- Exact specification path: `doc/ipados/requirements/IPADOS_HANDWRITING_APP_SPEC.md`
- Approved product commit: `4c8dde0b8fc65a40668807b81f8316f699fe0103`

The revision pin is defined by four fields: path, commit SHA, change/impact, and verification. The pinned path is read from the approved commit; the change/impact is the iPadOS reference-only boundary; verification requires the commit and path to be available as Git objects.

This repository has no package dependency, CI configuration, signing team, or App Store configuration.
