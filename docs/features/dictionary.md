# Dictionary

`Define Word` is a launcher command and a fallback. The command opens the dictionary screen (`.dictionary`)
empty; the fallback opens it on whatever was typed. The search field stays the term, so a different
word is one edit away. Definitions come from the dictionaries enabled in Dictionary.app. The
English pronunciation card uses installed macOS system voices. Definitions and written pronunciation
come from the selected native dictionary; no pronunciation service or API key is needed.

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

## Pronunciation card

One compact card appears directly below the headword. It shows a single Sounds like guide, a speaker
button, Slow, and source/accent selectors. Equivalent IPA variants collapse to one readable guide;
recordings with equivalent accent labels collapse to one choice. The first representative guide is
approximate, not a claim that every recording or system voice follows an identical transcription.
The selected dictionary's written pronunciation is the fallback when no readable online guide exists.

Native speech is the default audio source. It uses installed standard English voices through
AVSpeechSynthesizer; a shared public-name family is preferred for US/UK choices to reduce provider
loading. Enhanced, premium, novelty and Personal Voice entries are excluded. Discovery runs off-main,
refreshes when installed voices change, and preserves an available choice across word changes.
Native playback does not wait for Wiktionary metadata and remains usable when that service fails.

Recorded audio remains selectable and uses the bounded Wikimedia provider. Its word metadata may
also supply the card's readable guide. Only pressing Play downloads recording bytes. Requests use a
private ephemeral session without URL caching, respect Retry-After, and validate Wikimedia URLs.
Recording author, licence and source links are available in the source menu, not repeated on the card.
There is no persistent audio cache.

Changing the source stops the previous audio path and cancels pending recorded playback. Changing
words or closing the screen stops both paths. Native engines, utterances and recorded players are
released after completion/cancellation; cleanup schedules the app's existing idle memory reclamation.
Slow changes recorded playback speed directly and restarts native speech at the new rate. Source,
speed and native voice choices survive word changes for the current app session.

The final combined-source Release probe on 5 November 2026 completed recorded playback and native
US/UK playback, with all player, synthesizer, utterance and Settings-host weak references released.
Main-process peak was 74.5 MB. Sampled combined main plus speech/audio helpers peaked at 90.0 MB;
the sum of their separate lifetime peaks was 94.0 MB. Closed warmed combined footprint was 67.8 MB,
including 49.0 MB main and 18.7 MB of OS speech/audio helpers. Shared preexisting system daemons
were listed separately, and no system helpers were killed. The inactive apple card showed one guide
in a compact card below the word without clipping or visible attribution. Menus were not clicked in
this passive visual check. The background suite passed 127 harnesses; signed build and lint passed.
