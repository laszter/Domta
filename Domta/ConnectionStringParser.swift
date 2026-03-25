//
//  ConnectionStringParser.swift
//  Domta
//
//  Created by Codex on 25/3/26.
//

import Foundation

enum ConnectionStringParser {
    static func parse(_ rawValue: String) throws -> SQLConnectionConfiguration {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompareAppError.invalidConnectionString("ยังไม่ได้ใส่ค่า")
        }

        let segments = splitSegments(trimmed)
        var values: [String: String] = [:]

        for segment in segments {
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let key = String(segment[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(segment[segment.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = unwrapped(value)
        }

        let server = firstMatch(in: values, keys: ["server", "data source", "addr", "address", "network address"])
        guard let server, !server.isEmpty else {
            throw CompareAppError.invalidConnectionString("ไม่พบ `Server` หรือ `Data Source`")
        }

        let database = firstMatch(in: values, keys: ["database", "initial catalog"])
        let username = firstMatch(in: values, keys: ["user id", "uid", "user"])
        let password = firstMatch(in: values, keys: ["password", "pwd"])
        let integratedSecurity = parseBool(firstMatch(in: values, keys: ["integrated security", "trusted_connection", "trusted connection"])) ?? false
        let trustServerCertificate = parseBool(firstMatch(in: values, keys: ["trustservercertificate", "trust server certificate"])) ?? false
        let encrypt = parseBool(firstMatch(in: values, keys: ["encrypt"]))

        return SQLConnectionConfiguration(
            server: server,
            database: database,
            username: username,
            password: password,
            trustServerCertificate: trustServerCertificate,
            encrypt: encrypt,
            isIntegratedSecurity: integratedSecurity
        )
    }

    private static func firstMatch(in values: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = values[key.lowercased()] {
                return value
            }
        }

        return nil
    }

    private static func splitSegments(_ connectionString: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var braceDepth = 0
        var quoteCharacter: Character?

        for character in connectionString {
            if quoteCharacter == nil && character == ";" && braceDepth == 0 {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(current)
                }
                current = ""
                continue
            }

            if character == "{" && quoteCharacter == nil {
                braceDepth += 1
            } else if character == "}" && quoteCharacter == nil && braceDepth > 0 {
                braceDepth -= 1
            } else if character == "\"" || character == "'" {
                if quoteCharacter == character {
                    quoteCharacter = nil
                } else if quoteCharacter == nil {
                    quoteCharacter = character
                }
            }

            current.append(character)
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(current)
        }

        return segments
    }

    private static func unwrapped(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return String(trimmed.dropFirst().dropLast())
        }

        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }

        return trimmed
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1", "mandatory":
            return true
        case "false", "no", "0", "optional", "disable", "disabled":
            return false
        default:
            return nil
        }
    }
}
