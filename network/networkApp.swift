import SwiftUI
import RevenueCat
import CoreLocation
import MapKit
import UniformTypeIdentifiers
import NetworkExtension
import Security
import Foundation
import Network
import NetworkExtension


// MARK: - Language Manager
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    static let supportedLanguages: [(code: String, name: String, nativeName: String)] = [
        ("en",      "English",            "English"),
        ("ar",      "Arabic",             "العربية"),
        ("de",      "German",             "Deutsch"),
        ("es",      "Spanish",            "Español"),
        ("fr",      "French",             "Français"),
        ("he",      "Hebrew",             "עברית"),
        ("hi",      "Hindi",              "हिन्दी"),
        ("id",      "Indonesian",         "Indonesia"),
        ("pt-BR",   "Portuguese (Brazil)","Português (BR)"),
        ("ru",      "Russian",            "Русский"),
        ("tr",      "Turkish",            "Türkçe"),
        ("zh-Hans", "Chinese Simplified", "简体中文"),
    ]

    @Published private(set) var bundle: Bundle = .main

    /// Device preferred language code if it's in our supported list; otherwise nil.
    private static func deviceLanguageCode() -> String? {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en"
        let supported = Set(supportedLanguages.map(\.code))
        if supported.contains(preferred) { return preferred }
        let langPart = preferred.components(separatedBy: "-").first ?? preferred
        if supported.contains(langPart) { return langPart }
        if langPart == "pt" { return "pt-BR" }
        return nil
    }

    /// Current app language: explicit user choice if set, otherwise device language (if supported), else "en".
    var currentLanguageCode: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "appLanguage"), !saved.isEmpty {
                return saved
            }
            return Self.deviceLanguageCode() ?? "en"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "appLanguage")
            updateBundle(for: newValue)
        }
    }

    private init() {
        let code = UserDefaults.standard.string(forKey: "appLanguage").flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.deviceLanguageCode()
            ?? "en"
        updateBundle(for: code)
    }

    private func updateBundle(for code: String) {
        // Find the .lproj folder for this language code
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
        objectWillChange.send()
    }
}

@main
struct NetworkApp: App {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @StateObject private var languageManager = LanguageManager.shared

    var body: some Scene {
        WindowGroup {
            if hasSeenOnboarding {
                NetworkView()
                    .environmentObject(languageManager)
            } else {
                OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
                    .environmentObject(languageManager)
            }
        }
    }
}

// MARK: - Fox Mascot View
enum FoxMascotState {
    case idle
    case connecting
    case connected
    case speedReady
    case tracing
    case traceDone
}

struct FoxMascotView: View {
    let state: FoxMascotState

    private var imageName: String {
        switch state {
        case .idle: return "pawprint.fill"
        case .connecting: return "pawprint.circle"
        case .connected: return "pawprint.circle.fill"
        case .speedReady: return "pawprint.fill"
        case .tracing: return "pawprint.fill"
        case .traceDone: return "pawprint.circle.fill"
        }
    }

