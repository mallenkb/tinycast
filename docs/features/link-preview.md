# Link previews

Selecting a web link in Clipboard History fetches its page metadata and displays the preview
image. Pages without an image show a card with the favicon, title and description when available.
The Information section includes the URL and fetched title. A thin animated strip at the top of
the palette indicates loading; Reduce Motion holds the strip still.

## Invariants

- Only selecting a link fetches. Listing and filtering read cached favicons without network access.
- Only HTTP and HTTPS links and image URLs are fetched. App links and file paths stay unchanged.
- Requests use a private ephemeral session with no URL cache. Metadata and images stay in memory.
- Selection cancellation cancels network work and prevents an old result from replacing the new card.
- HTML reads stop at 128 KB, icons at 512 KB and banners at 2 MB. Requests time out after 10 seconds.
- Banners decode to a static first frame capped at 1600 pixels, icons at 64 pixels. The memory cache
  holds at most 24 entries with a 24 MB image cost limit.
- Missing metadata or failed requests fall back to the URL's host without blocking paste actions.

## Implementation

`AppCore` owns `LinkPreviewStore` and injects it through the palette environment.
`LinkPreviewDocument` parses metadata with Foundation only. Open Graph takes precedence over Twitter
Card and HTML metadata. Relative image and icon URLs resolve against the final page URL.
When a page has no banner, the fetcher tries its site's home page metadata.

`LinkPreviewCard` owns the selection task. `ClipboardView` reads cached titles and favicons.
The parser harness is registered as `link-preview-test` in `Scripts/run-tests.sh`.
