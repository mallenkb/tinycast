# Dictionary

`Define Word` is a launcher command and a fallback. The command opens the dictionary screen (`.dictionary`)
empty; the fallback opens it on whatever was typed. The search field stays the term, so a different
word is one edit away. Everything is read from the dictionaries enabled in Dictionary.app — no network,
no bundled word list.

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
Only one dictionary is displayed at a time. "Follow Dictionary.app Order" stays at the top; the selected
dictionary and recently selected dictionaries follow, with untouched sources in Dictionary.app order.
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
the public plain-text result is labeled "System Dictionary" without claiming a specific source.

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
