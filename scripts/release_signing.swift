#!/usr/bin/env swift
import Foundation
import CryptoKit

// Raw Ed25519 keys and signatures; no additional runtime dependency.
let args = CommandLine.arguments
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mac-dictation-agent-release")
let privateURL = root.appendingPathComponent("update-private.key")
let publicURL = root.appendingPathComponent("update-public.key")
do {
    switch args.dropFirst().first {
    case "generate":
        guard !FileManager.default.fileExists(atPath: privateURL.path),
              !FileManager.default.fileExists(atPath: publicURL.path) else {
            throw NSError(domain: "Keys already exist; never replace release identity", code: 1)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: privateURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
        try key.publicKey.rawRepresentation.write(to: publicURL, options: .withoutOverwriting)
        print(key.publicKey.rawRepresentation.base64EncodedString())
    case "sign" where args.count == 4:
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: privateURL))
        let signature = try key.signature(for: Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe))
        try signature.write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
    default:
        fputs("usage: release_signing.swift generate | sign ARCHIVE SIGNATURE\n", stderr)
        exit(2)
    }
} catch {
    fputs("Release signing failed: \(error)\n", stderr)
    exit(1)
}
