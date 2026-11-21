# iPadOS repository boundary

This repository owns iPadOS source, tests, builds, signing configuration, release configuration, and implementation Issues.

The `Cornell-Note/product` repository owns product principles, the iPadOS specification, ADRs, summaries, handoffs, learning notes, and agent skills. Its approved revision is referenced in `README.md` by specification path and exact commit SHA. Read the scope and behavior from that specification; do not restate it here.

Do not reuse Mac APIs, Prisma/SQLite, CanvasDocumentV1, or the Mac Markdown body as an iPadOS contract. iPadOS has its own contracts and implementation boundary.

External connections, publication, signing, and App Store operations require separate approval. Development sessions and shared working rules follow `../product/development/AGENTS.md`.
