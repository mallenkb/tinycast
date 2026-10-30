import Foundation

@main
struct LinkPreviewTests {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        detection()
        titles()
        metadata()
        lateMetadata()
        icons()
        faviconFallback()
        siteRoots()
        twitterImage()
        bookmarks()

        print(failures == 0 ? "Link preview tests passed" : "\(failures) link preview tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func detection() {
        let https = LinkPreviewDocument.pageURL(from: "https://github.com/abue-ammar/tinycast.git")
        expect(https?.absoluteString == "https://github.com/abue-ammar/tinycast.git",
            "a copied https URL is a page")
        let spaced = LinkPreviewDocument.pageURL(from: "  http://example.com/a b  ")
        expect(spaced?.absoluteString == "http://example.com/a%20b",
            "a spaced URL is rescued the way quicklinks rescue one")
        let bare = LinkPreviewDocument.pageURL(from: "github.com/abue-ammar")
        expect(bare?.absoluteString == "https://github.com/abue-ammar",
            "a bare host reads as https")
        expect(LinkPreviewDocument.pageURL(from: "just some words") == nil, "prose is no page")
        expect(
            LinkPreviewDocument.pageURL(from: "mailto:a@example.com") == nil,
            "a deeplink never fetches")
        expect(LinkPreviewDocument.pageURL(from: "/tmp/report.pdf") == nil, "a path never fetches")
        let rescued = LinkPreviewDocument.pageURL(from: "https://x.com/a b")
        expect(rescued?.absoluteString == "https://x.com/a%20b",
            "an inner space is rescued rather than refusing the page")
    }

