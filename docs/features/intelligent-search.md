# Search by description

## Invariants

- Interpret queries locally with Apple's installed Foundation Models model. Never request credentials,
  download a model or send queries to an external inference service.
- Ordinary search remains usable while interpretation runs and when the model is unavailable.
- A model response is only a proposed destination and search constraints. Results come from actual
  local stores. Commands run only through the existing explicit selection and confirmation path.
- Hidden or disabled commands and features remain unavailable. Exact names and aliases take priority.
- New queries, mode changes and closing the palette invalidate pending interpretation.
- Interpretation has a four-second deadline including debounce and queue time. Expired responses
  cannot publish. Ordinary search remains available if model cancellation takes longer to finish.
- Unsupported exclusions and file events fall back to ordinary search. Download, creation and access
  dates must never be substituted with modification dates, and downloading does not imply Downloads.
- Every unconsumed topic word remains a search term. Literal content after a topic marker retains
  words such as "not" and "last week" instead of turning them into filters.
- Clipboard visual content search remains opt-in. Enabled visual search matches recognized text and
  saved on-device image and video-frame descriptions; see [image-search.md](image-search.md).

## Ownership and flow

`AppCore` owns `SearchIntentCoordinator`. It debounces multiword input, snapshots the current command
catalog and known clipboard website hosts, then invokes `SearchIntentResolver` off the main actor.
The resolver first chooses an allowed destination, then extracts optional constraints. Command routes
use distinct keys mapped to command IDs; commands with duplicate titles are omitted from interpretation.
The pure
`SearchIntentPolicy` grounds those constraints in the user's request before they reach the stores.

File searches use the existing mapped index, paths, types and modification dates. Optional image
content search adds a disk-backed description index. Clipboard searches use copied text, URL hosts,
capture dates and stored OCR or visual descriptions.
The type dropdown narrows interpreted results. Root search suggests Clipboard History or Search
Files with the original description carried into that screen; enabled inline file results also use
the constraints.

File date filters support today, yesterday, this week, last week, the last seven days and last month.
Explicit modification, edit and save wording uses those dates. Downloaded, created, opened, received
and added wording is unsupported. Other date ranges, exclusions and alternatives expressed with
"or" remain ordinary queries. Unsupported date detection does not depend on the model returning a
time field. A standalone filename year remains a term; a year introduced with "from" is unsupported.
Folder filters require an explicit location such as "in Downloads". Quoted phrases before a topic
marker remain ordinary queries. After "named", "containing", "about" or another topic marker, the
remaining text is literal content. OCR matching retains every content term without dropping words.

Only the current interpretation is retained. A progress indicator appears in the existing header
while it runs. A failed or unsupported interpretation leaves ordinary search available. The model
is probabilistic and can misunderstand a request, so the typed query stays visible and editable.
There is at most one model operation in flight and one pending query. Expiry cancels the operation
and discards the pending interpretation without starting overlapping model sessions. If the framework
does not promptly honor cancellation, subsequent interpretations may also expire while ordinary
search continues. The deadline bounds the visible wait, not the framework's resource release time.

## Verification

The deterministic description and installation harnesses cover store filtering and command ranking.
`search-intent-live-test` is an opt-in harness using the installed model and synthetic queries. It
skips when the model is unavailable, and is excluded from the default suite. Model checks do not
replace deterministic tests for stale queries, visibility, URL hosts and date boundaries.

Run the opt-in model check on a Mac with Apple Intelligence available:

```sh
swiftc -swift-version 6 Tinycast/Features/SearchDescription.swift \
  Tinycast/Features/IntelligentSearch/Model/*.swift \
  Tinycast/Features/IntelligentSearch/Service/SearchIntentResolver.swift \
  Tests/search-intent-live-test.swift -o /tmp/tinycast-search-intent-live-test
/tmp/tinycast-search-intent-live-test
```