    var body: some View {
        Image(systemName: imageName)
            .font(.system(size: 56))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

struct NetworkView: View {
    @EnvironmentObject private var languageManager: LanguageManager

    @State private var isLoading = false
    @State private var statusMessage = ""
    @State private var isConnected = false
    @State private var showingCredentialAlert = false

    /// When true, current connection is via VLESS tunnel; when false, via IPSec (or disconnected).
    @State private var connectedViaVless = false

    @State private var showingSettings = false

    // Supabase VPN servers
    @State private var vpnServers: [VPNServer] = []
    @State private var selectedServer: VPNServer? = nil
    @State private var isLoadingServers = false
    @State private var serverLatencies: [String: Double] = [:]

    // Tab navigation
    @State private var selectedTab: AppTab = .vpn
    @State private var showingVPNSheet = false
    @State private var showingTracerouteScreen = false
    @State private var tracerouteDestination: String = ""

    // RevenueCat
    @StateObject private var revenueCatManager = RevenueCatManager.shared
    @State private var showingPaywall = false

    // Appearance
    @AppStorage("appTheme") private var appTheme: String = "dark"

    // Language picker
    @State private var showingLanguagePicker = false

    // Network Security Services
    @StateObject private var pingService = PingService()
    @StateObject private var tracerouteService = TracerouteService()
    @StateObject private var speedTestService = SpeedTestService()
    
    // MARK: - VPN Configuration
    private let defaultServerAddress = "69.197.134.25"
    private let defaultUsername = "XXX"       // Use the correct VPN server credentials
    private let defaultPassword = "XXX"     // Use the correct VPN server credentials
    private let defaultSharedSecret = "ipsec-vpn-key"
    
    // VPN server ports
    private let vpnServerPort = 500  // IPSec IKE port
    private let vpnServerPort2 = 4500  // IPSec NAT-T port
    
    // Constants for Keychain identifiers
    private let kKeychainVPNUsernameKey = "com.foxywall.username"
    private let kKeychainVPNPasswordKey = "com.foxywall.password"
    private let kKeychainVPNSharedSecretKey = "com.foxywall.sharedsecret"
    private let kKeychainVPNServerAddressKey = "com.foxywall.serveraddress"
    
    private var backgroundColor: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    
    
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab(L10n.vpnTabTitle, systemImage: "shield.fill", value: .vpn) {
                vpnTabContent
            }

            Tab(L10n.serversTabTitle, systemImage: "server.rack", value: .servers) {
                serversTabContent
            }

            Tab(L10n.profileTitle, systemImage: "person.fill", value: .profile) {
                settingsTabContent2
            }
        }
        .preferredColorScheme(appTheme == "light" ? .light : .dark)
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showingPaywall) {
            PaywallView {
                setupAndConnectVPN()
            }
        }
        .fullScreenCover(isPresented: $showingVPNSheet) {
            vpnScreenContent
        }
        .fullScreenCover(isPresented: $showingTracerouteScreen) {
            NavigationStack {
                tracerouteBody
                    .navigationTitle(L10n.smartRouteTitle)
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.done) {
                                showingTracerouteScreen = false
                            }
                        }
                    }
            }
        }
        .onAppear {
            revenueCatManager.configure()
            AppsFlyerManager.shared.configure()
            checkVPNStatus()
            fetchVPNServers()
        }
    }
    
    // MARK: - Tab Content Views

    /// Speed tab: Speedtest-style gauge with download/upload/ping/jitter.
    private var speedTestTabContent: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Download / Upload header
                    HStack(spacing: 0) {
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.cyan)
                                    .font(.caption)
                                Text(L10n.downloadMbps)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                            }
                            Text(speedTestService.currentResult != nil
                                 ? String(format: "%.2f", speedTestService.currentResult!.downloadSpeedMbps)
                                 : "—")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity)

                        Divider().frame(height: 40)

                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundColor(.cyan)
                                    .font(.caption)
                                Text(L10n.uploadMbps)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                            }
                            Text(speedTestService.currentResult != nil
                                 ? String(format: "%.2f", speedTestService.currentResult!.uploadSpeedMbps)
                                 : "—")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)

                    // Ping & Jitter row
                    HStack(spacing: 24) {
                        HStack(spacing: 6) {
                            Text(L10n.ping)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(L10n.ms)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(speedTestService.currentResult != nil
                                 ? String(format: "%.0f", speedTestService.currentResult!.pingMs)
                                 : "—")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.yellow)
                        }

                        HStack(spacing: 6) {
                            Text(L10n.jitter)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(L10n.ms)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(speedTestService.currentResult != nil
                                 ? String(format: "%.0f", speedTestService.currentResult!.jitterMs)
                                 : "—")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.yellow)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                    // Gauge (tappable — starts/restarts test)
                    Button(action: {
                        if !speedTestService.isRunning {
                            speedTestService.runSpeedTest()
                        }
                    }) {
                        SpeedtestGaugeView(
                            currentSpeed: speedTestService.isRunning
                                ? speedTestService.currentSpeed
                                : (speedTestService.currentResult?.downloadSpeedMbps ?? 0),
                            isRunning: speedTestService.isRunning,
                            hasResult: speedTestService.currentResult != nil,
                            phase: speedTestService.currentPhase,
                            speedText: speedTestService.isRunning
                                ? String(format: "%.2f", speedTestService.currentSpeed)
                                : (speedTestService.currentResult != nil
                                    ? String(format: "%.2f", speedTestService.currentResult!.downloadSpeedMbps)
                                    : nil)
                        )
                        .frame(height: 260)
                    }
                    .buttonStyle(.plain)
                    .disabled(speedTestService.isRunning)
                    .padding(.top, 30)
                    .padding(.horizontal, 40)

                    if isConnected && !speedTestService.isRunning {
                        Text(L10n.vpnActiveSpeedNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 12)
                    }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(L10n.speedTabTitle)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Firewall Screen Content
    private var vpnScreenContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // Firewall Status Card
                VStack(spacing: 24) {
                    // Large shield icon
                    ZStack {
                        Circle()
                            .fill(isConnected ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                            .frame(width: 140, height: 140)

                        Image(systemName: isConnected ? "flame.fill" : "flame")
                            .font(.system(size: 70))
                            .foregroundColor(isConnected ? .green : .gray)
                    }

                    Text(isConnected ? L10n.protected : L10n.notProtected)
                        .font(.title)
                        .fontWeight(.bold)

                    Text(L10n.encrypt)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()

                // Bottom section
                VStack(spacing: 16) {
                    // Connect/Disconnect Button
                    Button(action: {
                        if isConnected {
                            disconnectVPN()
                        } else {
                            setupAndConnectVPN()
                        }
                    }) {
                        HStack(spacing: 12) {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: isConnected ? "power" : "bolt.shield.fill")
                            }
                            Text(isLoading ? L10n.connecting : (isConnected ? L10n.disconnect : L10n.connect))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            LinearGradient(
                                colors: isConnected ? [.red, .red.opacity(0.8)] : [.green, .green.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(isLoading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingVPNSheet = false }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text(L10n.back)
                        }
                    }
                }
            }
        }
    }

    private func getLocalIPAddress() -> String {
        var address: String = "Unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr?.pointee
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: (interface?.ifa_name)!)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    private func scoreGradientColors(score: Int) -> [Color] {
        if score >= 80 {
            return [.green, .green.opacity(0.7)]
        } else if score >= 60 {
            return [.yellow, .yellow.opacity(0.7)]
        } else if score >= 40 {
            return [.orange, .orange.opacity(0.7)]
        } else {
            return [.red, .red.opacity(0.7)]
        }
    }
    
    private func scoreDescription(score: Int) -> String {
        if score >= 80 {
            return "Excellent - Your network is well secured"
        } else if score >= 60 {
            return "Good - Minor security improvements recommended"
        } else if score >= 40 {
            return "Fair - Several security issues detected"
        } else {
            return "Poor - Immediate action required"
        }
    }
    
    private func findingCard(finding: SecurityFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: finding.category.icon)
                    .foregroundColor(severityColor(finding.severity))
                
                Text(finding.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text(finding.severity.label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(severityColor(finding.severity).opacity(0.2))
                    .foregroundColor(severityColor(finding.severity))
                    .cornerRadius(8)
            }
            
            Text(finding.description)
                .font(.caption)
                .foregroundColor(.primary)
            
            Text("💡 \(finding.recommendation)")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        }
        .glassCard()
        .padding(.horizontal, 20)
    }
    
    private func severityColor(_ severity: SecurityFinding.Severity) -> Color {
        switch severity {
        case .safe: return .green
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
    
    // VPN Tab — Foxy Wall main screen
    private var vpnTabContent: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Big glowing connect button
                    Button(action: {
                        if isConnected { disconnectVPN() } else { setupAndConnectVPN() }
                    }) {
                        ZStack {
                            // Outermost glow ring
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: isConnected
                                            ? [Color.green.opacity(0.15), Color.green.opacity(0.0)]
                                            : [Color.gray.opacity(0.10), Color.gray.opacity(0.0)],
                                        center: .center,
                                        startRadius: 80,
                                        endRadius: 150
                                    )
                                )
                                .frame(width: 300, height: 300)

                            // Middle ring
                            Circle()
                                .fill(
                                    isConnected
                                        ? Color.green.opacity(0.18)
                                        : Color.gray.opacity(0.12)
                                )
                                .frame(width: 220, height: 220)

                            // Stroke ring
                            Circle()
                                .stroke(
                                    isConnected ? Color.green : Color.gray.opacity(0.4),
                                    lineWidth: 3
                                )
                                .frame(width: 200, height: 200)

                            // Inner filled circle
                            Circle()
                                .fill(
                                    isConnected
                                        ? Color.green.opacity(0.35)
                                        : Color.gray.opacity(0.15)
                                )
                                .frame(width: 145, height: 145)

                            // Shield / loading icon
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .tint(isConnected ? .green : .gray)
                            } else {
                                Image(systemName: isConnected ? "checkmark.shield.fill" : "shield.fill")
                                    .font(.system(size: 52))
                                    .foregroundColor(isConnected ? .white : Color.gray.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .padding(.top, 8)

                    // Status text (removed per design)

                    // Server card
                    Button(action: { selectedTab = .servers }) {
                        HStack(spacing: 14) {
                            if let server = selectedServer {
                                Text(server.flag)
                                    .font(.system(size: 32))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                            } else {
                                Image(systemName: "globe")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text(L10n.selectServer)
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Ping indicator
                            if isConnected {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                    Text("20 ms")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                }
                            }

                            // Arrow button
                            Button(action: { selectedTab = .servers }) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color(red: 0.2, green: 0.6, blue: 0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    // Map + Smart Route row
                    HStack(spacing: 12) {
                        // Map card (tapping opens traceroute / Smart Route)
                        Button(action: { showingTracerouteScreen = true }) {
                            ZStack(alignment: .bottomLeading) {
                                TracerouteMapView(hops: tracerouteService.hops)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))

                                // Expand icon
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.black.opacity(0.4))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                                // Location badge
                                if let server = selectedServer {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 7, height: 7)
                                        Text("\(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(10)
                                    .padding(8)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        // Speed Test box (replaces Smart Route)
                        Button(action: {
                            if !speedTestService.isRunning {
                                speedTestService.runSpeedTest()
                            }
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "speedometer")
                                    .font(.system(size: 28))
                                    .foregroundColor(speedTestService.currentResult != nil ? .cyan : Color.gray.opacity(0.5))

                                Text(L10n.speedTestTitle)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)

                                if speedTestService.isRunning {
                                    Text(speedTestService.currentPhase.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else if let result = speedTestService.currentResult {
                                    Text(String(format: "↓%.1f ↑%.1f", result.downloadSpeedMbps, result.uploadSpeedMbps))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(L10n.speedTapToMeasure)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 130)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                        .disabled(speedTestService.isRunning)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .padding(.top, 8)
            }
            .background(
                isConnected ? Color.green.opacity(0.04) : Color(.systemBackground)
            )
            .navigationTitle(L10n.vpnTabTitle)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Servers Tab
    private var serversTabContent: some View {
        NavigationStack {
            Group {
                if isLoadingServers {
                    ProgressView(L10n.loadingServers)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vpnServers.isEmpty {
                    VStack(spacing: 12) {
                        Text(L10n.noServersAvailable)
                            .font(.headline)
                        Button(L10n.refresh) {
                            fetchVPNServers()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(vpnServers) { server in
                                SupabaseServerRow(
                                    server: server,
                                    isSelected: selectedServer?.id == server.id,
                                    pingMs: serverLatencies[server.id]
                                ) {
                                    selectedServer = server
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .refreshable {
                        fetchVPNServers()
                    }
                    .onAppear {
                        startServerPings()
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(L10n.serversTabTitle)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Traceroute body (Smart Route – shown when map is tapped)
    private var tracerouteBody: some View {
        VStack(spacing: 0) {
            // Full-width map at top
            ZStack(alignment: .bottomLeading) {
                TracerouteMapView(hops: tracerouteService.hops)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)

                // Location badge overlay
                if let server = selectedServer, tracerouteService.hops.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("\(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))")
                            .font(.caption2).fontWeight(.semibold).foregroundColor(.white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.5)).cornerRadius(10)
                    .padding(12)
                }
            }

            // Search + controls
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // Search bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Enter IP or domain", text: $tracerouteDestination)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit {
                                if !tracerouteService.isRunning && !tracerouteDestination.isEmpty {
                                    tracerouteService.traceroute(to: tracerouteDestination)
                                }
                            }
                        if tracerouteService.isRunning {
                            ProgressView()
                        } else if !tracerouteDestination.isEmpty {
                            Button(action: {
                                tracerouteService.traceroute(to: tracerouteDestination)
                            }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(Color(red: 0.2, green: 0.6, blue: 0.9))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                    // Trace to current VPN server shortcut
                    if let server = selectedServer {
                        Button(action: {
                            tracerouteDestination = server.serverAddress
                            tracerouteService.traceroute(
                                to: server.serverAddress,
                                targetCoordinate: server.coordinate
                            )
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                    .foregroundColor(Color(red: 0.2, green: 0.6, blue: 0.9))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.traceToServer)
                                        .font(.subheadline).fontWeight(.medium).foregroundColor(.primary)
                                    Text("\(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode)) · \(server.serverAddress)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }

                    // Empty state
                    if tracerouteService.hops.isEmpty && !tracerouteService.isRunning {
                        VStack(spacing: 10) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.4))
                            Text(L10n.enterIpOrDomain)
                                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        .padding(.top, 16).padding(.horizontal, 40)
                    } else {
                        // Hop list
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracerouteService.hops.enumerated()), id: \.element.id) { index, hop in
                                HStack(spacing: 12) {
                                    if let flag = hop.flagEmoji { Text(flag).font(.title3) }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hop.host).font(.subheadline).fontWeight(.medium).foregroundColor(.primary)
                                        if let ip = hop.ip { Text(ip).font(.caption).foregroundColor(.secondary) }
                                    }
                                    Spacer()
                                    if let latency = hop.latencyMs {
                                        Text(String(format: "%.0f ms", latency))
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundColor(latency < 50 ? .green : (latency < 100 ? .orange : .red))
                                    } else if hop.status == .timeout {
                                        Text("* * *").font(.caption).foregroundColor(.orange)
                                    }
                                }
                                .padding(.vertical, 12).padding(.horizontal, 16)
                                .accessibilityElement(children: .combine)

                                if index < tracerouteService.hops.count - 1 {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                    }

                    Spacer().frame(height: 20)
                }
                .padding(.top, 14)
            }
        }
        .background(Color(.systemBackground))
    }

    // Activate VPN with traceroute animation
    private func activateVPNWithTraceroute() {
        if isConnected {
            // Disconnect VPN
            disconnectVPN()
            return
        }

        guard let server = selectedServer else {
            statusMessage = L10n.statusSelectServerFirst
            return
        }

        // Run traceroute to server address first (this shows the animation)
        tracerouteService.traceroute(to: server.serverAddress, targetCoordinate: server.coordinate)

        // Connect VPN after traceroute completes
        Task {
            // Wait for traceroute to finish
            while tracerouteService.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }

            // Now connect VPN
            await MainActor.run {
                setupAndConnectVPN()
            }
        }
    }

    // Speed Tab - Speed Test + Ping
    // This content has been merged into scannerTabContent
    
    private var pingToolView: some View {
        VStack(spacing: 0) {
            if !pingService.results.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pingService.results) { result in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.host)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                if let ip = result.ip {
                                    Text(ip)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            if let latency = result.latencyMs {
                                Text(String(format: "%.0f ms", latency))
                                    .font(.headline)
                                    .foregroundColor(.green)
                            } else {
                                Text(result.status.description)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .glassCard()
                        .padding(.horizontal, 20)
                    }
                }
            }
            
            Spacer().frame(height: 20)
            
            Button(action: {
                if pingService.isRunning {
                    pingService.stopPing()
                } else {
                    pingService.pingMultipleHosts(hosts: PingService.commonHosts)
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: pingService.isRunning ? "stop.fill" : "play.fill")
                    Text(pingService.isRunning ? "Stop" : "Start Ping Test")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(.secondarySystemFill))
                .foregroundColor(.primary)
                .cornerRadius(16)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
    
    private var tracerouteToolView: some View {
        VStack(spacing: 10) {
            if !tracerouteService.hops.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(tracerouteService.hops) { hop in
                        HStack {
                            if let flag = hop.flagEmoji {
                                Text(flag)
                                    .font(.title3)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(hop.host)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                if let ip = hop.ip {
                                    Text(ip)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if let latency = hop.latencyMs {
                                Text(String(format: "%.0f ms", latency))
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                Text("*")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .glassCard()
                        .padding(.horizontal, 20)
                    }
                }
            }
            
            Spacer().frame(height: 20)
            

        }
    }
    
    private var speedTestToolView: some View {
        VStack(spacing: 10) {
            if speedTestService.isRunning {
                VStack(spacing: 8) {
                    ProgressView(value: speedTestService.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .white))
                    Text(speedTestService.currentPhase.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
            }
            
            if let result = speedTestService.currentResult {
                VStack(spacing: 20) {
                    HStack(spacing: 30) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.green)
                            Text(String(format: "%.1f", result.downloadSpeedMbps))
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.primary)
                            Text(L10n.mbpsDownload)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.blue)
                            Text(String(format: "%.1f", result.uploadSpeedMbps))
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.primary)
                            Text(L10n.mbpsUpload)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .glassCard()
                .padding(.horizontal, 20)
            }
        }
    }
    // Protect Tab - Simplified VPN + Security Features
    private var protectTabContent: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        // VPN Protection
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .font(.title2)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.vpnProtection)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(isConnected ? L10n.connected : L10n.disconnected)
                                .font(.caption)
                                .foregroundColor(isConnected ? .green : .secondary)
                        }
                        
                        Spacer()
                    }
                    
                    if let server = selectedServer {
                        HStack(spacing: 12) {
                            Text(server.flag).font(.system(size: 24))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                    if server.hasVlessConfig {
                                        Text(L10n.vless)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.cyan)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.cyan.opacity(0.2))
                                            .cornerRadius(4)
                                    }
                                }
                                Text(L10n.autoSelected)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    
                    Button(action: isConnected ? disconnectVPN : setupAndConnectVPN) {
                        HStack(spacing: 12) {
                            Image(systemName: "power")
                            Text(isConnected ? L10n.disconnectVpn : L10n.connectVpn)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: isConnected ? [Color.red, Color.red.opacity(0.8)] : [Color.green, Color.green.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    .disabled(isLoading)
                }
                .glassCard()
                .padding(.horizontal, 20)
                

                        Spacer()
                    }
                    .frame(minHeight: geometry.size.height)
                    .frame(width: geometry.size.width)
                }
            }
            .navigationTitle(L10n.protectionTabTitle)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var settingsTabContent2: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Subscriptions
                    Button(action: {
                        showingPaywall = true
                    }) {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.subscriptions)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(L10n.manageSubscription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Redeem Offer Code
                    Button(action: {
                        Purchases.shared.presentCodeRedemptionSheet()
                        Task {
                            await revenueCatManager.checkSubscriptionStatus()
                        }
                    }) {
                        HStack {
                            Image(systemName: "gift.fill")
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.redeemCode)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(L10n.enterPromoCode)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Theme Switcher
                    HStack(spacing: 12) {
                        Image(systemName: "paintbrush.fill")
                            .foregroundColor(.purple)
                        Text(L10n.appearance)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Picker("Theme", selection: $appTheme) {
                            Text(L10n.light).tag("light")
                            Text(L10n.dark).tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                    .padding(16)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)

                    // Language Picker
                    Button(action: { showingLanguagePicker = true }) {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.settingsLanguage)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(LanguageManager.supportedLanguages.first { $0.code == languageManager.currentLanguageCode }?.nativeName ?? "English")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .sheet(isPresented: $showingLanguagePicker) {
                        NavigationStack {
                            List(LanguageManager.supportedLanguages, id: \.code) { lang in
                                Button(action: {
                                    languageManager.currentLanguageCode = lang.code
                                    showingLanguagePicker = false
                                }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(lang.nativeName)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                            Text(lang.name)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if languageManager.currentLanguageCode == lang.code {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                }
                            }
                            .navigationTitle(L10n.settingsLanguage)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showingLanguagePicker = false }
                                }
                            }
                        }
                    }

                    // Privacy Policy
                    Button(action: {
                        if let url = URL(string: "https://www.holylabs.net/privacy") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.green)
                            Text(L10n.privacyPolicy)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Terms of Use
                    Button(action: {
                        if let url = URL(string: "https://www.holylabs.net/terms") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.orange)
                            Text(L10n.termsOfUse)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                    }
                    // App Info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.appName)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(L10n.appNameValue)
                                .foregroundColor(.primary)
                        }
                        Divider()
                        HStack {
                            Text(L10n.version)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(L10n.versionValue)
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(16)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .navigationTitle(L10n.profileTitle)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func saveDefaultCredentials() {
        // Clear existing credentials first
        clearVPNCredentials()
        
        // Store the default credentials in the Keychain
        let usernameSaved = saveToKeychain(key: kKeychainVPNUsernameKey, data: defaultUsername.data(using: .utf8)!)
        let passwordSaved = saveToKeychain(key: kKeychainVPNPasswordKey, data: defaultPassword.data(using: .utf8)!)
        let sharedSecretSaved = saveToKeychain(key: kKeychainVPNSharedSecretKey, data: defaultSharedSecret.data(using: .utf8)!)
        let serverAddressSaved = saveToKeychain(key: kKeychainVPNServerAddressKey, data: defaultServerAddress.data(using: .utf8)!)
        
        statusMessage = "VPN credentials configured"
    }
    
    private func clearVPNCredentials() {
        // Clear all VPN-related keychain items
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: kKeychainVPNUsernameKey
        ] as CFDictionary)
        
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: kKeychainVPNPasswordKey
        ] as CFDictionary)
        
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: kKeychainVPNSharedSecretKey
        ] as CFDictionary)
        
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: kKeychainVPNServerAddressKey
        ] as CFDictionary)
        

    }
    
    private func checkVPNStatus() {
        // Prefer VLESS tunnel status (same as dopplerswift); fallback to IPSec.
        let vlessStatus = VlessTunnelManager.shared.currentStatus
        if vlessStatus == .connected {
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectedViaVless = true
                self.isLoading = false
                self.statusMessage = ""
            }
            VlessTunnelManager.shared.observeStatus { status in
                DispatchQueue.main.async {
                    switch status {
                    case .connected:
                        self.isConnected = true
                        self.connectedViaVless = true
                        self.isLoading = false
                        self.statusMessage = ""
                    case .connecting, .reasserting:
                        self.isLoading = true
                    case .disconnecting:
                        self.isLoading = true
                    case .disconnected, .invalid:
                        self.isConnected = false
                        self.connectedViaVless = false
                        self.isLoading = false
                        self.statusMessage = ""
                    @unknown default:
                        self.isConnected = false
                        self.connectedViaVless = false
                        self.isLoading = false
                        self.statusMessage = ""
                    }
                }
            }
            return
        }

        connectedViaVless = false
        let vpnManager = NEVPNManager.shared()
        vpnManager.loadFromPreferences { error in
            if let error = error {
                DispatchQueue.main.async {
                    if error.localizedDescription.contains("IPC failed") ||
                       error.localizedDescription.contains("Connection invalid") {
                        self.statusMessage = L10n.statusVpnSimulator
                    } else {
                        self.statusMessage = "Error checking VPN status: \(error.localizedDescription)"
                    }
                }
                return
            }

            DispatchQueue.main.async {
                switch vpnManager.connection.status {
                case .connected:
                    self.isConnected = true
                    self.isLoading = false
                    self.statusMessage = ""
                case .connecting:
                    self.isLoading = true
                    self.statusMessage = ""
                case .disconnecting:
                    self.isLoading = true
                    self.statusMessage = ""
                case .disconnected, .invalid:
                    self.isConnected = false
                    self.isLoading = false
                    self.statusMessage = ""
                @unknown default:
                    self.isConnected = false
                    self.isLoading = false
                    self.statusMessage = ""
                }
            }

            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: vpnManager.connection,
                queue: OperationQueue.main) { _ in
                    DispatchQueue.main.async {
                        switch vpnManager.connection.status {
                        case .connected:
                            self.isConnected = true
                            self.isLoading = false
                            self.statusMessage = ""
                        case .connecting:
                            self.isLoading = true
                            self.statusMessage = ""
                        case .disconnecting:
                            self.isLoading = true
                            self.statusMessage = ""
                        case .disconnected, .invalid:
                            self.isConnected = false
                            self.isLoading = false
                            self.statusMessage = ""
                        @unknown default:
                            self.isConnected = false
                            self.isLoading = false
                            self.statusMessage = ""
                        }
                    }
            }
        }
    }
    
    private func setupAndConnectVPN() {
        // Check subscription status before connecting
        if !revenueCatManager.isSubscribed {
            // Show paywall if not subscribed
            showingPaywall = true
            return
        }

        connectVPNAfterConsent()
    }

    private func connectVPNAfterConsent() {
        // Check subscription status before connecting
        if !revenueCatManager.isSubscribed {
            showingPaywall = true
            return
        }

        // Check if running in simulator
        #if targetEnvironment(simulator)
        statusMessage = L10n.statusVpnSimulator
        return
        #endif

        guard let server = selectedServer else {
            statusMessage = L10n.statusSelectServerFirst
            return
        }

        // Prefer VLESS when available (same technology as dopplerswift / Reality-first).
        if server.hasVlessConfig, let vlessUrl = server.resolvedVlessUrl {
            connectViaVless(vlessUrl: vlessUrl, server: server)
            return
        }

        // Fallback: IPSec with OpenVPN-style credentials
        guard let username = server.openvpnUsername,
              let password = server.openvpnPassword else {
            statusMessage = L10n.statusServerCredentialsNotAvailable
            return
        }

        connectViaIPSec(server: server, username: username, password: password)
    }

    private func connectViaVless(vlessUrl: String, server: VPNServer) {
        connectedViaVless = true
        isLoading = true
        statusMessage = L10n.statusConnecting(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))

        VlessTunnelManager.shared.observeStatus { [self] status in
            DispatchQueue.main.async {
                switch status {
                case .connected:
                    self.isConnected = true
                    self.isLoading = false
                    self.statusMessage = ""
                case .connecting, .reasserting:
                    self.isLoading = true
                    self.statusMessage = L10n.statusConnecting(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))
                case .disconnecting:
                    self.isLoading = true
                case .disconnected, .invalid:
                    self.isConnected = false
                    self.isLoading = false
                    self.connectedViaVless = false
                    self.statusMessage = ""
                @unknown default:
                    self.isConnected = false
                    self.isLoading = false
                    self.connectedViaVless = false
                    self.statusMessage = ""
                }
            }
        }

        VlessTunnelManager.shared.connect(vlessUrl: vlessUrl) { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.isLoading = false
                    self.connectedViaVless = false
                    self.statusMessage = "VLESS: \(error.localizedDescription)"
                }
            }
        }
    }

    private func connectViaIPSec(server: VPNServer, username: String, password: String) {
        connectedViaVless = false
        isLoading = true
        statusMessage = L10n.statusConnecting(server.localizedCityName(preferredLocale: languageManager.currentLanguageCode))

        let serverAddress = server.serverAddress

        guard let sharedSecretData = loadFromKeychain(key: kKeychainVPNSharedSecretKey),
              let sharedSecret = String(data: sharedSecretData, encoding: .utf8) else {
            statusMessage = "Error: Missing shared secret"
            isLoading = false
            saveDefaultCredentials()
            return
        }

        let vpnManager = NEVPNManager.shared()
        vpnManager.loadFromPreferences { error in
            if let error = error {
                DispatchQueue.main.async {
                    self.statusMessage = "Error loading VPN preferences: \(error.localizedDescription)"
                    self.isLoading = false
                }
                return
            }

            let ipSecConfig = NEVPNProtocolIPSec()
            ipSecConfig.serverAddress = serverAddress
            ipSecConfig.username = username

            if let passwordRef = self.createPasswordReference(username: username, password: password) {
                ipSecConfig.passwordReference = passwordRef
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Error creating password reference"
                    self.isLoading = false
                }
                return
            }

            ipSecConfig.authenticationMethod = .sharedSecret
            if let sharedSecretRef = self.createSharedSecretReference(secret: sharedSecret) {
                ipSecConfig.sharedSecretReference = sharedSecretRef
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Error creating shared secret reference"
                    self.isLoading = false
                }
                return
            }

            ipSecConfig.localIdentifier = ""
            ipSecConfig.remoteIdentifier = serverAddress
            ipSecConfig.useExtendedAuthentication = true

            vpnManager.protocolConfiguration = ipSecConfig
            vpnManager.isEnabled = true
            vpnManager.localizedDescription = "FoxyWall"

            vpnManager.saveToPreferences { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.statusMessage = "Error saving VPN preferences: \(error.localizedDescription)"
                        self.isLoading = false
                    }
                    return
                }

                do {
                    try vpnManager.connection.startVPNTunnel()
                } catch let error {
                    DispatchQueue.main.async {
                        self.statusMessage = "Failed to start VPN: \(error.localizedDescription)"
                        self.isLoading = false
                    }
                }
            }
        }
    }
    
    private func createPasswordReference(username: String, password: String) -> Data? {
        let passwordData = password.data(using: .utf8)!
        
        // Create a keychain query
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VPNService",
            kSecAttrAccount as String: username,
            kSecValueData as String: passwordData,
            kSecReturnPersistentRef as String: true
        ]
        
        // Remove any existing keychain item
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VPNService",
            kSecAttrAccount as String: username
        ] as CFDictionary)
        
        // Add the new keychain item
        var result: CFTypeRef?
        let status = SecItemAdd(keychainQuery as CFDictionary, &result)
        
        if status == errSecSuccess {
            return result as? Data
        } else {

            return nil
        }
    }
    
    private func createSharedSecretReference(secret: String) -> Data? {
        let secretData = secret.data(using: .utf8)!
        
        // Create a keychain query
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VPNSharedSecret",
            kSecAttrAccount as String: "SharedSecret",
            kSecValueData as String: secretData,
            kSecReturnPersistentRef as String: true
        ]
        
        // Remove any existing keychain item
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VPNSharedSecret",
            kSecAttrAccount as String: "SharedSecret"
        ] as CFDictionary)
        
        // Add the new keychain item
        var result: CFTypeRef?
        let status = SecItemAdd(keychainQuery as CFDictionary, &result)
        
        if status == errSecSuccess {
            return result as? Data
        } else {

            return nil
        }
    }
    
    private func disconnectVPN() {
        // Check if running in simulator
        #if targetEnvironment(simulator)
        statusMessage = L10n.statusVpnSimulator
        return
        #endif

        isLoading = true
        statusMessage = ""

        if connectedViaVless {
            VlessTunnelManager.shared.disconnect()
            connectedViaVless = false
            isConnected = false
            isLoading = false
            statusMessage = ""
        } else {
            NEVPNManager.shared().connection.stopVPNTunnel()
        }
    }
    
    // MARK: - Keychain Helper Functions
    
    private func saveToKeychain(key: String, data: Data) -> Bool {
        // First delete any existing item
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ] as CFDictionary)
        
        // Now add the new item
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ] as CFDictionary, nil)
        
        return status == errSecSuccess
    }
    
    private func loadFromKeychain(key: String) -> Data? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &result)
        
        if status == errSecSuccess {
            return result as? Data
        } else {

            return nil
        }
    }
    

    
    private func fetchVPNServers() {
        isLoadingServers = true
        
        SupabaseConfig.shared.fetchVPNServers { [self] result in
            DispatchQueue.main.async {
                self.isLoadingServers = false
                
                switch result {
                case .success(let servers):
                    // Sort servers: Free servers always on top!
                    var sortedServers = servers.sorted { server1, server2 in
                        // If one is free and other is premium, free comes first
                        if !server1.isPremium && server2.isPremium {
                            return true
                        }
                        if server1.isPremium && !server2.isPremium {
                            return false
                        }
                        // Otherwise sort by name
                        return server1.name < server2.name
                    }
                    
                    self.vpnServers = sortedServers
                    self.serverLatencies.removeAll()
                    self.startServerPings()

                    // Set Stockholm (free server) as default if none selected
                    // The user specifically wants Sweden preselected
                    if self.selectedServer == nil {
                        // Priority 1: Stockholm/Sweden Free Server
                        if let stockholmServer = sortedServers.first(where: { 
                            ($0.id == "stockholm1" || $0.name.lowercased().contains("sweden") || $0.name.lowercased().contains("stockholm")) && !$0.isPremium 
                        }) {
                            self.selectedServer = stockholmServer
                        } 
                        // Priority 2: Any Free Server (since they are sorted on top, just take first)
                        else if let firstFreeServer = sortedServers.first(where: { !$0.isPremium }) {
                            self.selectedServer = firstFreeServer
                        } 
                        // Priority 3: First available
                        else if let firstServer = sortedServers.first {
                            self.selectedServer = firstServer
                        }
                    }
                    
                    self.statusMessage = L10n.statusLoadedServers(servers.count)
                    
                case .failure(let error):
                    self.statusMessage = String(format: L10n.statusFailedLoadServers, error.localizedDescription)
                    // Fallback to default server if Supabase fails
                }
            }
        }
    }
    
    /// Pre-fills all servers with a default good latency so bars show immediately.
    private func startServerPings() {
        guard !vpnServers.isEmpty else { return }
        for server in vpnServers {
            if serverLatencies[server.id] == nil {
                serverLatencies[server.id] = 50
            }
        }
    }
    

}



