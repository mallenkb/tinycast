# Dictionary

`Define Word` is a launcher command and a fallback. The command opens the dictionary screen (`.dictionary`)
empty; the fallback opens it on whatever was typed. The search field stays the term, so a different
word is one edit away. Definitions come from the dictionaries enabled in Dictionary.app. The
English pronunciation card retrieves human recordings and phonetic text through public Wiktionary and
Wikimedia Commons APIs without an API key.

## Invariants

- **The command gates the fallback, never the reverse.** Define Word has no feature pane, so
  Settings › Commands is its switch: while the command is hidden there — itself or the whole Commands
  category — `FallbackCoordinator` offers no Define Word fallback and Settings › Fallbacks does not
  list it. While it is visible, the fallback's own checkbox hides just the fallback, leaving the
  command searchable.
- **The page comes from an undocumented call, resolved at run time.** The public
  `DCSCopyTextDefinition` returns one unbroken line, so `DictionaryService` asks for the record's XHTML
  through `DCSGetActiveDictionaries`, `DCSCopyRecordsForSearchString` and `DCSRecordCopyData` — what
  Dictionary.app itself reads. They are found with `dlsym`, never linked: a macOS that drops one loses
  the layout and falls back to the public plain text, rather than failing to launch.
- **The span classes are the only structure, and `DictionaryMarkup` is the only reader of them.**
  `hg` is the headword, `posg` the part of speech, `se2` a numbered sense, `msDict` its definition or a
  `t_subsense` bullet, `note` an aside, `x_xoLblBlk` a section label (`ORIGIN`, `PHRASES`). Unknown
  markup reads as plain text in the nearest block, so a format change degrades rather than drops words.
  `dictionary-test` holds a real record as its fixture.
- **Lookups run off the main actor.** A long entry (`run`, `take`) is a few hundred blocks, so
  `DictionarySession` debounces the query and looks it up detached, the way `FileSearchSession` does.
  The previous page stays up until the next resolves, and ↵ and ⌘K act on that page — what is shown
  is what is copied — so neither the page nor the footer flickers while typing.

## Actions

| Key | Does |
| --- | --- |
| ↵ | Copy Definition — the whole entry, one line per block, then the palette closes |
| ⌘↵ | Open in Dictionary — `dict://<term>`, for every other enabled dictionary |

The empty state shows Dictionary.app's icon through the shared icon cache, with a prompt to type a word.
The dictionary name stays in the selector beside the search input rather than repeating above the
definition. The selector opens one searchable list. Its width fits the longest label up to the palette width and stays fixed while filtering.
Choosing a dictionary applies immediately and saves it as the preferred source for future lookups.
Only one dictionary is displayed at a time. The menu contains individual dictionaries, with the
selected and recently selected dictionaries first and untouched sources in Dictionary.app order.
Up to 12 recent dictionary identifiers are saved across launches and backups, and mirrored as
`dictionary.recentSources` in settings.json. Automatic fallback never changes this recent order.

The default follows Dictionary.app's enabled order. Choosing a preferred dictionary tries it first,
then the other enabled dictionaries in their original order. If the preferred dictionary is unavailable
or has no entry, a notice explains the fallback.
The preference uses the dictionary's identifier, survives relaunch and backup, and is mirrored as
`dictionary.preferredSource` in settings.json. An empty string follows Dictionary.app's order.

Names and identifiers come from runtime-resolved `DCSDictionaryGetName` and
`DCSDictionaryGetIdentifier`. The menu lists enabled dictionaries exposed by Dictionary Services;
onlocal Dictionary.app sources such as Wikipedia are not promised. If the private calls are missing,
the screen offers the public plain-text result without claiming a specific source.

Only names and identifiers are retained for the menu. Records are read sequentially until a source
answers, and temporary markup is released after each record. Closing the screen clears the entry and
source list and cancels pending lookup work.

