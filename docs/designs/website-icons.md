# Website icons

The Mac Agent generates icons for eligible links in its selected library. An
iPhone-origin capture reaches that same queue through ordinary capture sync.
The Agent runs icon work independently of capture sync and enrichment, so a
local Mac capture can acquire an icon while its library server is unavailable.
`Store.websiteIconsEnabled` is persisted in the shared database and defaults
to false. Claim, completion and publication recheck policy, live references,
library binding, device identity and the claim token.

## Origins and fetching

`WebsiteIconOrigin` accepts HTTPS DNS hosts on port 443. It rejects credentials,
IP literals and local or reserved names, retains `www`, and removes the path,
query and fragment. Unicode and punycode host spellings share a canonical ASCII
origin and SHA-256 identity. Previously accepted escaped ASCII host spellings
retain that identity. The captured URL stays intact; capture deduplication does not
rewrite it for icon discovery.

`PinnedWebsiteIconTransport` resolves through the system resolver, checks every
returned binary address, then connects to a validated numeric address. TLS
uses the original hostname and default system anchors. The fixed favicon GET
follows successful trust evaluation. There are no cookies, client certificates,
redirects, proxy fallback or ancillary trust-network requests.
Connection failures try another validated address within the original deadline
and a shared incoming encrypted-byte budget. Trust, framing, status, size,
deadline and cancellation failures remain terminal.
The HTTP parser validates and discards unrelated response fields, including
repeated fields. Content-Length, Transfer-Encoding and Content-Encoding remain
strictly checked, including duplicate refusal.

The absolute five-second network deadline and two-worker admission limit bound
active work. The 256 KiB encrypted-stream allowance includes the TLS handshake
and HTTP framing, so the usable image body can be smaller. Headers, framing,
image dimensions, pixels and frame count have additional bounds. PNG, JPEG
and ICO sources are rasterized into static 64-by-64 sRGB PNGs containing only
IHDR, IDAT and IEND chunks.

This implementation uses deprecated SecureTransport and supports TLS 1.2.
TLS-1.3-only hosts, proxies, redirects, trailer-bearing responses and
close-delimited responses are refused. Numeric sockets do not guarantee
hostname-triggered VPN activation. Operating-system DNS setup, trust callbacks
and ImageIO decoding cannot be forcibly preempted; admission slots remain held
until the corresponding work returns.

## Shared records

The icon lane has separate operations, device sequences, receipts, feed,
cursor, visible projection and presentation revision. It does not modify
capture revisions, search content or answer evidence. Icon content references
verified SHA-256 blobs with a normalizer version and fetch date; the authority
assigns revisions using compare-and-swap, rather than trusting fetch dates.

The HTTP lane is additive envelope version 5. A capability probe through the
existing authenticated zero-size capture baseline precedes any icon upload.
Every icon response, including upload and download, validates capability and
principal identity. An older server continues syncing captures; Settings
explains that icon delivery needs a server update.

Each origin has at most one immutable pending operation. A lost acknowledgement
retries the exact operation identity and bytes. An accepted operation observed
in the feed remains queued until its durable receipt arrives, but does not
optimistically overwrite newer accepted icon state. Pull cycles process a
bounded number of pages. Expired feeds recover from a complete, bounded icon
baseline.

The authority indexes live capture origins. Removing the last live reference
atomically publishes an icon tombstone in the icon lane. Removing one of several
references preserves the icon. Stale or unreferenced uploads cannot resurrect
it. Restored links create fresh demand; retained bytes support recovery, but
neither deletion nor policy disable physically erases historical blob files.

The authority retains at most 4,096 icon records, including tombstones. A new
record at capacity receives an explicit durable rejection that advances the
device's icon sequence without adding a record or feed event. Later updates
and deletions of existing records can proceed. Repeated rejected operations
return the same receipt; verified uploaded bytes can remain cached.

## Local display and library handoff

Mac and iPhone views load verified local assets through `CapdWebsiteIcons`.
Cache identities include library, generation, origin, revision, normalizer
version and digest. Late completions cannot populate a different library or
replacement record. Reads enforce the encoded byte limit before allocating
file data; decoding checks the actual PNG. Missing or corrupt assets use native
symbols.

The Mac consumer checks the existing database change monitor once per second
while it is retained, then reloads records when the revision changes. This
detects commits from the separate Agent database connection. Original database
file identity and library binding fence each reload; a failed check clears
artwork and forces a fresh snapshot after recovery. The refresh loop cancels
when its consumer is released.

The cache holds at most 128 images, 16 distinct requests, two active readers,
64 waiters per request and 512 total waiters. Cancellation, reset and the
five-second waiter deadline release waiters. A noncooperative reader keeps its
active-worker slot until it returns. The iPhone preference controls display;
generation remains owned by the Mac Agent.

Content snapshots use version 2 when icon records are present. Version 1
omission preserves target icons whose origins remain referenced by the final
capture batch. Existing valid target icons win, and all
assets, identities and admission budgets are verified before publication.
Enrollment stages icon assets on disk and pins the icon baseline to its capture
cursor. Unbound Mac icons live in a separate `assets/website-icons` namespace;
the handoff copies verified reachable assets into a fresh bound namespace with
rollback. A populated unbound sync blob namespace is never silently rebound.
The capture orphan sweep excludes the managed `website-icons` directory,
including retained bytes for currently unreferenced origins.

The standalone Python exporter uses public Foundation host parsing on macOS
for the same IDN and escaped ASCII origin identities. It has no third-party
Python dependency. Other platforms retain ASCII export and explicitly refuse
IDN input that requires Foundation.

Enrollment installs the verified target baseline and queues local icons missing
from it as durable pending upserts in the same transaction as the capture
baseline. Existing target icons and tombstones remain authoritative. Against
an older server, all preserved icons remain queued until it gains icon support.
They retain their verified bytes without changing the generation setting or
fetching the origin again.

Legacy pending enrollment fingerprints remain valid only when the known icon
namespace is wholly empty, including its history and counters. Real icon state
is included in preparation fingerprints. Host display, generation and sync
errors retain separate presentation: icon failure does not turn accepted
capture sync into failure.
