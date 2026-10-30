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
- HTML reads stop at the closing head tag or 2 MiB, icons at 512 KB and banners at 2 MB.
  Requests time out after 10 seconds.
- Banners decode to a static first frame capped at 1000 pixels and 3 MB of decoded pixels;
  square and high-bit-depth images may render smaller to fit that budget. Icons stay at 64 pixels.
- Bannerless results can retry after 60 seconds so failed image requests do not persist all session.
- Metadata and favicons retain up to 24 entries with a 1 MiB cost limit. Only the latest banner
  stays cached, with a 3 MB budget. Revisiting an older banner fetches it again.
- Hiding clears banners and prevents pending requests from restoring them.
- Missing metadata or failed requests fall back to the URL's host without blocking paste actions.

## Implementation

`AppCore` owns `LinkPreviewStore` and injects it through the palette environment.
`LinkPreviewDocument` parses metadata with Foundation only. Open Graph takes precedence over Twitter
Card and HTML metadata, including `og:image:url`, `og:image:secure_url`, and `twitter:image:src`.
The parser shares the fetcher’s 2 MiB limit so large page scripts do not hide later metadata. Relative image and icon URLs resolve against the final page URL.
HTML requests use a browser-compatible user agent to avoid mobile shells that omit head metadata.
When a page has no banner, the fetcher tries its site's home page metadata.

`LinkPreviewCard` owns the selection task. `ClipboardView` reads cached titles and favicons.
The parser harness is registered as `link-preview-test` in `Scripts/run-tests.sh`.
