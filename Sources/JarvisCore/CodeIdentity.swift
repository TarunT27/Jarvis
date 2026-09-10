import Foundation
import Security
public enum CodeIdentity {
    /// Pin the current installed peer's CodeDirectory hash, including for an ad-hoc personal build.
    public static func requirement(at url:URL) throws -> String {
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL,[],&code)==errSecSuccess,let code,
              SecStaticCodeCheckValidity(code,[],nil)==errSecSuccess else { throw JarvisError.message("Peer application signature is invalid.") }
        var info:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let dictionary=info as? [String:Any],let hash=dictionary[kSecCodeInfoUnique as String] as? Data else { throw JarvisError.message("Cannot verify peer application identity.") }
        return "cdhash H\""+hash.map { String(format:"%02x",$0) }.joined()+"\""
    }
}
