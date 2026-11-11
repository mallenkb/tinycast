# Emoji picker

A palette sub-screen (reached like Clipboard / Calculator History) presenting a searchable emoji grid.

## Invariants

- **`Model/` stays Foundation-only** — `EmojiCatalog`, `EmojiGridGeometry` and the generated dataset are
  compiled by `emoji-test`, so an `import AppKit` there breaks the test suite.
- **`EmojiData.generated.swift` and `Resources/EmojiKeywords/` are emitted by `node Scripts/gen-emoji.js`**
  (Node 18+ for global `fetch`) and are never edited by hand. Regenerate and commit instead.
- **Keyword packs are plain files, never `.lproj` folders.** Search loads packs for the user's
  macOS languages independently of Tinycast's UI language.

## Layout

| Path                                                | Role                                        |
| --------------------------------------------------- | ------------------------------------------- |
| `Model/EmojiCatalog.swift`                          | The catalog model — groups, names, keywords |
| `Model/EmojiGridGeometry.swift`                     | Pure grid math — columns, item sizing       |
| `Model/EmojiData.generated.swift`                   | The dataset                                 |
| `Resources/EmojiKeywords/<language>.txt`            | CLDR keyword packs, `glyph\|terms` per line |
| `Service/EmojiIndex.swift`                          | Search index over the catalog               |
| `Service/EmojiDescriptionSearch.swift`              | Local sentence embedding search over emoji |
| `Service/FrequentEmojiStore.swift`                  | Persisted emoji history and usage counts    |
| `Service/PinnedEmojiStore.swift`                    | Persisted pins, in the order the user set   |
| `UI/EmojiGridView.swift`                            | The SwiftUI grid                            |
| `UI/EmojiScreen.swift`, `UI/EmojiCoordinator.swift` | The palette screen and its action surface   |

The index and the store are **effects**, so they live under `Service/` — only the three files above them
are pure.

## Search

- **Keywords keep their CLDR phrase boundaries.** The generator joins them with commas and keeps every
  annotation, and a single-word query fuzzy-matches the name and each keyword on its own, so a
  subsequence never spans two keywords.
- **Every word of a multiword query must start a word** in the name or a keyword, in any order. A literal
  phrase outranks words found in the name, which outrank words assembled from name and keywords.
- **English descriptions also match without filler words.** If an entry does not match the full query,
  search retries without `a`, `an`, `the`, `on`, `of`, `with`, `in`, `at`, `to`, `my`, `your` and `its`.
  Every remaining word must match; these results rank below full-query matches. Single-word queries
  and queries made entirely of filler words keep their original behavior.
- **Hand and face gestures have curated English descriptions** in `EmojiIndex`, added when search text
  is folded. Queries such as `hand on face`, `hand of face`, `hand on chin` and `hands covering eyes`
  use local text matching, without a model or network request. The generated CLDR catalog is unchanged.
- **English phrases also receive local semantic matches.** After a 250 ms typing pause, Apple's
  Natural Language sentence embedding compares the query with catalog names and keywords. This uses
  machine learning, not an LLM or Apple Intelligence generation. It makes no network requests and
  does not request model downloads. If the English embedding is unavailable or language detection
  does not identify English, keyword results remain available.
- **Semantic results are catalog emoji only.** Text-symbol categories are excluded. Up to 12 matches
  with cosine similarity of at least 0.6 follow keyword results, without duplicates; category, pin and
  frequency filters still apply. The threshold is an initial cutoff, not a calibrated confidence score.
  Single words and queries longer than 200 characters use keyword search only.
- **Embedding work stays off the main actor.** Catalog vectors are created on the first eligible query,
  stored as normalized `Float` arrays, reused while the picker is open, and released on unload.
  The view owns cancellation; query identity and catalog revision gate publication. Model loading and
  the first catalog pass can delay semantic results but do not block keyword results. Latency, accuracy
  and memory usage require measurement on supported hardware.
- **AI Suggestions appear when an empty search can be retried with Apple Intelligence.** For phrases
  in All Categories or a catalog category, the on-device model ranks a shortlist assembled from
  nearby embeddings and overlapping words. Pose descriptions help retrieve entries such as a man
  in lotus position for `man sitting`. Only valid shortlist IDs can produce results, with up to five
  emoji shown. The picker honors Tinycast's Apple Intelligence route switch and model availability.
  Pinned and Frequently Used remain limited to their own entries.
