# Technology comparison: vless-ios vs dopplerswift (PulseVPN)

This document compares [dopplerswift](https://github.com/pochtmanr/dopplerswift) (PulseVPN) with this repo so we align on the same VPN technology where possible.

## dopplerswift (PulseVPN) stack

| Layer | Technology |
|-------|------------|
| **Tunnel** | `NEPacketTunnelProvider` extension (`PulseVPNTunnel`), bundle ID `com.simnetiq.vpnreact.tunnel` |
| **Core** | **LibXray** – Xray core (C/Go) via Swift wrapper. Supports VLESS, Reality, VMess, Trojan, etc. |
| **Config format** | Full **Xray JSON** passed as `providerConfiguration["xrayJSON"]` (and saved to App Group as backup) |
| **App → Tunnel** | Main app converts VLESS share link → `VLessConfig` (VLessParser) → Xray JSON (XrayConfigBuilder) → `VPNManager.connect(xrayJSON:)` → `NETunnelProviderProtocol.providerConfiguration["xrayJSON"]` |
| **App Group** | `group.com.simnetiq.vpnreact` – `ConfigStore.saveXrayConfig` / `loadXrayConfig` |
| **Network** | HTTP proxy mode (no TUN capture). Xray runs SOCKS + HTTP inbounds; iOS routes HTTP/HTTPS via `NEProxySettings`. |
| **Assets** | `geoip.dat`, `geosite.dat` in tunnel extension for routing. |

## vless-ios (FoxyWall) before alignment

| Layer | Technology |
|-------|------------|
| **Tunnel** | **No tunnel target in repo.** `VlessTunnelManager` expects extension `com.theholylabs.foxywall.VlessTunnel`. |
| **Config** | Passed `vless_url` string only; no Xray JSON. |
| **Connect** | **IPSec only** – `connectVPNAfterConsent()` required OpenVPN username/password and set up `NEVPNProtocolIPSec`. VLESS path was never used. |
| **App Group** | None. |

## Alignment done in this repo

1. **Same config flow as dopplerswift**
   - **VLessParser**: parses `vless://` URI (including Reality query params: `security=reality`, `pbk`, `sid`, `sni`, `fp`, `type`, etc.) into `VLessConfig`.
   - **XrayConfigBuilder**: builds Xray JSON from `VLessConfig` (VLESS outbound, optional Reality/TLS stream settings, routing).
   - **ConfigStore**: App Group `group.com.theholylabs.foxywall`; save/load `xray_config_json` so the tunnel can read config from the app.

2. **VlessTunnelManager**
   - Passes **xrayJSON** in `providerConfiguration["xrayJSON"]` (same key as dopplerswift).
   - Optionally still accepts `vless_url` and converts to Xray JSON in-app before passing.
   - Tunnel bundle ID remains `com.theholylabs.foxywall.VlessTunnel` for when the extension target is added.

3. **Connect flow**
   - **VLESS first**: If server has `hasVlessConfig`, build Xray JSON from `resolvedVlessUrl` and connect via `VlessTunnelManager` (xrayJSON).
   - **Fallback**: Otherwise use existing IPSec/OpenVPN path.
   - Disconnect uses the same manager that was used to connect (VLESS tunnel vs system VPN).

## What’s still missing for full parity

- **Packet Tunnel Extension target** in this Xcode project that:
  - Uses **LibXray** (Xray core) – e.g. [libxray](https://github.com/wanliyunyan/libxray) or similar iOS Xray framework.
  - Reads `providerConfiguration["xrayJSON"]` (and optionally `ConfigStore.loadXrayConfig()` from App Group).
  - Prepares inbounds (SOCKS/HTTP), runs Xray with the provided JSON, applies `NEPacketTunnelNetworkSettings` with proxy (same as dopplerswift’s `PacketTunnelProvider`).
  - Includes `geoip.dat` / `geosite.dat` if using geo routing.
- **App Group** added to the **tunnel extension** entitlements (`group.com.theholylabs.foxywall`) so it can read the saved config.

Once the tunnel extension is implemented to expect **xrayJSON** and run LibXray, the app side will already be using the same technology and config format as dopplerswift.
