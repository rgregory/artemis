import Foundation
import Security

// Private-but-stable libsandbox call: returns 1 if the process is sandboxed, 0 if not.
@_silgen_name("sandbox_check")
private func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

struct CodeInfo {
    var signing: SigningState = .unsigned
    var teamID: String = ""
    var hardenedRuntime = false
    var sandboxEntitlement = false
    var entitlements: [EntitlementItem] = []
}

enum SandboxInspector {
    static let sandboxKey = "com.apple.security.app-sandbox"

    private static let adHocFlag: UInt32 = 0x0002      // kSecCodeSignatureAdhoc
    private static let runtimeFlag: UInt32 = 0x10000   // kSecCodeSignatureRuntime

    /// Reads the code signature of a bundle (static, on-disk) and pulls out its entitlements.
    static func inspect(_ url: URL) -> CodeInfo {
        var result = CodeInfo()

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return result }

        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &cfInfo) == errSecSuccess,
              let info = cfInfo as? [String: Any] else { return result }

        // Unsigned code still returns a dictionary, just without an identifier.
        guard info[kSecCodeInfoIdentifier as String] != nil else { return result }

        let sigFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        result.signing = (sigFlags & adHocFlag) != 0 ? .adHoc : .signed
        result.hardenedRuntime = (sigFlags & runtimeFlag) != 0
        result.teamID = info[kSecCodeInfoTeamIdentifier as String] as? String ?? ""

        if let ents = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            result.sandboxEntitlement = isTrue(ents[sandboxKey])
            result.entitlements = ents.keys.sorted().map {
                EntitlementItem(key: $0, value: describe(ents[$0]))
            }
        }
        return result
    }

    /// Asks the kernel whether a live process is actually inside a sandbox.
    static func isProcessSandboxed(_ pid: pid_t) -> Bool {
        sandbox_check(pid, nil, 0) != 0
    }

    private static func isTrue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.map { describe($0) }.joined(separator: ", ") }
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().map { "\($0): \(describe(dict[$0]))" }.joined(separator: ", ")
        }
        return String(describing: value)
    }
}
