# iPadOS repository boundary

This repository owns iPadOS source, tests, builds, signing configuration, release configuration, and implementation Issues.

The `Cornell-Note/product` repository owns product principles, the iPadOS specification, ADRs, summaries, handoffs, and learning notes. Its approved revision is referenced in `README.md` by specification path and exact commit SHA.

Do not reuse Mac APIs, Prisma/SQLite, CanvasDocumentV1, or the Mac Markdown body as an iPadOS contract. iPadOS has its own contracts and implementation boundary.

## Initial scope

- One notebook equals one Cornell page.
- Apple Pencil and one-finger drawing.
- Eraser.
- Two-finger pan and pinch.
- Automatic local save.

External connections, publication, signing, and App Store operations require separate approval. This bootstrap contains no implementation scaffold.