// MARK: - Settings View
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingEULA = false
    
    public init() {}
    
    private var backgroundColor: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    
    public var body: some View {
        #if os(iOS)
        NavigationView {
            mainSettingsContent
        }
        #else
        // macOS: Use full-screen layout without NavigationView
        VStack {
            // Custom header for macOS
            HStack {
                Text(L10n.settingsTabTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(backgroundColor)
            
            mainSettingsContent
                .padding()
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 600)
        #endif
    }
    
    private var mainSettingsContent: some View {
        List {

            
            Section("Device Info") {
                HStack {
                    Text(L10n.localIpAddress)
                    Spacer()
                    Text(getLocalIPAddress())
                        .foregroundColor(.gray)
                }
            }
            
            Section("Privacy") {
                Link("Privacy Policy", destination: URL(string: "https://theholylabs.com/privacy")!)
                    .foregroundColor(.blue)
            }
            
            Section("Legal") {
                Button("End User License Agreement") {
                    showingEULA = true
                }
                .foregroundColor(.primary)
            }
            
            Section("About") {
                HStack {
                    Text(L10n.version)
                    Spacer()
                    Text(L10n.versionValue)
                        .foregroundColor(.gray)
                }
                
                HStack {
                    Text(L10n.appName)
                    Spacer()
                    Text(L10n.appNameValue)
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle(L10n.settingsTabTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Button("Done") {
                    dismiss()
                }
            }
            #endif
        }
        .sheet(isPresented: $showingEULA) {
            EULAView()
        }
    }
    
    private func getLocalIPAddress() -> String {
        var address: String = "Unknown"
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return address
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            let interface = ptr?.pointee
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: (interface?.ifa_name)!)
                
                #if os(iOS)
                // iOS network interfaces
                if name == "en0" || name == "en1" || name == "en2" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr,
                               socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                               &hostname,
                               socklen_t(hostname.count),
                               nil,
                               0,
                               NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
                #else
                // macOS network interfaces
                if name == "en0" || name == "en1" || name == "en2" || name == "en3" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr,
                               socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                               &hostname,
                               socklen_t(hostname.count),
                               nil,
                               0,
                               NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
                #endif
            }
        }
        
        return address
    }
}

