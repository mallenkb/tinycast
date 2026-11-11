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
- Bannerless results can retry on selection after 15 seconds; no background retry timer runs.
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
Invalid image URLs are skipped. The fetcher tries up to three distinct Open Graph or Twitter image
URLs sequentially, stopping at the first decodable image. If no banner loads, it tries the site's home
page metadata, with at most four image downloads across both pages. Image requests also send the
browser-compatible user agent. Downsampling disables the source-image cache to avoid retaining a
full-size decoded copy alongside the thumbnail.

`LinkPreviewCard` owns the selection task. `ClipboardView` reads cached titles and favicons.
The parser harness is registered as `link-preview-test` in `Scripts/run-tests.sh`.
