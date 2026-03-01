import Foundation

// MARK: - Parser Errors

enum VLessParserError: LocalizedError {
    case invalidScheme
    case missingUUID
    case missingHost
    case missingPort
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "Invalid URI scheme. Expected vless://."
        case .missingUUID:
            return "UUID is missing from the VLESS URI."
        case .missingHost:
            return "Host address is missing from the VLESS URI."
        case .missingPort:
            return "Port number is missing from the VLESS URI."
        case .invalidPort:
            return "Port number is not a valid integer (1-65535)."
        }
    }
}

// MARK: - Parser

/// Parses vless:// URIs (including Reality params) into VLessConfig — same approach as dopplerswift.
enum VLessParser {

    /// Parses a `vless://` URI string into a `VLessConfig`.
    /// Format: `vless://uuid@host:port?param1=val1&param2=val2#remark`
    static func parse(_ uriString: String) throws -> VLessConfig {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "vless://"
        guard trimmed.lowercased().hasPrefix(prefix) else {
            throw VLessParserError.invalidScheme
        }

        let withoutScheme = String(trimmed.dropFirst(prefix.count))
        let (beforeFragment, remark) = splitOnce(withoutScheme, separator: "#")
        let (authority, queryString) = splitOnce(beforeFragment, separator: "?")
        let (uuid, hostPort) = try parseAuthority(authority)
        let (host, port) = try parseHostPort(hostPort)
        let params = parseQueryParams(queryString)
        let decodedRemark = remark.removingPercentEncoding ?? remark

        return VLessConfig(
            id: UUID(),
            address: host,
            port: port,
            uuid: uuid,
            flow: params["flow"],
            security: params["security"] ?? "none",
            sni: params["sni"],
            publicKey: params["pbk"],
            shortId: params["sid"],
            fingerprint: params["fp"],
            network: params["type"] ?? "tcp",
            path: params["path"]?.removingPercentEncoding,
            serviceName: params["serviceName"],
            remark: decodedRemark.isEmpty ? host : decodedRemark,
            rawURI: trimmed
        )
    }

    private static func splitOnce(_ string: String, separator: Character) -> (String, String) {
        guard let index = string.firstIndex(of: separator) else {
            return (string, "")
        }
        let before = String(string[string.startIndex..<index])
        let after = String(string[string.index(after: index)...])
        return (before, after)
    }

    private static func parseAuthority(_ authority: String) throws -> (String, String) {
        guard let atIndex = authority.firstIndex(of: "@") else {
            throw VLessParserError.missingUUID
        }
        let uuid = String(authority[authority.startIndex..<atIndex]).trimmingCharacters(in: .whitespaces)
        let hostPort = String(authority[authority.index(after: atIndex)...])
        guard !uuid.isEmpty else { throw VLessParserError.missingUUID }
        return (uuid, hostPort)
    }

    private static func parseHostPort(_ hostPort: String) throws -> (String, Int) {
        let host: String
        let portString: String

        if hostPort.hasPrefix("[") {
            guard let closingBracket = hostPort.firstIndex(of: "]") else {
                throw VLessParserError.missingHost
            }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closingBracket])
            let after = hostPort[hostPort.index(after: closingBracket)...]
            portString = after.hasPrefix(":") ? String(after.dropFirst()) : String(after)
        } else {
            if let colon = hostPort.lastIndex(of: ":") {
                host = String(hostPort[..<colon])
                portString = String(hostPort[hostPort.index(after: colon)...])
            } else {
                throw VLessParserError.missingPort
            }
        }

        guard let port = Int(portString), port >= 1, port <= 65535 else {
            throw VLessParserError.invalidPort
        }
        guard !host.isEmpty else { throw VLessParserError.missingHost }
        return (host, port)
    }

    private static func parseQueryParams(_ queryString: String) -> [String: String] {
        guard !queryString.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            params[String(key)] = value.removingPercentEncoding ?? value
        }
        return params
    }
}
