// MARK: - OPCUABonjourScanner.swift
//
// mDNS (Bonjour) scanner for discovering OPC-UA servers on the local network.
// OPC-UA servers register as _opcua-tcp._tcp. mDNS services per OPC-UA Part 12 §6.
//
// ── Compatible Servers ────────────────────────────────────────────────────────
//   Kepware OPC Server, Prosys OPC UA Simulation Server, open62541-based servers,
//   UA Toolkit servers, AVEVA, Rockwell FactoryTalk, Siemens OPC-UA servers.
//   All must publish _opcua-tcp._tcp. to be discovered.
//
// ── Scan Lifecycle ────────────────────────────────────────────────────────────
//   scan(timeout: 6.0):
//     Clears servers[] + pending[]. Sets isScanning = true.
//     Creates NetServiceBrowser, searches for _opcua-tcp._tcp. in "local.".
//     Stops after `timeout` seconds via Timer (default 6 s).
//   stopScan():
//     Stops browser, resolves any remaining pending services, sets isScanning = false.
//
// ── NSNetServiceBrowserDelegate ───────────────────────────────────────────────
//   browser(_:didFind:) → service.delegate = self → service.resolve(withTimeout: 5)
//   Added to pending[] during resolution.
//   browser(_:didRemove:) → removes from servers[] if previously resolved.
//
// ── NSNetServiceDelegate ──────────────────────────────────────────────────────
//   netServiceDidResolveAddress(_:):
//     Extracts hostname + port from NetService.
//     Creates OPCUABonjourServer { name, host, port, url = "opc.tcp://host:port" }
//     Appends to servers[] (deduplicates by host+port).
//
// ── OPCUABonjourServer ────────────────────────────────────────────────────────
//   name: mDNS service name (e.g. "Kepware OPC Server - UA/DA")
//   host: resolved hostname (e.g. "plc01.local" or "192.168.1.10")
//   port: TCP port (typically 4840 or 49320)
//   url:  computed "opc.tcp://host:port" — ready for OPCUAClientService.connect()

import Foundation

// MARK: - Discovered Bonjour Server

struct OPCUABonjourServer: Identifiable, Equatable {
    let id   = UUID()
    let name: String
    let host: String    // resolved hostname, e.g. "plc01.local"
    let port: Int

    /// OPC-UA endpoint URL ready to connect.
    var url: String { "opc.tcp://\(host):\(port)" }
}

// MARK: - Bonjour Scanner

/// Scans the local network for OPC-UA servers via mDNS (_opcua-tcp._tcp.).
/// Most OPC-UA servers (Kepware, Prosys, UA Toolkit, open62541 …) register this service.
@MainActor
final class OPCUABonjourScanner: NSObject, ObservableObject {

    @Published var servers:    [OPCUABonjourServer] = []
    @Published var isScanning: Bool = false

    private var browser:    NetServiceBrowser?
    private var pending:    [NetService] = []
    private var stopTimer:  Timer?

    // MARK: - Public API

    func scan(timeout: TimeInterval = 6.0) {
        servers   = []
        pending   = []
        isScanning = true

        let b = NetServiceBrowser()
        b.delegate = self
        browser = b
        b.searchForServices(ofType: "_opcua-tcp._tcp.", inDomain: "local.")

        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopScan() }
        }
        Logger.shared.info("Bonjour scan started for _opcua-tcp._tcp.")
    }

    func stopScan() {
        browser?.stop()
        browser = nil
        pending.removeAll()
        isScanning = false
        stopTimer?.invalidate()
        stopTimer = nil
        Logger.shared.info("Bonjour scan stopped — found \(servers.count) server(s)")
    }

    // MARK: - Private helpers

    private func addServer(name: String, hostName: String, port: Int) {
        // Strip trailing dot from mDNS FQDN (e.g. "plc01.local." → "plc01.local")
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        guard !servers.contains(where: { $0.host == host && $0.port == port }) else { return }
        servers.append(OPCUABonjourServer(name: name, host: host, port: port))
        Logger.shared.info("Bonjour: found OPC-UA server '\(name)' at \(host):\(port)")
    }
}

// MARK: - NetServiceBrowserDelegate

extension OPCUABonjourScanner: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        Task { @MainActor in self.pending.append(service) }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Logger.shared.warning("Bonjour search error: \(errorDict)")
        Task { @MainActor in self.isScanning = false }
    }
}

// MARK: - NetServiceDelegate

extension OPCUABonjourScanner: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? sender.name
        let port = sender.port
        let name = sender.name
        Task { @MainActor in self.addServer(name: name, hostName: host, port: port) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Logger.shared.warning("Bonjour: could not resolve '\(sender.name)': \(errorDict)")
    }
}
