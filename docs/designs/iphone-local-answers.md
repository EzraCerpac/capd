# Local library questions on iPhone

The Ask Cap sheet uses `CapdAnswers` with `MobileAnswerRetrieval`. The reader opens
the selected app-group database through GRDB's read-only configuration and the
same generation fence used by activation. It does not create a missing database,
migrate, initialize a sync runtime, fetch links, or read image assets.

## Availability and generation

`OnDeviceAnswerModel` selects Apple's `SystemLanguageModel.default` and opens a
fresh session per question on iOS/macOS 26 or later. It checks current model and
locale availability before opening the reader. Unsupported hardware, disabled
Apple Intelligence, unsupported language, and model readiness have separate UI
messages. Check again and foreground return refresh availability.

No model tools, remote service, fallback, question log, or persisted answer is
supplied. On 26.4 and later, the adapter counts prompt, instruction and schema
tokens and reserves response context. Earlier supported releases use bounded
input and context-overflow handling. Cancellation discards late results.
Availability does not guarantee that the model service can complete generation.
The preserved adapter retains its bounds and generation-failure behavior.

Local checks use Xcode 27 / Swift 6.4; no older SDK is installed here. The SDK
27-specific error mapping is guarded by `compiler(>=6.4)` while the existing
legacy mapping and failure fallback remain. This does not claim an Xcode 26.3
build was tested.

## Evidence

Questions are limited to 500 characters. Natural Language word segmentation
selects up to eight significant terms, yielding at most nine local searches,
each capped at twelve hits. Retrieval keeps BM25-ranked FTS matches first. For
terms containing non-ASCII letters, a parameterized literal search of saved text
fills remaining candidate slots when the SQLite tokenizer cannot match inside a
continuous sentence. This fallback scans stored text; its result count is
bounded, but its scan cost grows with the library. It does not change the index
or promise recall for every language.

Evidence combines matching passages from saved selection, note, body and OCR
text, retaining passages found by later queries for the same capture. Title-only
matches retain a prose fallback. Tags alone are not evidence.

The service deduplicates captures, chooses at most six sources, and limits each
excerpt to 1,000 UTF-8 bytes and total excerpts to 5,000 bytes, including passage
separators. These limits cover excerpts rather than the full prompt or model tokens.
Structured answers must
cite supplied source numbers and quote text present in the corresponding excerpt.
Unsupported citations or insufficient evidence produce a clear failure message.
Quote membership does not establish semantic entailment; the UI presents the
supporting quotes and opens the saved-source detail, including recognized image
text, for review.

The reader opens only after the user asks and resolves the current selected
configuration. A stale generation fails through the activation fence. Navigation
uses app-owned capture UUIDs, rather than model-supplied URLs.

## Integration and checks

XcodeGen includes the answer package for the phone target. `CapdMobile` links its
retrieval protocol; `LibraryView` presents the Ask sheet. The Mac retains its
existing local answer implementation.

Synthetic unit tests cover bounds, unavailable models without reads, quote/source
validation, cancellation, FTS stemming and BM25 ranking, mid-sentence Japanese
and Chinese matching, combined prose fields, unchanged outbox/content, and
missing-database refusal. UI fixtures are included separately and require an
explicit simulator run; an unsigned simulator build verifies compilation.

The DEBUG simulator-only `--capd-synthetic-citation` fixture accepts only synthetic
orchid evidence. It exercises the real retriever, citation validator and source
navigation with a clearly labeled fixture model. Release and physical-device
builds select `OnDeviceAnswerModel`. Fixture success does not establish native
generation or answer quality. Broad question-retrieval improvements are outside
this preserved implementation.

See [synthetic model diagnostics](foundation-model-diagnosis.md) for the separate
bounded framework probe.
