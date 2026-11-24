import Foundation
import CryptoKit

/// Deliberately distinct from forward-update discovery. Only an explicitly
/// supported predecessor is offered. An unsigned GitHub response cannot
/// choose the downgrade version or authorize executable contents.
public struct SignedRollbackPackage: Equatable, Sendable {
    public let version:String
    public let build:String
    public let byteCount:Int
    public let sha256:String

    public static func previous(for installed:String) -> Self? {
        guard installed == "0.19.2" else { return nil }
        return .init(version:"0.19.1",build:"199",byteCount:90_423_835,
            sha256:"69ad432f94baed0034c74666f707682bf0d25efa5c09bd079d2e3403f2479308")
    }
    public var archiveURL:URL { SignedUpdatePolicy.assetURL(version:version)! }
    public var signatureURL:URL { URL(string:archiveURL.absoluteString+".edsignature")! }

    // Internal verification primitive also exercised with independent test keys.
    static func verify(bytes:Data,signature:Data,publicKey:Data) throws {
        let key=try Curve25519.Signing.PublicKey(rawRepresentation:publicKey)
        guard signature.count==64,key.isValidSignature(signature,for:bytes) else {
            throw ApplicationRollback.Failure("Firma Ed25519 del pacchetto precedente non valida.")
        }
    }

    public func validateArchive(_ url:URL,signatureText:Data) throws {
        let meta=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard meta.isRegularFile==true,meta.isSymbolicLink != true,
              meta.fileSize==byteCount,signatureText.count<=256,
              let text=String(data:signatureText,encoding:.utf8),
              let signature=Data(base64Encoded:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              let key=Data(base64Encoded:SignedUpdatePolicy.publicKey) else {
            throw ApplicationRollback.Failure("Pacchetto precedente o firma non corrispondenti.")
        }
        let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
        let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        guard bytes.count==byteCount,digest==sha256 else {
            throw ApplicationRollback.Failure("SHA-256 del pacchetto precedente non corrispondente.")
        }
        try Self.verify(bytes:bytes,signature:signature,publicKey:key)
    }

    /// The ZIP is verified before extraction; no untrusted archive is opened.
    /// Caller owns a unique, private staging directory and cleans it up.
    public func prepare(in staging:URL) async throws -> URL {
        let fm=FileManager.default
        let values=try staging.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true,
              staging.resolvingSymlinksInPath().path==staging.path,
              try fm.contentsOfDirectory(atPath:staging.path).isEmpty else {
            throw ApplicationRollback.Failure("Cartella temporanea rollback non valida.")
        }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=30
        configuration.timeoutIntervalForResource=600
        configuration.httpShouldSetCookies=false
        configuration.urlCache=nil
        let session=URLSession(configuration:configuration)
        defer { session.finishTasksAndInvalidate() }
        let (signature,response)=try await session.data(from:signatureURL)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,
              response.url?.scheme=="https",signature.count<=256 else {
            throw ApplicationRollback.Failure("Firma della versione precedente non disponibile.")
        }
        let (temporary,downloadResponse)=try await session.download(from:archiveURL)
        defer { try? fm.removeItem(at:temporary) }
        guard let downloadHTTP=downloadResponse as? HTTPURLResponse,downloadHTTP.statusCode==200,
              downloadResponse.url?.scheme=="https" else {
            throw ApplicationRollback.Failure("Pacchetto precedente non disponibile.")
        }
        let zip=staging.appendingPathComponent("previous.zip")
        try fm.moveItem(at:temporary,to:zip)
        try validateArchive(zip,signatureText:signature)
        try signature.write(to:staging.appendingPathComponent("previous.edsignature"),options:.withoutOverwriting)
        try Task.checkCancellation()
        let expanded=staging.appendingPathComponent("expanded",isDirectory:true)
        try fm.createDirectory(at:expanded,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-x","-k",zip.path,expanded.path]
        process.standardOutput=FileHandle.nullDevice
        process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else {
            throw ApplicationRollback.Failure("Estrazione del pacchetto precedente non riuscita.")
        }
        let app=expanded.appendingPathComponent("MacSync.app")
        try validateApplication(app)
        return app
    }

    public func validateApplication(_ app:URL) throws {
        try ApplicationRollback.validateBundle(app,version:version)
        guard Bundle(url:app)?.object(forInfoDictionaryKey:"CFBundleVersion") as? String==build else {
            throw ApplicationRollback.Failure("Build precedente non corrispondente.")
        }
    }
}