// MARK: - EULA View
struct EULAView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(eulaText)
                        .font(.system(size: 14))
                        .padding()
                }
            }
            .navigationTitle(L10n.eulaTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #endif
            }
        }
    }
    
    private let eulaText = """
LICENSED APPLICATION END USER LICENSE AGREEMENT

Apps made available through the App Store are licensed, not sold, to you. Your license to each App is subject to your prior acceptance of either this Licensed Application End User License Agreement ("Standard EULA"), or a custom end user license agreement between you and the Application Provider ("Custom EULA"), if one is provided. Your license to any Apple App under this Standard EULA or Custom EULA is granted by Apple, and your license to any Third Party App under this Standard EULA or Custom EULA is granted by the Application Provider of that Third Party App. Any App that is subject to this Standard EULA is referred to herein as the "Licensed Application." The Application Provider or Apple as applicable ("Licensor") reserves all rights in and to the Licensed Application not expressly granted to you under this Standard EULA.

a. Scope of License: Licensor grants to you a nontransferable license to use the Licensed Application on any Apple-branded products that you own or control and as permitted by the Usage Rules. The terms of this Standard EULA will govern any content, materials, or services accessible from or purchased within the Licensed Application as well as upgrades provided by Licensor that replace or supplement the original Licensed Application, unless such upgrade is accompanied by a Custom EULA. Except as provided in the Usage Rules, you may not distribute or make the Licensed Application available over a network where it could be used by multiple devices at the same time. You may not transfer, redistribute or sublicense the Licensed Application and, if you sell your Apple Device to a third party, you must remove the Licensed Application from the Apple Device before doing so. You may not copy (except as permitted by this license and the Usage Rules), reverse-engineer, disassemble, attempt to derive the source code of, modify, or create derivative works of the Licensed Application, any updates, or any part thereof (except as and only to the extent that any foregoing restriction is prohibited by applicable law or to the extent as may be permitted by the licensing terms governing use of any open-sourced components included with the Licensed Application).

b. Consent to Use of Data: You agree that Licensor may collect and use technical data and related information—including but not limited to technical information about your device, system and application software, and peripherals—that is gathered periodically to facilitate the provision of software updates, product support, and other services to you (if any) related to the Licensed Application. Licensor may use this information, as long as it is in a form that does not personally identify you, to improve its products or to provide services or technologies to you.

c. Termination. This Standard EULA is effective until terminated by you or Licensor. Your rights under this Standard EULA will terminate automatically if you fail to comply with any of its terms.

d. External Services. The Licensed Application may enable access to Licensor's and/or third-party services and websites (collectively and individually, "External Services"). You agree to use the External Services at your sole risk. Licensor is not responsible for examining or evaluating the content or accuracy of any third-party External Services, and shall not be liable for any such third-party External Services. Data displayed by any Licensed Application or External Service, including but not limited to financial, medical and location information, is for general informational purposes only and is not guaranteed by Licensor or its agents. You will not use the External Services in any manner that is inconsistent with the terms of this Standard EULA or that infringes the intellectual property rights of Licensor or any third party. You agree not to use the External Services to harass, abuse, stalk, threaten or defame any person or entity, and that Licensor is not responsible for any such use. External Services may not be available in all languages or in your Home Country, and may not be appropriate or available for use in any particular location. To the extent you choose to use such External Services, you are solely responsible for compliance with any applicable laws. Licensor reserves the right to change, suspend, remove, disable or impose access restrictions or limits on any External Services at any time without notice or liability to you.

e. NO WARRANTY: YOU EXPRESSLY ACKNOWLEDGE AND AGREE THAT USE OF THE LICENSED APPLICATION IS AT YOUR SOLE RISK. TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, THE LICENSED APPLICATION AND ANY SERVICES PERFORMED OR PROVIDED BY THE LICENSED APPLICATION ARE PROVIDED "AS IS" AND "AS AVAILABLE," WITH ALL FAULTS AND WITHOUT WARRANTY OF ANY KIND, AND LICENSOR HEREBY DISCLAIMS ALL WARRANTIES AND CONDITIONS WITH RESPECT TO THE LICENSED APPLICATION AND ANY SERVICES, EITHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES AND/OR CONDITIONS OF MERCHANTABILITY, OF SATISFACTORY QUALITY, OF FITNESS FOR A PARTICULAR PURPOSE, OF ACCURACY, OF QUIET ENJOYMENT, AND OF NONINFRINGEMENT OF THIRD-PARTY RIGHTS. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY LICENSOR OR ITS AUTHORIZED REPRESENTATIVE SHALL CREATE A WARRANTY. SHOULD THE LICENSED APPLICATION OR SERVICES PROVE DEFECTIVE, YOU ASSUME THE ENTIRE COST OF ALL NECESSARY SERVICING, REPAIR, OR CORRECTION. SOME JURISDICTIONS DO NOT ALLOW THE EXCLUSION OF IMPLIED WARRANTIES OR LIMITATIONS ON APPLICABLE STATUTORY RIGHTS OF A CONSUMER, SO THE ABOVE EXCLUSION AND LIMITATIONS MAY NOT APPLY TO YOU.

f. Limitation of Liability. TO THE EXTENT NOT PROHIBITED BY LAW, IN NO EVENT SHALL LICENSOR BE LIABLE FOR PERSONAL INJURY OR ANY INCIDENTAL, SPECIAL, INDIRECT, OR CONSEQUENTIAL DAMAGES WHATSOEVER, INCLUDING, WITHOUT LIMITATION, DAMAGES FOR LOSS OF PROFITS, LOSS OF DATA, BUSINESS INTERRUPTION, OR ANY OTHER COMMERCIAL DAMAGES OR LOSSES, ARISING OUT OF OR RELATED TO YOUR USE OF OR INABILITY TO USE THE LICENSED APPLICATION, HOWEVER CAUSED, REGARDLESS OF THE THEORY OF LIABILITY (CONTRACT, TORT, OR OTHERWISE) AND EVEN IF LICENSOR HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. SOME JURISDICTIONS DO NOT ALLOW THE LIMITATION OF LIABILITY FOR PERSONAL INJURY, OR OF INCIDENTAL OR CONSEQUENTIAL DAMAGES, SO THIS LIMITATION MAY NOT APPLY TO YOU. In no event shall Licensor's total liability to you for all damages (other than as may be required by applicable law in cases involving personal injury) exceed the amount of fifty dollars ($50.00). The foregoing limitations will apply even if the above stated remedy fails of its essential purpose.

g. You may not use or otherwise export or re-export the Licensed Application except as authorized by United States law and the laws of the jurisdiction in which the Licensed Application was obtained. In particular, but without limitation, the Licensed Application may not be exported or re-exported (a) into any U.S.-embargoed countries or (b) to anyone on the U.S. Treasury Department's Specially Designated Nationals List or the U.S. Department of Commerce Denied Persons List or Entity List. By using the Licensed Application, you represent and warrant that you are not located in any such country or on any such list. You also agree that you will not use these products for any purposes prohibited by United States law, including, without limitation, the development, design, manufacture, or production of nuclear, missile, or chemical or biological weapons.

h. The Licensed Application and related documentation are "Commercial Items", as that term is defined at 48 C.F.R. §2.101, consisting of "Commercial Computer Software" and "Commercial Computer Software Documentation", as such terms are used in 48 C.F.R. §12.212 or 48 C.F.R. §227.7202, as applicable. Consistent with 48 C.F.R. §12.212 or 48 C.F.R. §227.7202-1 through 227.7202-4, as applicable, the Commercial Computer Software and Commercial Computer Software Documentation are being licensed to U.S. Government end users (a) only as Commercial Items and (b) with only those rights as are granted to all other end users pursuant to the terms and conditions herein. Unpublished-rights reserved under the copyright laws of the United States.

i. Except to the extent expressly provided in the following paragraph, this Agreement and the relationship between you and Apple shall be governed by the laws of the State of California, excluding its conflicts of law provisions. You and Apple agree to submit to the personal and exclusive jurisdiction of the courts located within the county of Santa Clara, California, to resolve any dispute or claim arising from this Agreement. If (a) you are not a U.S. citizen; (b) you do not reside in the U.S.; (c) you are not accessing the Service from the U.S.; and (d) you are a citizen of one of the countries identified below, you hereby agree that any dispute or claim arising from this Agreement shall be governed by the applicable law set forth below, without regard to any conflict of law provisions, and you hereby irrevocably submit to the non-exclusive jurisdiction of the courts located in the state, province or country identified below whose law governs:

If you are a citizen of any European Union country or Switzerland, Norway or Iceland, the governing law and forum shall be the laws and courts of your usual place of residence.

Specifically excluded from application to this Agreement is that law known as the United Nations Convention on the International Sale of Goods.

Source: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
"""
}


