# Image and video content search

## Invariants

- Analyze images and sampled video frames locally, off the capture and query paths. Never use a network model or download weights.
- Visual descriptions require macOS 27 and an available Apple Intelligence model with vision support.
  OCR continues to work without that capability.
- Generated descriptions are search metadata. Copy Text continues to return OCR only.
- Respect File Search scopes, ignore rules, type filters and dates. Reject cached matches when the
  source size or modification timestamp changes, the file disappears, or its index entry is removed.
- Process one clipboard or file asset at a time. Decode media and run the model in a disposable helper.
- Background image processing is a per-machine choice, excluded from backups and settings.json.

## Controls and ownership

Clipboard History's existing text-search switch is now **Search image, video and PDF content**.
File Search has a separate **Search image and video content** switch, off by default. Neither switch changes
the other. Enabling one backfills the corresponding history or configured file scopes.

`AppCore` owns `FileImageContentIndexer` and the existing `ClipboardTextIndexer`. Their admission
checks share the two-second idle window and prevent overlapping background extraction jobs.
The file indexer reads bounded batches from the existing file index, pauses between extractions,
and rescans while idle to discover changes and retry partial results. Disabling cancels its helper and purges the file-content database. Application shutdown stops work
without discarding metadata. Scope changes and lost Full Disk Access retire old work and remove
excluded metadata. Dataless cloud files and symbolic links are not decoded.

`ImageContentExtractor` runs only in `ClipboardTextHelper`. It combines Vision OCR with a short
description from Apple's installed on-device model. Descriptions include objects, colors, settings
and relationships. The model receives a thumbnail with a maximum edge of 1024 pixels.
Still images are limited to 32 MB and retain the OCR bitmap limits. Videos retain an 8K source edge
limit with at most 33.55 megapixels. Duration and file size do not impose separate cutoffs. A short
video supplies one frame;
otherwise the helper samples three frames at 10%, 50% and 90% of its duration. Captions are combined
for the whole file. This can miss brief scenes and does not transcribe speech or return timestamps.
External media references and implicit cloud downloads are disabled in the helper. The parent bounds JSON output to 256 KB
and enforces the existing 60-second helper deadline.

## Storage and retrieval

Clipboard metadata uses `item_text`; `item_text_versions` marks OCR-only and visually described rows.
Old OCR rows are backfilled without changing the copied item. Text and version updates are transactional.
A caption failure retains searchable OCR and uses the existing bounded retry queue.
Deleting an item deletes its derived text and version. History exports contain no generated captions.

File metadata lives in `ImageContent/images.sqlite3` in the app's Application Support directory.
SQLite FTS stores text on disk with a 2 MiB connection cache. Rows carry a scope fingerprint, file size
and modification timestamp. Searches validate those fields and index membership before returning a
match. Completed scans prune records outside the active scope and deleted files. Incomplete extraction
retries at most three times per source version, one minute apart.

Filename matches retain priority; content matches fill the remaining result budget. Visual descriptions
match significant words across the saved caption and OCR, without requiring one contiguous phrase.
File content matching also stems English words. Clipboard dates mean capture time; file dates mean
modification time. Unsupported date and exclusion wording still follows the intent policy.

This searches generated descriptions and recognized text, not pixel-to-text embeddings. Missing or
differently worded details can miss a match, and descriptions can be inaccurate. Visual descriptions
are generated in English. Synthetic native-model probes verified still-image OCR and captions plus three-scene video retrieval
through the shipped store and file index. These checks do not establish accuracy on arbitrary media
or performance on large libraries. Combined memory use remains unmeasured for this feature.
