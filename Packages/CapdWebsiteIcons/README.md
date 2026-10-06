# CapdWebsiteIcons

An offline consumer of normalized website-icon PNGs. Callers supply a local blob reader and an identity containing the library scope, session generation, origin ID, record revision, normalizer version and content digest. The reader must enforce the blob's declared size limit before allocating bytes and verify its current library ownership. The cache then checks the returned data's digest, 256 KiB limit, PNG type, single frame and dimensions of at most 64 pixels.

The cache holds at most 128 decoded images, 16 pending identities, 64 waiters per identity and 512 waiters in total. Two local loaders can run at once. A five-second deadline releases waiters; a loader that ignores cancellation continues occupying its worker slot until it returns. Reset discards pending results. Assets persist in the library's existing blob store.

`WebsiteIconTile` shows the symbol fallback immediately when its identity disappears or changes. The package contains no website transport or network preference. Tests use generated PNGs and suspended in-memory readers.