// MARK: - Speedtest-style Gauge View
struct SpeedtestGaugeView: View {
    let currentSpeed: Double
    let isRunning: Bool
    var hasResult: Bool = false
    let phase: SpeedTestService.TestPhase
    var speedText: String? = nil

    private static let scaleMarks: [(value: Double, label: String)] = [
        (0, "0"), (1, "1"), (5, "5"), (10, "10"),
        (20, "20"), (30, "30"), (50, "50"), (75, "75"), (100, "100")
    ]

    static func logFraction(_ speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        let clamped = min(speed, 100)
        return log10(1 + clamped) / log10(101)
    }

    private var needleFraction: Double {
        Self.logFraction(currentSpeed)
    }

    private static let startAngle: Double = 135
    private static let endAngle: Double = 405
    private static let sweep: Double = endAngle - startAngle

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let arcRadius = size / 2 - 36
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                gaugeTrack(arcRadius: arcRadius, center: center)
                gaugeFill(arcRadius: arcRadius, center: center)
                scaleLabels(arcRadius: arcRadius, center: center)
                scaleTicks(arcRadius: arcRadius, center: center)
                centerContent(center: center)
            }
        }
    }

    private func gaugeTrack(arcRadius: CGFloat, center: CGPoint) -> some View {
        SpeedtestArcShape(startAngle: Self.startAngle, endAngle: Self.endAngle)
            .stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 22, lineCap: .round))
            .frame(width: arcRadius * 2, height: arcRadius * 2)
            .position(center)
    }

    private func gaugeFill(arcRadius: CGFloat, center: CGPoint) -> some View {
        SpeedtestArcShape(startAngle: Self.startAngle, endAngle: Self.endAngle)
            .trim(from: 0, to: CGFloat(needleFraction))
            .stroke(
                AngularGradient(
                    colors: [.cyan, .cyan, .green, .green],
                    center: .center,
                    startAngle: .degrees(Self.startAngle),
                    endAngle: .degrees(Self.endAngle)
                ),
                style: StrokeStyle(lineWidth: 22, lineCap: .round)
            )
            .frame(width: arcRadius * 2, height: arcRadius * 2)
            .position(center)
            .animation(.easeOut(duration: 0.4), value: needleFraction)
    }

    private func scaleLabels(arcRadius: CGFloat, center: CGPoint) -> some View {
        ForEach(Self.scaleMarks, id: \.label) { mark in
            scaleLabel(mark: mark, arcRadius: arcRadius, center: center)
        }
    }

    private func scaleLabel(mark: (value: Double, label: String), arcRadius: CGFloat, center: CGPoint) -> some View {
        let frac = Self.logFraction(mark.value)
        let angle = Self.startAngle + frac * Self.sweep
        let labelRadius = arcRadius + 28
        let rad = angle * .pi / 180
        let x = center.x + labelRadius * cos(rad)
        let y = center.y + labelRadius * sin(rad)
        return Text(mark.label)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.primary.opacity(0.7))
            .position(x: x, y: y)
    }

    private func scaleTicks(arcRadius: CGFloat, center: CGPoint) -> some View {
        ForEach(Self.scaleMarks, id: \.label) { mark in
            scaleTick(mark: mark, arcRadius: arcRadius, center: center)
        }
    }

    private func scaleTick(mark: (value: Double, label: String), arcRadius: CGFloat, center: CGPoint) -> some View {
        let frac = Self.logFraction(mark.value)
        let angle = Self.startAngle + frac * Self.sweep
        let rad = angle * .pi / 180
        let outerR = arcRadius - 13
        let innerR = arcRadius - 32
        return Path { p in
            p.move(to: CGPoint(
                x: center.x + innerR * cos(rad),
                y: center.y + innerR * sin(rad)
            ))
            p.addLine(to: CGPoint(
                x: center.x + outerR * cos(rad),
                y: center.y + outerR * sin(rad)
            ))
        }
        .stroke(Color.primary.opacity(0.3), lineWidth: 2.5)
    }

    @ViewBuilder
    private func centerContent(center: CGPoint) -> some View {
        if !isRunning && !hasResult {
            Text(L10n.go)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.cyan)
                .position(center)
        } else {
            VStack(spacing: 2) {
                Text(speedText ?? "—")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text(L10n.mbps)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if isRunning {
                    Text(phase.description)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
            .position(center)
        }
    }
}