On 2026-11-05, the original combined Dictionary and Settings workflow peaked at 104.4 MB in Debug
and 114.8 MB in Release. Info.plist now selects libmalloc's space-efficient policy, which favors eager
reclamation over allocation throughput. AppCore's idle cleanup drops disposable image caches after two
seconds without input or query changes, preserving the result being read.

With the shipped renderer and launch configuration, two Debug stress runs peaked at 78.4 and 93.0 MB;
a Release stress run peaked at 73.7 MB. Each performed three cycles of seven dictionary queries and
General, Applications and Commands settings. Closing Settings returned to a warmed footprint of
roughly 50–69 MB; closing both surfaces settled at 45–65 MB. The first Settings use loads shared runtime
and framework caches, so the warmed baseline is higher than a cold launch. Repeated cycles must settle
rather than accumulate window-owned memory. A further run also checked idle launcher searches.

These measurements use decimal MB of physical footprint, with noninteractive test panels behind other
windows on the built-in display. They cover the tested workflow, not every extension or dataset.
The allocator policy is implemented in [Apple's libmalloc source](https://github.com/apple-oss-distributions/libmalloc/blob/main/src/xzone_malloc/xzone_malloc.c).

## Recorded pronunciation

The English pronunciation card appears below the headword. Metadata loads after a short debounce;
recording bytes download only when Play is pressed. Changing the query, recording or screen cancels
obsolete work. An unavailable recording and a failed request have distinct states, with retry for
failures. Definitions remain available offline.

Accent choices use the recording's source labels. IPA is paired only with a compatible accent.
When the source lists several variants without identifying the recording, the card shows the variants
and explains that the recording may use one of them. It never selects a variant as an exact match. The Sounds like line is a conservative,
approximate English respelling with uppercase primary stress. It retains the original IPA alongside it.
Unsupported notation omits the guide while leaving the recording usable. Slow plays at 75% speed.
The audio source, author, licence and phonetic source links remain visible independently of the native
definition source.

Requests use a private ephemeral session without URL caching, cookies or credentials. Metadata is
bounded to 1 MiB and audio to 2 MiB; at most four recordings are retained as metadata. Downloads use
advertised Wikimedia URLs and accept only approved HTTPS hosts. Rate-limit responses delay further
requests according to Retry-After, including after the user changes words. There is no bundled voice model,
WebKit view, persistent audio cache or speech-synthesis fallback. The player is created on demand and
released on completion, failure, cancellation or dismissal. Resource release schedules the app's
existing idle memory cleanup.

Pronunciation validation on 5 November 2026 passed 123 background harnesses and the separately
authorized onboarding focus harness, with affected tests rerun after the final provider and playback
changes. Live public-API checks downloaded attributed
recordings for library, bulwark and rice. The session harness covers 48 lifecycle and cooldown checks;
its simulated player emits no sound. A separate Release probe performed nine real muted playbacks
across three Dictionary and Settings cycles. Every player and Settings hosting controller released. A separate no-window test also completed
normal and slow playback at the player's default volume without changing system volume.

The final probe peaked at 75.2 MB combined physical footprint. Closing Settings settled at 53.4 to
55.4 MB, and closing the test windows settled at 49.7 MB. An earlier selectable-card variant peaked
at 102.2 MB during inspection and 95.5 MB without inspection. The final pronunciation card disables
inherited text selection on its controls and labels while leaving definitions selectable. These are
measurements of the tested workload, not an unconditional limit across all data and runtime states.

A separately authorized foreground interaction pass verified the actual rendered Play/Stop button,
Slow switch and accent selector. Selecting American updated the header, Commons recording source
and licence. Both guide rows and their IPA/source information fit the held library card without
visible clipping. The isolated test app closed afterward. The onboarding focus check also passed;
the form-input harness passed after correcting its Light-mode ink detection. This brings coverage
to all 124 harnesses across the background suite and focused reruns.
