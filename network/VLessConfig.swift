import Foundation

/// Parsed VLESS config (same shape as dopplerswift for Xray JSON building).
struct VLessConfig: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let address: String
    let port: Int
    let uuid: String
    let flow: String?
    let security: String
    let sni: String?
    let publicKey: String?
    let shortId: String?
    let fingerprint: String?
    let network: String
    let path: String?
    let serviceName: String?
    let remark: String
    let rawURI: String
}