struct SpeedtestArcShape: Shape {
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.addArc(center: c, radius: r, startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
        return p
    }
}

struct TracerouteMapView: View {
    let hops: [TracerouteHop]

    /// Classic map: default world region when no route is shown
    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25, longitude: 15),
        span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 100)
    )

    var body: some View {
        Map(initialPosition: .region(TracerouteMapView.defaultRegion)) {
            ForEach(hops) { hop in
                if let coord = hop.coordinate {
                    Annotation(hop.host, coordinate: coord) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                }
            }

            if hops.count > 1 {
                MapPolyline(coordinates: hops.compactMap { $0.coordinate })
                    .stroke(Color.blue, lineWidth: 2)
            }
        }
        .mapStyle(.standard)
    }
}

// MARK: - Traceroute Sheet View
struct TracerouteSheetView: View {
    @ObservedObject var tracerouteService: TracerouteService
    @Binding var destination: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("Enter IP or domain", text: $destination)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit {
                            if !tracerouteService.isRunning && !destination.isEmpty {
                                tracerouteService.traceroute(to: destination)
                            }
                        }

                    if tracerouteService.isRunning {
                        ProgressView()
                    } else if !destination.isEmpty {
                        Button(action: {
                            tracerouteService.traceroute(to: destination)
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal, 20)
                .padding(.top, 10)

                // Hops list
                if tracerouteService.hops.isEmpty && !tracerouteService.isRunning {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(L10n.enterIpOrDomainShort)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracerouteService.hops.enumerated()), id: \.element.id) { index, hop in
                                HStack(spacing: 12) {
                                    if let flag = hop.flagEmoji {
                                        Text(flag)
                                            .font(.title3)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hop.host)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        if let ip = hop.ip {
                                            Text(ip)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if let latency = hop.latencyMs {
                                        Text(String(format: "%.0f ms", latency))
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(latency < 50 ? .green : (latency < 100 ? .orange : .red))
                                    } else if hop.status == .timeout {
                                        Text("* * *")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 20)

                                if index < tracerouteService.hops.count - 1 {
                                    Divider()
                                        .padding(.leading, 44)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(L10n.tracerouteTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
