import Foundation
import Security

// Used only by explicit, one-time signing setup. No login/account secrets are read.
func checked(_ status: OSStatus) throws {
    if status != errSecSuccess {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "QingyiSigning", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected PKCS12 file, transport-password file, keychain path"])
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let password = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).trimmingCharacters(in: .newlines)
    var keychain: SecKeychain?
    try checked(SecKeychainOpen(CommandLine.arguments[3], &keychain))
    var trusted: SecTrustedApplication?
    try checked(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted))
    var access: SecAccess?
    try checked(SecAccessCreate("Qingyi" as CFString, [trusted!] as CFArray, &access))
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    let passwordCF = password as CFString
    let keyUsage = [kSecAttrCanSign] as CFArray
    let keyAttributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
    parameters.flags = [.importOnlyOne]
    parameters.passphrase = .passUnretained(passwordCF)
    parameters.accessRef = .passUnretained(access!)
    parameters.keyUsage = .passUnretained(keyUsage)
    parameters.keyAttributes = .passUnretained(keyAttributes)
    var format: SecExternalFormat = .formatPKCS12
    var type: SecExternalItemType = .itemTypeAggregate
    var items: CFArray?
    try withExtendedLifetime((passwordCF, access, keyUsage, keyAttributes)) {
        try checked(SecItemImport(data as CFData, nil, &format, &type, [], &parameters, keychain, &items))
    }
    print("Imported Qingyi identity; key is permanent, sensitive and non-extractable.")
} catch {
    fputs("Signing import failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
