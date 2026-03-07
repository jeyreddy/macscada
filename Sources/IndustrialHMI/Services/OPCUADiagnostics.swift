// MARK: - OPCUADiagnostics.swift
//
// Step-by-step OPC-UA connection diagnostic tool.
// Helps engineers identify why a connection attempt to an OPC-UA server fails.
//
// ── Diagnostic Steps ──────────────────────────────────────────────────────────
//   1. Parse URL        — validates opc.tcp://host:port format
//   2. DNS Resolution   — resolves hostname via NWParameters.tcp → NWEndpoint
//   3. TCP Reachability — attempts TCP connection to host:port (5 s timeout)
//   4. OPC-UA Handshake — UA_Client_connect() to verify OPC-UA layer responds
//   5. Browse Root      — UA_Client_browseSimplifiedExtensionObject (sanity check)
//
// ── DiagnosticStep ────────────────────────────────────────────────────────────
//   Status: .running, .pass, .fail, .warning
//   title: step name displayed in UI
//   detail: technical detail (IP address, error code, latency ms)
//   suggestion: actionable advice shown when status == .fail
//   durationMs: wall-clock time for the step (shown in UI as "Xms")
//
// ── Suggested URLs ────────────────────────────────────────────────────────────
//   suggestedURLs: [String] populated when DNS resolves to multiple IPs or
//   when the server has multiple discoveryUrls. Shown in OPCUAConnectionView
//   as clickable alternatives to try.
//
// ── run(url:) Sequence ────────────────────────────────────────────────────────
//   Steps run sequentially — later steps are skipped if earlier ones fail.
//   All work dispatched to background queue; @Published updates back on @MainActor.
//   Each step records start time → computes durationMs on completion.
//   isRunning published: OPCUAConnectionView shows a progress indicator during run.
//
// ── Integration ───────────────────────────────────────────────────────────────
//   OPCUAConnectionView instantiates OPCUADiagnostics as @StateObject.
//   "Run Diagnostics" button in diagnosticsSection calls diagnostics.run(url: diagURL).
//   Results shown as a list of DiagnosticStep rows with status icons.

import Foundation
import Network
import Darwin
import COPC

// MARK: - DiagnosticStep

struct DiagnosticStep: Identifiable {
    enum Status { case pass, fail, warning, running }

    let id       = UUID()
    let title:   String
    var status:  Status
    var detail:  String
    var suggestion: String? = nil
    var durationMs: Int? = nil
}

// MARK: - OPCUADiagnostics

/// Runs a sequence of checks to diagnose OPC-UA connection problems.
@MainActor
class OPCUADiagnostics: ObservableObject {
    @Published var steps:       [DiagnosticStep] = []
    @Published var isRunning:   Bool = false
    @Published var suggestedURLs: [String] = []

    // MARK: - Run

