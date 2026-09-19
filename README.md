# Cornell Note for iPad

Cornell Note for iPad targets iPadOS 17+ as a local-first, on-device app. Mac integration, a cloud backend, and authentication are not initial requirements.

SwiftUI, PencilKit, and SwiftData are future implementation plans. This bootstrap contains no source or scaffold.

## Product reference

The product specification source of truth is the private `Cornell-Note/product` repository:

- Exact specification path: `doc/ipados/requirements/IPADOS_HANDWRITING_APP_SPEC.md`
- Approved product commit: `4c8dde0b8fc65a40668807b81f8316f699fe0103`

The revision pin is defined by four fields: path, commit SHA, change/impact, and verification. The pinned path is read from the approved commit; the change/impact is the iPadOS reference-only boundary; verification requires the commit and path to be available as Git objects.

This repository does not create a package, Swift source, Xcode project or workspace, dependency, CI configuration, signing configuration, or App Store configuration.