- **A full name ranks first, then a complete leading name word, then an exact keyword**, then a partial
  leading word: `birthday` keeps 🎂 first, and `pray` favours the annotation over "prayer beads".
- **Colon-wrapped queries are unwrapped**, so `:+1:` reuses CLDR's `+1` annotation with no alias table.
- **Other languages add keywords; English always stays.** The picker loads one pack per language in
  `SystemLanguages.preferred`, matched by `Bundle.preferredLocalizations` (`zh-CN` reads `zh-Hans`), so
  a Simplified Chinese Mac finds 🐱 by `猫` and by `cat`. Pack terms join after the English keywords,
  so an English name match still ranks first. An English-only Mac reads no pack. The generator drops terms
  English already has, folds `’` to `'`, and gives katakana a hiragana twin, since an IME shows hiragana
  until conversion. Packs ship for German, Spanish, French, Japanese, Korean, Portuguese, Russian and
  Simplified Chinese.
- **The catalog loads on demand.** Tinycast releases it when the picker is hidden or another screen opens.
  Reopening a preserved picker reloads the catalog for its existing query and category.
- **Search text is folded once, at load.** `EmojiIndex` keeps a `FuzzyMatch.Candidate` for each name
  and keyword, so a keystroke folds only the query. Folding non-ASCII keywords per keystroke made one
  pack cost 5–7× the English-only search.
- **Usage breaks ties, never tiers.** The top 100 glyphs from `FrequentEmojiStore.top` add a 100…1
  bonus, and the store's identity and revision are in the search memo key.

## Rendering

Return pastes the selected emoji even when clicking the grid moves focus away from the search field.
Text composition and an open control list retain their own Return handling.
Paste sends its Command-V events to the captured target app, even if focus changes during dismissal.
If that app quits before delivery, the events are discarded.

Two structural decisions in `EmojiGridView` are load-bearing, and both are about the ~2,000 cells the
grid can realize.

**Interaction lives on the row, never the cell.** Tap, double-tap, right-click and hover are attached
once per `EmojiGridRowView`. A fast scroll realizes every cell, and per-cell interaction
machinery — notably the `NSView`-backed right-click catcher — costs roughly **100 MB** at that scale,
which lazy containers never release. Per-row keeps it bounded to the handful of visible rows, so the
cell view stays pure content: no gestures, no overlays, no hover tracking. Hover is resolved by
mapping the pointer's x through the shared cell size and gap; points in a gap and empty trailing slots
of a partial last row resolve to nil.

**Rows sit directly under the outer `LazyVStack`.** A cell nested inside a `LazyVGrid` cannot be
scrolled to until it is realized, which broke keyboard scrolling on key-hold. Keeping rows as the
`ScrollViewReader`'s targets means any row can be reached even while off-screen. Row IDs are
section-namespaced, because a frequently-used emoji also appears inside its own category. Selecting
into the first row scrolls to the origin rather than the row, so the section header shows too.

The grid list uses the palette scrollbar (`.thinScrollbar()` + `.hideNativeScrollers()`). Its local
section header adds the item count without changing list headers elsewhere — see [ui.md](../ui.md).
Rows keep the same gap in both axes, while a selected cell expands its own blurred glyph behind the
foreground glyph so the colour wash and slim outer ring remain specific to that emoji.

## Categories, pins and density

The header category menu filters the same ordered section model used by rendering and search. The
default overview shows Pinned first, then Frequently Used and the catalog categories. Frequently Used
shows the most recently used emoji, regardless of count, in at most two rows at the current column
count; when a use or a density change rewrites it, the selection follows its emoji. Pinned glyphs live in `emoji-pinned.json` under Application Support; their order is explicit
user data and is also carried by the configuration backup. A new pin is appended without moving the
current selection; the Actions menu or ⌥⌘↑/↓ can then move it up or down inside Pinned. Every position
is counted over the pins the catalog can show, so a stored glyph it lacks — from a newer backup — never
shifts one.

Grid density is six through ten columns. `AppSettings.emojiGridColumns` is the default for a fresh
picker; zoom, from Actions or its chords, writes only `PaletteState.emojiGridColumnsOverride`, so a temporary zoom
does not silently change the preference. Actual Size (`⌘0`) clears that override; `⌘+` and `⌘-`
remove or add one column. Removing the selected item from the leading Pinned section keeps the
selection on the neighbour that takes its place instead of following the item into the catalog.