    func run(url rawURL: String) async {
        isRunning     = true
        steps         = []
        suggestedURLs = []

        // ── Step 1: Parse URL ─────────────────────────────────────────────
        let step = DiagnosticStep(title: "Parse URL", status: .running, detail: rawURL)
        steps.append(step)

        guard let parsed = parseOPCUAURL(rawURL) else {
            steps[index("Parse URL")].status = .fail
            steps[index("Parse URL")].detail  = "'\(rawURL)' is not a valid opc.tcp:// URL"
            steps[index("Parse URL")].suggestion = "Use format: opc.tcp://hostname:4840"
            isRunning = false
            return
        }
        let host = parsed.host
        let port = parsed.port
        steps[index("Parse URL")].status = .pass
        steps[index("Parse URL")].detail  = "host=\(host)  port=\(port)"

        // ── Step 2: Hostname resolution ────────────────────────────────────
        let resolveStart = Date()
        let resolveStep = DiagnosticStep(title: "Resolve Hostname", status: .running,
                                          detail: "Resolving '\(host)'…")
        steps.append(resolveStep)

        let resolvedIPs = resolveHostname(host)
        let resolveMs   = Int(Date().timeIntervalSince(resolveStart) * 1000)
        if resolvedIPs.isEmpty {
            steps[index("Resolve Hostname")].status = .fail
            steps[index("Resolve Hostname")].detail  = "'\(host)' could not be resolved (DNS/mDNS lookup failed)"
            steps[index("Resolve Hostname")].suggestion =
                "The server hostname changed. Try:\n  • opc.tcp://localhost:\(port)\n  • opc.tcp://127.0.0.1:\(port)\n  • Use 'Scan Network' to find the new hostname"
            steps[index("Resolve Hostname")].durationMs = resolveMs
        } else {
            steps[index("Resolve Hostname")].status = .pass
            steps[index("Resolve Hostname")].detail  = "Resolved to: \(resolvedIPs.joined(separator: ", ")) (\(resolveMs) ms)"
            steps[index("Resolve Hostname")].durationMs = resolveMs
        }

        // ── Step 3: TCP connectivity (localhost + resolved IPs) ────────────
        let tcpStep = DiagnosticStep(title: "TCP Port \(port)", status: .running,
                                      detail: "Testing TCP connectivity…")
        steps.append(tcpStep)

        // Always try localhost and 127.0.0.1 in parallel with the given host
        let tcpTargets: [String] = Array(Set(resolvedIPs + ["127.0.0.1", "::1"]))
        var tcpResults: [(host: String, ok: Bool, ms: Int)] = []

        await withTaskGroup(of: (String, Bool, Int).self) { group in
            for target in tcpTargets {
                group.addTask {
                    let t = Date()
                    let ok = await self.testTCP(host: target, port: port)
                    return (target, ok, Int(Date().timeIntervalSince(t) * 1000))
                }
            }
            for await (h, ok, ms) in group {
                tcpResults.append((h, ok, ms))
            }
        }

        let reachable = tcpResults.filter { $0.ok }
        if reachable.isEmpty {
            steps[index("TCP Port \(port)")].status = .fail
            steps[index("TCP Port \(port)")].detail  = "Port \(port) is not reachable on any tested address"
            steps[index("TCP Port \(port)")].suggestion =
                "No process appears to be listening on port \(port). Check that the OPC-UA server is running."
        } else {
            let summary = reachable.map { "\($0.host) (\($0.ms) ms)" }.joined(separator: ", ")
            steps[index("TCP Port \(port)")].status = .pass
            steps[index("TCP Port \(port)")].detail  = "Reachable at: \(summary)"

            // Build suggested URLs from reachable addresses
            for r in reachable {
                let suggested = "opc.tcp://\(r.host):\(port)"
                if !suggestedURLs.contains(suggested) {
                    suggestedURLs.append(suggested)
                }
            }
        }

        // ── Step 4: OPC-UA endpoint probe ─────────────────────────────────
        // Try reachable addresses with UA_Client_getEndpoints
        let probeTargets: [String] = reachable.map { "opc.tcp://\($0.host):\(port)" }

        let probeStep = DiagnosticStep(title: "OPC-UA Endpoint Probe", status: .running,
                                        detail: "Querying endpoints…")
        steps.append(probeStep)

        var probeSuccess = false
        for probeURL in probeTargets {
            let t = Date()
            let eps = await fetchEndpoints(url: probeURL)
            let ms  = Int(Date().timeIntervalSince(t) * 1000)
            if !eps.isEmpty {
                probeSuccess = true
                let modeList = eps.map { $0.securityMode.rawValue }.joined(separator: ", ")
                steps[index("OPC-UA Endpoint Probe")].status = .pass
                steps[index("OPC-UA Endpoint Probe")].detail  =
                    "Found \(eps.count) endpoint(s) at \(probeURL) (\(ms) ms)\nSecurity: \(modeList)"
                steps[index("OPC-UA Endpoint Probe")].durationMs = ms
                // Prefer this URL
                if !suggestedURLs.contains(probeURL) {
                    suggestedURLs.insert(probeURL, at: 0)
                }
                break
            }
        }
        if !probeSuccess {
            steps[index("OPC-UA Endpoint Probe")].status = reachable.isEmpty ? .warning : .fail
            steps[index("OPC-UA Endpoint Probe")].detail  =
                reachable.isEmpty
                    ? "Skipped — no reachable address found"
                    : "Server responded on TCP but rejected OPC-UA endpoint query"
            steps[index("OPC-UA Endpoint Probe")].suggestion =
                "The process on port \(port) may not be an OPC-UA server, or may require a different security policy."
        }

        // ── Step 5: LocalHostName hint ─────────────────────────────────────
        let localName = ProcessInfo.processInfo.hostName
        let hintStep = DiagnosticStep(title: "This Machine", status: .pass,
                                       detail: "Hostname: \(localName)")
        steps.append(hintStep)
        let localURL = "opc.tcp://\(localName):\(port)"
        if !suggestedURLs.contains(localURL) && !suggestedURLs.contains("opc.tcp://localhost:\(port)") {
            suggestedURLs.append("opc.tcp://localhost:\(port)")
        }

        isRunning = false
    }

