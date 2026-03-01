import Foundation
import NetworkExtension

/// Manages VLESS/Xray VPN connection via a Packet Tunnel extension.
/// Uses same technology as dopplerswift: pass xrayJSON in providerConfiguration["xrayJSON"].
final class VlessTunnelManager {
    static let shared = VlessTunnelManager()

    /// Bundle ID of the Packet Tunnel extension. Must match the extension target's PRODUCT_BUNDLE_IDENTIFIER.
    private let tunnelBundleId = "com.theholylabs.foxywall.VlessTunnel"

    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: Any?

    var currentStatus: NEVPNStatus {
        tunnelManager?.connection.status ?? .invalid
    }

    var isConnected: Bool {
        currentStatus == .connected
    }

    private init() {}

    /// Connect using full Xray JSON config (same as dopplerswift). Saves to App Group as backup.
    func connect(xrayJSON: String, completion: @escaping (Error?) -> Void) {
        let json = xrayJSON.trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty else {
            completion(NSError(domain: "VlessTunnelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty Xray config"]))
            return
        }

        ConfigStore.saveXrayConfig(json)

        loadOrCreateManager { [weak self] manager, error in
            guard let self = self else { return }
            if let error = error {
                completion(error)
                return
            }
            guard let manager = manager else {
                completion(NSError(domain: "VlessTunnelManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create tunnel manager"]))
                return
            }

            let protocolConfig = manager.protocolConfiguration as? NETunnelProviderProtocol ?? NETunnelProviderProtocol()
            protocolConfig.providerBundleIdentifier = self.tunnelBundleId
            protocolConfig.serverAddress = "VLESS"
            protocolConfig.providerConfiguration = ["xrayJSON": json]
            manager.protocolConfiguration = protocolConfig
            manager.localizedDescription = "FoxyWall VLESS"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    completion(saveError)
                    return
                }
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        completion(loadError)
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self.tunnelManager = manager
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        }
    }

    /// Connect using VLESS URL from Supabase (same format as Android). Converts to Xray JSON then connects.
    func connect(vlessUrl: String, completion: @escaping (Error?) -> Void) {
        let url = vlessUrl.trimmingCharacters(in: .whitespaces)
        guard url.lowercased().hasPrefix("vless://") else {
            completion(NSError(domain: "VlessTunnelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid VLESS URL"]))
            return
        }

        do {
            let config = try VLessParser.parse(url)
            let xrayJSON = XrayConfigBuilder.buildJSON(from: config)
            connect(xrayJSON: xrayJSON, completion: completion)
        } catch {
            completion(error)
        }
    }
    
    func disconnect() {
        tunnelManager?.connection.stopVPNTunnel()
    }
    
    /// Call from the main app to observe tunnel status changes (e.g. update isConnected UI).
    func observeStatus(using block: @escaping (NEVPNStatus) -> Void) {
        if let obs = statusObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let status: NEVPNStatus = (note.object as? NEVPNConnection)?.status ?? self?.currentStatus ?? .invalid
            block(status)
        }
    }
    
    private func loadOrCreateManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                completion(nil, error)
                return
            }
            let existing = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self?.tunnelBundleId }
            if let existing = existing {
                completion(existing, nil)
                return
            }
            let newManager = NETunnelProviderManager()
            completion(newManager, nil)
        }
    }
}

extension Notification.Name {
    static let VlessTunnelStatusDidChange = NEVPNStatusDidChange
}
