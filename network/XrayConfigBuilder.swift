import Foundation

/// Builds Xray JSON from VLessConfig — same structure as dopplerswift (VLESS outbound, Reality/TLS, routing).
enum XrayConfigBuilder {

    private static let supportedGeoIPCountries: Set<String> = [
        "de", "gb", "fr", "nl", "ru", "us", "tr", "it", "es", "pl",
        "ua", "kz", "ae", "il", "cn", "br", "jp", "kr", "in", "au", "ca"
    ]

    /// Build full Xray config JSON from a single VLESS config (no smart routing for now).
    static func buildJSON(
        from config: VLessConfig,
        smartRoutingCountry: String? = nil,
        smartRoutingCustomDomains: [String] = [],
        bypassTLDWebsites: Bool = true,
        bypassDomesticIPs: Bool = true
    ) -> String {
        let outbounds: [[String: Any]] = [
            buildProxyOutbound(from: config),
            ["tag": "direct", "protocol": "freedom"],
            ["tag": "block", "protocol": "blackhole"]
        ]

        var routingRules: [[String: Any]] = []

        if let country = smartRoutingCountry, !country.isEmpty {
            let code = country.lowercased()
            let hasGeoIP = supportedGeoIPCountries.contains(code)
            if bypassTLDWebsites {
                routingRules.append([
                    "type": "field",
                    "domain": ["domain:\(code)"],
                    "outboundTag": "direct"
                ])
            }
            if bypassDomesticIPs && hasGeoIP {
                routingRules.append([
                    "type": "field",
                    "ip": ["geoip:\(code)"],
                    "outboundTag": "direct"
                ])
            }
        }

        if !smartRoutingCustomDomains.isEmpty {
            let domainPatterns = smartRoutingCustomDomains.map { domain -> String in
                if domain.hasPrefix("domain:") || domain.hasPrefix("full:") || domain.hasPrefix("regexp:") {
                    return domain
                }
                return "domain:\(domain)"
            }
            routingRules.append([
                "type": "field",
                "domain": domainPatterns,
                "outboundTag": "direct"
            ])
        }

        routingRules.append([
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": "proxy"
        ])

        var root: [String: Any] = [:]
        root["routing"] = [
            "domainStrategy": "AsIs",
            "rules": routingRules
        ]
        root["outbounds"] = outbounds

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func buildProxyOutbound(from config: VLessConfig) -> [String: Any] {
        var user: [String: Any] = [
            "id": config.uuid,
            "encryption": "none"
        ]
        if let flow = config.flow, !flow.isEmpty {
            user["flow"] = flow
        }

        let vnextEntry: [String: Any] = [
            "address": config.address,
            "port": config.port,
            "users": [user]
        ]
        let settings: [String: Any] = ["vnext": [vnextEntry]]

        return [
            "tag": "proxy",
            "protocol": "vless",
            "settings": settings,
            "streamSettings": buildStreamSettings(from: config)
        ]
    }

    private static func buildStreamSettings(from config: VLessConfig) -> [String: Any] {
        var stream: [String: Any] = [
            "network": config.network,
            "security": config.security
        ]

        switch config.security {
        case "reality":
            stream["realitySettings"] = buildRealitySettings(from: config)
        case "tls":
            stream["tlsSettings"] = buildTLSSettings(from: config)
        default:
            break
        }

        switch config.network {
        case "ws":
            if let path = config.path {
                stream["wsSettings"] = ["path": path]
            }
        case "grpc":
            if let serviceName = config.serviceName {
                stream["grpcSettings"] = ["serviceName": serviceName]
            }
        case "h2":
            if let path = config.path {
                stream["httpSettings"] = ["path": path]
            }
        default:
            break
        }

        return stream
    }

    private static func buildRealitySettings(from config: VLessConfig) -> [String: Any] {
        var settings: [String: Any] = [
            "show": false,
            "spiderX": ""
        ]
        if let sni = config.sni { settings["serverName"] = sni }
        if let fingerprint = config.fingerprint { settings["fingerprint"] = fingerprint }
        if let publicKey = config.publicKey { settings["publicKey"] = publicKey }
        if let shortId = config.shortId { settings["shortId"] = shortId }
        return settings
    }

    private static func buildTLSSettings(from config: VLessConfig) -> [String: Any] {
        var settings: [String: Any] = [:]
        if let sni = config.sni { settings["serverName"] = sni }
        if let fingerprint = config.fingerprint { settings["fingerprint"] = fingerprint }
        return settings
    }
}
