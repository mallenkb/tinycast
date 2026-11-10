# Search by description

## Invariants

- Interpret broader queries locally with Apple's installed Foundation Models model and structured
  queries with local rules. Never request credentials, download a model or send queries externally.
- Ordinary search remains usable while interpretation runs and when the model is unavailable.
- A model response is only a proposed destination and search constraints. Results come from actual
  local stores. Commands run only through the existing explicit selection and confirmation path.
- Hidden or disabled commands and features remain unavailable. Exact names and aliases take priority.
- New queries, mode changes and closing the palette invalidate pending interpretation.
- Interpretation has a four-second deadline including debounce and queue time. Expired responses
  cannot publish. Ordinary search remains available if model cancellation takes longer to finish.
- Unsupported exclusions and file events fall back to ordinary search. Creation and download dates
  use their own metadata. Only an explicit folder clause restricts the search to Downloads.
- Every unconsumed topic word remains a search term. Literal content after a topic marker retains
  words such as "not" and "last week" instead of turning them into filters.
- Clipboard visual content search remains opt-in. Enabled visual search matches recognized text and
  saved on-device image and video-frame descriptions; see [image-search.md](image-search.md).

## Ownership and flow

`AppCore` owns `SearchIntentCoordinator`. It debounces multiword input, snapshots the current command
catalog and known clipboard website hosts, then starts `SearchIntentHelper` for local interpretation.
The helper exits after returning its result, so the model's working memory leaves with the process.
The resolver first chooses an allowed destination, then extracts optional constraints. Command routes
use distinct keys mapped to command IDs; commands with duplicate titles are omitted from interpretation.
The pure
`SearchIntentPolicy` grounds those constraints in the user's request before they reach the stores.

Searches such as `links I copied` and `links from <site>` route to Clipboard History locally. They use
known hosts to resolve a one-character spelling error without invoking the model.

File searches use the existing mapped index, paths, types and modification dates. Optional image
content search adds a disk-backed description index. Clipboard searches use copied text, URL hosts,
capture dates and stored OCR or visual descriptions.
The type dropdown narrows interpreted results. Root search suggests Clipboard History or Search
Files with the original description carried into that screen; enabled inline file results also use
the constraints.

Structured file queries are parsed by `SearchFileQuery` before model validation. They support exact
and relative modification, creation and download dates, date ranges, arbitrary formats and folders, filename
and content clauses, sizes, tags, exclusions and sorting. Invalid or ambiguous structured dates are
not reinterpreted by the model. Search Files skips model generation when its structured parser already
handled the query. See [file-search.md](file-search.md) for the grammar and filter chips.
The on-device model can interpret questions such as "Which HTML files did I download last week?"
The policy verifies the event and date against the query, then passes editable filters to Search Files.
Access dates remain unsupported. Clipboard descriptions retain their existing date grammar.
Folder filters require an explicit location such as "in Downloads". Quoted phrases before a topic
marker remain ordinary queries. In broader model-assisted descriptions, text after "named", "containing", "about" or another topic
marker remains literal. Structured file queries allow more clauses after a quoted phrase. OCR matching retains every content term without dropping words.

Only the current interpretation is retained. A progress indicator appears in the existing header
while it runs. A failed or unsupported interpretation leaves ordinary search available. The model
is probabilistic and can misunderstand a request, so the typed query stays visible and editable.
There is at most one model operation in flight and one pending query. Cancellation and expiry
terminate and reap the helper before another starts. Ordinary search continues while it runs.

## Verification

The deterministic description and installation harnesses cover store filtering and command ranking.
`search-intent-live-test` is an opt-in harness using the installed model and synthetic queries. It
skips when the model is unavailable, and is excluded from the default suite. Model checks do not
replace deterministic tests for stale queries, visibility, URL hosts and date boundaries.

Run the opt-in model check on a Mac with Apple Intelligence available:

```sh
swiftc -swift-version 6 Tinycast/Features/SearchDescription.swift \
  Tinycast/Features/SearchDatePhrase.swift Tinycast/Features/SearchFileConstraints.swift \
  Tinycast/Features/SearchCalendarDate.swift Tinycast/Features/SearchFileQuery.swift \
  Tinycast/Features/IntelligentSearch/Model/*.swift \
  Tinycast/Features/IntelligentSearch/Helper/SearchIntentResolver.swift \
  Tinycast/Features/IntelligentSearch/Service/SearchIntentWorker.swift \
  Tinycast/Platform/ProcessExit.swift \
  Tests/search-intent-live-test.swift -o /tmp/tinycast-search-intent-live-test
/tmp/tinycast-search-intent-live-test
```

Pass the built app's `Contents/Helpers/SearchIntentHelper` path to the harness to exercise the
production subprocess and its transport as well as the resolver.
