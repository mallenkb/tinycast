import Foundation
import Security

/// Proves a staged bundle is ours: a pinned fork leaf, or the leaf the running copy was signed with.
enum BundleSignature {
    /// SHA-1 of each `Tinycast Self-Signed` leaf this fork releases with; add the next before rotating.
    static let trustedLeaves = ["d8b274154817b753049cc0d63af0bf709fc5d7ab"]

    static var requirement: String {
        trustedLeaves.map { "certificate leaf = H\"\($0)\"" }.joined(separator: " or ")
    }

    static func isTrusted(_ bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return false }
        // An unsealed bundle can claim any identity, and a nested helper is where one hides.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else { return false }
        if satisfiesPinnedLeaf(staticCode, flags: flags) { return true }
        // A copy signed by a leaf not yet pinned still accepts builds signed by that same leaf.
        guard let running = runningLeaf(), let candidate = leaf(of: staticCode) else { return false }
        return running == candidate
    }

    private static func satisfiesPinnedLeaf(_ code: SecStaticCode, flags: SecCSFlags) -> Bool {
        var compiled: SecRequirement?
        guard
            SecRequirementCreateWithString(Self.requirement as CFString, [], &compiled)
                == errSecSuccess, let compiled
        else { return false }
        return SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
    }

    private static func runningLeaf() -> Data? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        return leaf(of: staticCode)
    }

    private static func leaf(of code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
