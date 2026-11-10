import Foundation

@main
nonisolated enum SpotlightContentHelper {
    static func main() async {
        exit(await SpotlightContentHandler.run())
    }
}