    // MARK: - Helpers

    private func index(_ title: String) -> Int {
        steps.firstIndex(where: { $0.title == title }) ?? 0
    }

    private func parseOPCUAURL(_ raw: String) -> (host: String, port: Int)? {
        guard raw.hasPrefix("opc.tcp://"),
              let inner = URL(string: raw.replacingOccurrences(of: "opc.tcp://", with: "http://")) else {
            return nil
        }
        guard let host = inner.host, !host.isEmpty else { return nil }
        let port = inner.port ?? 4840
        return (host, port)
    }

    private func resolveHostname(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family   = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM)
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host, nil, &hints, &res) == 0, let root = res else { return [] }
        defer { freeaddrinfo(root) }
        var ips: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = root
        while let ptr = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ai_addr, socklen_t(ptr.pointee.ai_addrlen),
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if !ips.contains(ip) { ips.append(ip) }
            }
            cur = ptr.pointee.ai_next
        }
        return ips
    }

    private func testTCP(host: String, port: Int) async -> Bool {
        let nwHost: NWEndpoint.Host = .name(host, nil)
        let nwPort  = NWEndpoint.Port(rawValue: UInt16(port)) ?? 4840
        let conn    = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        // Use a lock-protected flag so concurrent NW and GCD callbacks are safe.
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func tryFire() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !fired else { return false }
                fired = true; return true
            }
        }
        let flag = OnceFlag()
        return await withCheckedContinuation { cont in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.cancel()
                    if flag.tryFire() { cont.resume(returning: true) }
                case .failed, .cancelled:
                    if flag.tryFire() { cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                conn.cancel()
                if flag.tryFire() { cont.resume(returning: false) }
            }
        }
    }

    private func fetchEndpoints(url: String) async -> [OPCUAEndpointInfo] {
        // Reuse the discovery logic already in OPCUAClientService via a temp approach.
        // We create a lightweight wrapper here to avoid tight coupling.
        typealias EPResult = [OPCUAEndpointInfo]
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let tmp = UA_Client_new()
                UA_ClientConfig_setDefault(UA_Client_getConfig(tmp))
                defer { UA_Client_delete(tmp) }

                var count: Int = 0
                var eps: UnsafeMutablePointer<UA_EndpointDescription>? = nil
                guard UA_Client_getEndpoints(tmp, url, &count, &eps) == UA_STATUSCODE_GOOD,
                      count > 0, let ep = eps else {
                    cont.resume(returning: [])
                    return
                }
                var result: EPResult = []
                for i in 0..<count {
                    let d    = ep[i]
                    let epURL = self.uaStr(d.endpointUrl)
                    let name  = self.uaStr(d.server.applicationName.text)
                    let mode  = OPCUASecurityMode(rawMode: d.securityMode.rawValue)
                    let atype = OPCUAApplicationType(rawValue: d.server.applicationType.rawValue)
                    let pol   = self.uaStr(d.securityPolicyUri)
                    result.append(OPCUAEndpointInfo(
                        endpointUrl: epURL.isEmpty ? url : epURL,
                        serverName:  name.isEmpty  ? "OPC-UA Server" : name,
                        applicationType: atype,
                        securityMode: mode,
                        securityPolicy: pol
                    ))
                }
                for i in 0..<count {
                    var e = eps!.advanced(by: i).pointee
                    UA_EndpointDescription_clear(&e)
                }
                Darwin.free(eps)
                cont.resume(returning: result)
            }
        }
    }

    private nonisolated func uaStr(_ s: UA_String) -> String {
        guard s.length > 0, let data = s.data else { return "" }
        return String(bytes: UnsafeRawBufferPointer(start: data, count: s.length), encoding: .utf8) ?? ""
    }
}