    static func titles() {
        let base = URL(string: "https://example.com/a")!
        expect(
            LinkPreviewDocument.parseHead("<head><title>Tinycast</title></head>", baseURL: base)
                .title == "Tinycast",
            "the document title is read")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><title>Plain</title><meta property=\"og:title\" content=\"Rich\"></head>",
                baseURL: base
            ).title == "Rich",
            "og:title wins over the document title")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><TITLE> Loud </TITLE></head>", baseURL: base
            ).title == "Loud",
            "tags match case-insensitively and trim")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><title>Fish &amp; Chips &#8212; ok</title></head>", baseURL: base
            ).title == "Fish & Chips — ok",
            "entities decode")
        for (source, decoded) in [
            ("End &#39;", "End '"),
            ("End &#x27;", "End '"),
            ("End &apos;", "End '"),
            ("End &unknown;", "End &unknown;"),
            ("End &x;", "End &x;"),
            ("End &", "End &"),
            ("End &#123456789;", "End &#123456789;")
        ] {
            expect(
                LinkPreviewDocument.parseHead(
                    "<head><title>\(source)</title></head>", baseURL: base
                ).title == decoded,
                "a trailing entity decodes or stays literal within the remaining text")
        }
        expect(
            LinkPreviewDocument.parseHead("<head></head>", baseURL: base).title == nil,
            "no title reads nil")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><title>  </title></head>", baseURL: base
            ).title == nil,
            "a blank title reads nil")
    }

    static func metadata() {
        let base = URL(string: "https://example.com/a")!
        let doc = LinkPreviewDocument.parseHead(
            "<head><meta property=\"og:title\" content=\"T\">"
                + "<meta property=\"og:description\" content=\"Plain &amp; simple\">"
                + "<meta property=\"og:image\" content=\"/cover.png\"></head>",
            baseURL: base)
        expect(doc.description == "Plain & simple", "og:description decodes entities")
        expect(doc.imagePath == "https://example.com/cover.png",
            "og:image resolves against the page")
        let fallback = LinkPreviewDocument.parseHead(
            "<head><meta name=\"description\" content=\"Old style\"></head>", baseURL: base)
        expect(fallback.description == "Old style", "a plain description is the fallback")
        expect(fallback.imagePath == nil, "no image reads nil")
    }

    static func lateMetadata() {
        let base = URL(string: "https://example.com/video")!
        let prefix = "<head><script>" + String(repeating: " ", count: 800_000) + "</script>"
        let html = prefix + "<meta property='og:title' content='Video title'>"
            + "<meta property='og:image' content='/video.jpg'></head>"
            + "<meta property='og:image' content='/wrong-body.jpg'>"
        let head = LinkPreviewDocument.parseHead(html, baseURL: base)
        expect(head.title == "Video title", "metadata after a large script remains reachable")
        expect(head.imagePath == "https://example.com/video.jpg", "late OG image beats body markup")
        for key in ["og:image:url", "og:image:secure_url", "twitter:image:src"] {
            let html = "<meta property='\(key)' content='/photo.jpg?a=1&amp;b=2'>"
            expect(LinkPreviewDocument.parseHead(html, baseURL: base).imagePath
                == "https://example.com/photo.jpg?a=1&b=2", "image alias \(key) resolves")
        }
        let oversized = String(repeating: " ", count: LinkPreviewDocument.headByteLimit)
            + "<meta property='og:image' content='/outside-budget.jpg'>"
        expect(LinkPreviewDocument.parseHead(oversized, baseURL: base).imagePath == nil,
            "metadata scanning remains bounded")
    }

    static func icons() {
        let base = URL(string: "https://example.com/blog/post")!
        expect(
            LinkPreviewDocument.parseHead(
                "<head><link rel=\"icon\" href=\"/i.png\"></head>", baseURL: base
            ).iconPath == "https://example.com/i.png",
            "a root-relative icon resolves")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><link rel=\"shortcut icon\" href=\"//cdn.example.com/f.ico\"></head>",
                baseURL: base
            ).iconPath == "https://cdn.example.com/f.ico",
            "a protocol-relative icon takes the page scheme")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><link rel=\"stylesheet\" href=\"/s.css\">"
                    + "<LINK REL=\"apple-touch-icon\" HREF=\"touch.png\"></head>",
                baseURL: base
            ).iconPath == "https://example.com/blog/touch.png",
            "a relative icon resolves against the page, matching case-insensitively")
        expect(
            LinkPreviewDocument.parseHead(
                "<head><link rel=\"icon\" href=\"https://a.com/x.svg\"></head>", baseURL: base
            ).iconPath == "https://a.com/x.svg",
            "an absolute icon passes through")
        expect(
            LinkPreviewDocument.parseHead("<head></head>", baseURL: base).iconPath == nil,
            "no icon link reads nil")
    }

    static func faviconFallback() {
        let plain = LinkPreviewDocument.faviconFallback(for: URL(string: "https://x.com/a/b?c=1")!)
        expect(plain?.absoluteString == "https://x.com/favicon.ico",
            "the fallback keeps the origin and drops the path")
        let ported = LinkPreviewDocument.faviconFallback(for: URL(string: "http://x.com:8080/a")!)
        expect(ported?.absoluteString == "http://x.com:8080/favicon.ico",
            "the fallback keeps a port")
    }

    static func siteRoots() {
        let file = URL(string: "https://www.figma.com/design/abc/File?node-id=1-2")!
        expect(LinkPreviewDocument.siteRoot(for: file)?.absoluteString == "https://www.figma.com/",
            "a deep page falls back to its site's home page")
        expect(LinkPreviewDocument.siteRoot(for: URL(string: "https://figma.com/")!) == nil,
            "a home page has no root of its own to fall back to")
        expect(LinkPreviewDocument.siteRoot(for: URL(string: "https://x.com/?q=1")!) != nil,
            "a query makes the root a different page")
    }

    static func twitterImage() {
        let base = URL(string: "https://example.com/a")!
        let head = LinkPreviewDocument.parseHead(
            "<head><meta name=\"twitter:image\" content=\"/card.png?a=1&amp;b=2\"></head>",
            baseURL: base)
        expect(head.imagePath == "https://example.com/card.png?a=1&b=2",
            "twitter:image stands in for a missing og:image, entities decoded")
        let both = LinkPreviewDocument.parseHead(
            "<head><meta name=\"twitter:image\" content=\"/t.png\">"
                + "<meta property=\"og:image\" content=\"/og.png\"></head>",
            baseURL: base)
        expect(both.imagePath == "https://example.com/og.png", "og:image wins over twitter:image")
    }

    static func bookmarks() {
        let webloc =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
            + "<plist version=\"1.0\"><dict><key>URL</key>"
            + "<string>https://example.com/saved</string></dict></plist>"
        expect(
            LinkPreviewDocument.bookmarkURL(fromWebloc: Data(webloc.utf8))?.absoluteString
                == "https://example.com/saved",
            "a webloc resolves to its page")
        expect(
            LinkPreviewDocument.bookmarkURL(fromWebloc: Data("not a plist".utf8)) == nil,
            "a broken webloc resolves nowhere")
        expect(
            LinkPreviewDocument.bookmarkURL(
                fromURLFile: "[InternetShortcut]\r\nURL=https://example.com/s\r\n")?.absoluteString
                == "https://example.com/s",
            "a .url file resolves off its URL line")
        expect(
            LinkPreviewDocument.bookmarkURL(fromURLFile: "[InternetShortcut]\r\n") == nil,
            "a .url file without one resolves nowhere")
        expect(
            LinkPreviewDocument.bookmarkURL(fromURLFile: "URL=file:///tmp/x") == nil,
            "a bookmark to a local file never fetches")
    }
}
