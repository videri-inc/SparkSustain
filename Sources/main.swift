import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import IOKit
import Network
import ServiceManagement

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Paths & logging

let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/SparkSustain")
let configURL = appSupportDir.appendingPathComponent("config.json")
let canvasesURL = appSupportDir.appendingPathComponent("canvases.json")
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SparkSustain.log")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
    NSLog("SparkSustain: %@", message)
}

// MARK: - Control Center bridge files

/// Folder shared with the sandboxed Control Center extension.
let sharedControlDir = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.videri.jay.sparksustain")
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.videri.jay.sparksustain")

/// Publish the Sparks' on/off state for the Control Center control and ask
/// the system to refresh it.
func writeControlState(on: Bool) {
    try? FileManager.default.createDirectory(at: sharedControlDir, withIntermediateDirectories: true)
    let url = sharedControlDir.appendingPathComponent("control-state.json")
    try? JSONSerialization.data(withJSONObject: ["on": on]).write(to: url)
    #if canImport(WidgetKit)
    if #available(macOS 26.0, *) {
        ControlCenter.shared.reloadAllControls()
    }
    #endif
}

// MARK: - Desk power detection

/// Identifies a specific power adapter (e.g. the USB-C dock/monitor at the
/// desk) so wake brightness can require being plugged into it.
struct DeskPower: Codable {
    var watts: Int
    var vendor_id: Int
    var product_id: Int
    var label: String { vendor_id != 0 ? "\(watts)W USB-C (vendor \(vendor_id))" : "\(watts)W adapter" }
}

/// Read the current external power adapter from the battery controller.
func currentPowerAdapter() -> (connected: Bool, watts: Int, vendor: Int, product: Int) {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return (false, 0, 0, 0) }
    defer { IOObjectRelease(service) }
    func prop(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
    let connected = (prop("ExternalConnected") as? Bool) ?? false
    let details = prop("AdapterDetails") as? [String: Any]
    let watts = details?["Watts"] as? Int ?? 0
    var vendor = 0, product = 0
    if let feds = prop("FedDetails") as? [[String: Any]] {
        for fed in feds where (fed["FedExternalConnected"] as? Int) == 1 {
            vendor = fed["FedVendorID"] as? Int ?? 0
            product = fed["FedProductID"] as? Int ?? 0
            break
        }
    }
    return (connected, watts, vendor, product)
}

/// True when no desk-power requirement is set, or the Mac is currently
/// drawing from the captured adapter (matched by USB vendor/product id,
/// falling back to wattage when the adapter reports no identity).
func isOnDeskPower(_ config: Config) -> Bool {
    guard let desk = config.desk_power else { return true }
    let adapter = currentPowerAdapter()
    guard adapter.connected else { return false }
    if desk.vendor_id != 0 {
        return adapter.vendor == desk.vendor_id && adapter.product == desk.product_id
    }
    return adapter.watts == desk.watts
}

// MARK: - Config

struct CanvasTarget: Codable {
    var name: String
    var device_id: String
    var device_jid: String
    var player_id: String
    /// Tenant the canvas belongs to — sent as the x-tenant header.
    var tenant: String?
}

struct Config: Codable {
    var api_base_url: String
    var username: String
    var password: String
    var api_key: String
    var tenant: String
    var wake_brightness_percent: Int
    var sleep_brightness_percent: Int
    /// How long a hotkey / Control Center toggle holds its state before
    /// automation resumes (menu holds pick their own duration).
    var default_override_minutes: Int?
    /// Workspaces (tenants) this install is allowed to see and control.
    /// Empty/nil = all workspaces the account can access.
    var workspaces: [String]?
    /// Per-tenant sub-workspace scoping: tenant -> checked group UUIDs.
    /// A checked group includes everything nested beneath it. Empty/missing
    /// list = the whole tenant.
    var workspace_groups: [String: [String]]?
    var office_network_prefixes: [String]?
    /// When set, wake brightness additionally requires the Mac to be drawing
    /// power from this specific adapter (e.g. the USB-C dock at the desk).
    /// MagSafe, battery, or any other charger counts as away-from-desk.
    var desk_power: DeskPower?
    /// Override for the update manifest URL (default: the GitHub repo).
    var update_url: String?
    /// Set once the user has been warned that SparkSustain deletes existing
    /// platform brightness schedules for its displays (true = deleted,
    /// false = user declined; nil = not yet asked).
    var schedules_overridden: Bool?
    var canvases: [CanvasTarget]

    static let template = Config(
        api_base_url: "https://api.go.videri.com",
        username: "",
        password: "",
        api_key: "",
        tenant: "",
        wake_brightness_percent: 70,
        sleep_brightness_percent: 0,
        default_override_minutes: 60,
        workspaces: [],
        workspace_groups: [:],
        office_network_prefixes: [],
        desk_power: nil,
        update_url: nil,
        schedules_overridden: nil,
        canvases: []
    )

    var hasCredentials: Bool { !username.isEmpty && !password.isEmpty && !api_key.isEmpty }
    var isFilledIn: Bool { hasCredentials && canvases.contains { !$0.device_jid.isEmpty } }
    var readyTargets: [CanvasTarget] { canvases.filter { !$0.device_jid.isEmpty } }
    var officePrefixes: [String] { (office_network_prefixes ?? []).filter { !$0.isEmpty } }
}

func loadConfig() -> Config? {
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        log("Config parse error: \(error)")
        return nil
    }
}

func saveConfig(_ config: Config) {
    try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config) {
        try? data.write(to: configURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}

// MARK: - Local network detection

func localIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
    defer { freeifaddrs(ifaddrPtr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let current = ptr {
        let ifa = current.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
           (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: host)
                if !address.isEmpty && !address.hasPrefix("169.254.") {
                    addresses.append(address)
                }
            }
        }
        ptr = ifa.ifa_next
    }
    return addresses
}

/// "192.168.4.23" -> "192.168.4." (assumes a /24, right for typical office LANs)
func subnetPrefix(of address: String) -> String? {
    let parts = address.split(separator: ".")
    guard parts.count == 4 else { return nil }
    return parts.prefix(3).joined(separator: ".") + "."
}

func currentSubnetPrefixes() -> [String] {
    Array(Set(localIPv4Addresses().compactMap(subnetPrefix(of:)))).sorted()
}

/// True when a local IPv4 matches a configured office prefix.
/// With no prefixes configured, network gating is off — always "in office".
func isOnOfficeNetwork(_ config: Config) -> Bool {
    let prefixes = config.officePrefixes
    guard !prefixes.isEmpty else { return true }
    let locals = localIPv4Addresses()
    return locals.contains { local in prefixes.contains { local.hasPrefix($0) } }
}

// MARK: - HTTP helper (synchronous)

struct HTTPResult {
    let status: Int
    let body: Data
    var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
}

enum HTTPError: Error, CustomStringConvertible {
    case transport(String)
    var description: String {
        switch self { case .transport(let m): return m }
    }
}

func httpRequest(method: String, url: URL, headers: [String: String], jsonBody: Data?) throws -> HTTPResult {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    if let body = jsonBody {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }
    let semaphore = DispatchSemaphore(value: 0)
    var result: HTTPResult?
    var failure: String?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            failure = error.localizedDescription
        } else if let http = response as? HTTPURLResponse {
            result = HTTPResult(status: http.statusCode, body: data ?? Data())
        } else {
            failure = "no response"
        }
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    if let failure = failure { throw HTTPError.transport(failure) }
    return result!
}

// MARK: - Videri API client

struct CanvasInfo {
    let name, deviceId, jid, playerId, product, presence, location, group, tenant: String

    var target: CanvasTarget {
        CanvasTarget(name: name, device_id: deviceId, device_jid: jid,
                     player_id: playerId, tenant: tenant)
    }

    var label: String {
        var details: [String] = []
        if !product.isEmpty { details.append(product) }
        if !location.isEmpty { details.append(location) }
        else if !group.isEmpty { details.append(group) }
        if !tenant.isEmpty { details.append(tenant) }
        let suffix = details.isEmpty ? "" : " — " + details.joined(separator: ", ")
        let state = presence.isEmpty ? "" : "  [\(presence)]"
        return "\(name)\(suffix)\(state)"
    }
}

/// Decode the payload claims of a JWT without verifying the signature —
/// used only to read our own token's tenant list locally.
func jwtClaims(_ jwt: String) -> [String: Any] {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return [:] }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return json
}

final class VideriClient {
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast
    /// Tenant names from the id_token's "tenants" claim, captured at auth.
    private var tokenTenants: [String] = []
    private let lock = NSLock()

    func invalidateToken() {
        lock.lock(); defer { lock.unlock() }
        cachedToken = nil
        tokenExpiry = .distantPast
    }

    private func token(_ config: Config) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let token = cachedToken, tokenExpiry > Date().addingTimeInterval(300) {
            return token
        }
        let url = URL(string: "\(config.api_base_url)/rpm-service/v2/auth/token")!
        let body = try JSONSerialization.data(withJSONObject: [
            "username": config.username,
            "password": config.password,
            "api_key": config.api_key,
        ])
        let result = try httpRequest(method: "POST", url: url, headers: [:], jsonBody: body)
        guard result.status == 200,
              let json = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw HTTPError.transport("Sign-in failed (HTTP \(result.status)). Check your username, password, and API key.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        cachedToken = idToken
        tokenExpiry = Date().addingTimeInterval(expiresIn)
        // The "tenants" claim is a JSON-encoded string array inside the JWT.
        if let claim = jwtClaims(idToken)["tenants"] as? String,
           let data = claim.data(using: .utf8),
           let names = try? JSONSerialization.jsonObject(with: data) as? [String] {
            tokenTenants = names
        }
        log("Obtained new API token (expires in \(Int(expiresIn))s; tenants: \(tokenTenants.joined(separator: ",")))")
        return idToken
    }

    /// Every workspace (tenant) the account's token grants access to.
    func allTokenTenants(_ config: Config) throws -> [String] {
        _ = try token(config)
        lock.lock(); defer { lock.unlock() }
        return tokenTenants.isEmpty ? [""] : tokenTenants
    }

    /// Tenants to operate across: the user's chosen workspaces if set, else
    /// the legacy single-tenant override, else everything in the token.
    func availableTenants(_ config: Config) throws -> [String] {
        if let workspaces = config.workspaces, !workspaces.isEmpty { return workspaces }
        if !config.tenant.isEmpty { return [config.tenant] }
        return try allTokenTenants(config)
    }

    /// Force a fresh token fetch to prove the credentials work.
    func validateCredentials(_ config: Config) throws {
        invalidateToken()
        _ = try token(config)
    }

    private func authHeaders(_ config: Config, tenant: String) throws -> [String: String] {
        var headers = ["Authorization": "Bearer \(try token(config))"]
        if !tenant.isEmpty { headers["x-tenant"] = tenant }
        return headers
    }

    // MARK: Workspace (group) hierarchy

    /// One node of a tenant's workspace (group) hierarchy.
    struct GroupNode {
        let uuid: String
        let name: String
        let children: [GroupNode]
    }

    /// The current user's workspace tree for one tenant.
    func fetchGroupTree(config: Config, tenant: String) throws -> [GroupNode] {
        let headers = try authHeaders(config, tenant: tenant)
        let url = URL(string: "\(config.api_base_url)/rpm/v1/users/me/groups_access")!
        let result = try httpRequest(method: "GET", url: url, headers: headers, jsonBody: nil)
        if result.status == 401 { invalidateToken() }
        guard (200..<300).contains(result.status),
              let json = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let access = json["groupAccess"] as? [[String: Any]] else {
            throw HTTPError.transport("groups_access HTTP \(result.status)")
        }
        func parse(_ nodes: [[String: Any]]) -> [GroupNode] {
            nodes.compactMap { node in
                guard let uuid = node["uuid"] as? String else { return nil }
                let name = (node["displayName"] as? String)
                    ?? (node["name"] as? String) ?? uuid
                let kids = (node["descendants"] as? [[String: Any]]).map(parse) ?? []
                return GroupNode(uuid: uuid, name: name, children: kids)
            }
        }
        return parse(access)
    }

    /// A checked node grants itself plus its entire subtree.
    static func expandGroupSelection(_ checked: Set<String>, tree: [GroupNode]) -> [String] {
        var result = Set<String>()
        func walk(_ nodes: [GroupNode], _ inherited: Bool) {
            for node in nodes {
                let selected = inherited || checked.contains(node.uuid)
                if selected { result.insert(node.uuid) }
                walk(node.children, selected)
            }
        }
        walk(tree, false)
        return Array(result)
    }

    // MARK: Brightness schedules

    /// Permanently delete every platform brightness schedule (canvas settings
    /// event) for the configured displays, per tenant.
    func deleteBrightnessSchedules(config: Config) throws -> String {
        let targets = config.readyTargets
        guard !targets.isEmpty else { throw HTTPError.transport("no canvases configured") }
        let fallbackTenant = ((try? availableTenants(config))?.first) ?? config.tenant
        let groups = Dictionary(grouping: targets) { target in
            (target.tenant?.isEmpty == false) ? target.tenant! : fallbackTenant
        }
        var deleted = 0
        var errors: [String] = []
        for (tenant, group) in groups {
            let ids = group.compactMap { Int($0.player_id) }
            guard !ids.isEmpty else { continue }
            let headers = try authHeaders(config, tenant: tenant)
            let body = try JSONSerialization.data(withJSONObject: ["canvasIds": ids])
            var groupError: String?
            for path in ["/publisher/api/v1/canvas_settings_events", "/api/v1/canvas_settings_events"] {
                let url = URL(string: "\(config.api_base_url)\(path)")!
                let result = try httpRequest(method: "DELETE", url: url, headers: headers, jsonBody: body)
                if (200..<300).contains(result.status) {
                    let json = (try? JSONSerialization.jsonObject(with: result.body) as? [String: Any]) ?? [:]
                    let ok = (json["numberOfSuccessfulEventsDeletion"] as? Int) ?? 0
                    deleted += ok
                    log("Deleted \(ok) brightness schedule events for \(ids.count) canvases (tenant \(tenant))")
                    groupError = nil
                    break
                }
                if result.status == 401 { invalidateToken() }
                groupError = "HTTP \(result.status) at \(path): \(result.bodyString.prefix(120))"
            }
            if let groupError = groupError { errors.append("\(tenant): \(groupError)") }
        }
        if !errors.isEmpty && deleted == 0 { throw HTTPError.transport(errors.joined(separator: " | ")) }
        let suffix = errors.isEmpty ? "" : " (some failed: \(errors.joined(separator: "; ").prefix(120)))"
        return "Deleted \(deleted) brightness schedule event\(deleted == 1 ? "" : "s")\(suffix)"
    }

    // MARK: Canvases

    /// One page-1000 query against /canvases for one tenant, optionally
    /// filtered to specific workspace groups.
    private func fetchCanvasPage(config: Config, tenant: String, assignedToGroup: Bool,
                                 groupUUIDs: [String] = []) throws -> [[String: Any]] {
        let headers = try authHeaders(config, tenant: tenant)
        var urlString = "\(config.api_base_url)/canvas-service/canvases?assigned_to_group=\(assignedToGroup)&size=1000"
        if !groupUUIDs.isEmpty {
            urlString += "&group_uuid=" + groupUUIDs.joined(separator: ",")
        }
        let url = URL(string: urlString)!
        let result = try httpRequest(method: "GET", url: url, headers: headers, jsonBody: nil)
        guard (200..<300).contains(result.status) else {
            if result.status == 401 { invalidateToken() }
            throw HTTPError.transport("HTTP \(result.status): \(result.bodyString.prefix(300))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any] else {
            throw HTTPError.transport("unexpected canvases response")
        }
        return (json["content"] as? [[String: Any]])
            ?? (json["data"] as? [[String: Any]])
            ?? (json["canvases"] as? [[String: Any]]) ?? []
    }

    /// All canvases in one tenant. With a sub-workspace selection, a single
    /// group-filtered query is used; otherwise both readings of the required
    /// assigned_to_group flag are merged, de-duplicating by device id.
    private func fetchTenantCanvases(config: Config, tenant: String) throws -> [[String: Any]] {
        if let checked = config.workspace_groups?[tenant], !checked.isEmpty {
            var uuids = checked
            if let tree = try? fetchGroupTree(config: config, tenant: tenant) {
                let expanded = VideriClient.expandGroupSelection(Set(checked), tree: tree)
                if !expanded.isEmpty { uuids = expanded }
            }
            return try fetchCanvasPage(config: config, tenant: tenant,
                                       assignedToGroup: true, groupUUIDs: uuids)
        }
        var items = try fetchCanvasPage(config: config, tenant: tenant, assignedToGroup: false)
        if items.isEmpty {
            items = try fetchCanvasPage(config: config, tenant: tenant, assignedToGroup: true)
        } else if let grouped = try? fetchCanvasPage(config: config, tenant: tenant, assignedToGroup: true) {
            let seen = Set(items.compactMap { $0["device_id"] as? String })
            items += grouped.filter { canvas in
                guard let id = canvas["device_id"] as? String else { return true }
                return !seen.contains(id)
            }
        }
        return items
    }

    /// Fetch every canvas the account can see, across its chosen workspaces.
    func fetchCanvasList(config: Config) throws -> [CanvasInfo] {
        let tenants = try availableTenants(config)
        var canvases: [CanvasInfo] = []
        var errors: [String] = []
        for tenant in tenants {
            do {
                let items = try fetchTenantCanvases(config: config, tenant: tenant)
                canvases += items.map { canvas in
                    CanvasInfo(
                        name: canvas["name"] as? String ?? "",
                        deviceId: canvas["device_id"] as? String ?? "",
                        jid: canvas["xmpp_jid"] as? String ?? "",
                        playerId: (canvas["id"].map { "\($0)" }) ?? "",
                        product: canvas["product_name"] as? String ?? "",
                        presence: canvas["presence_status"] as? String ?? "",
                        location: canvas["location"] as? String ?? "",
                        group: canvas["group_name"] as? String ?? "",
                        tenant: tenant
                    )
                }
            } catch {
                errors.append("\(tenant): \(error)")
                log("Canvas fetch failed for tenant \(tenant): \(error)")
            }
        }
        if canvases.isEmpty && !errors.isEmpty {
            throw HTTPError.transport(errors.joined(separator: " | "))
        }
        // online first, then by name
        return canvases.sorted {
            if ($0.presence == "online") != ($1.presence == "online") {
                return $0.presence == "online"
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Fetch canvases and also save a browsable copy to canvases.json.
    func discoverCanvases(config: Config) throws -> String {
        let canvases = try fetchCanvasList(config: config)
        let simplified: [[String: Any]] = canvases.map {
            ["name": $0.name, "device_id": $0.deviceId, "device_jid": $0.jid,
             "player_id": $0.playerId, "product_name": $0.product,
             "presence_status": $0.presence, "location": $0.location,
             "group_name": $0.group, "tenant": $0.tenant]
        }
        let out = try JSONSerialization.data(withJSONObject: simplified, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: canvasesURL)
        log("Discovered \(canvases.count) canvases; wrote \(canvasesURL.path)")
        return "Found \(canvases.count) canvases — opening canvases.json."
    }

    // MARK: Commands

    /// One sync_command to one canvas; waits for the device's ack.
    /// Returns nil on SUCCESS, or a short error description.
    private func sendCommand(name: String, params: [String: Any], target: CanvasTarget,
                             tenant: String, config: Config) -> String? {
        do {
            let headers = try authHeaders(config, tenant: tenant)
            let payload: [String: Any] = [
                "message_id": UUID().uuidString,
                "command_name": name,
                "command_params": params,
                "device_id": target.device_id,
                "device_jid": target.device_jid,
                "player_id": target.player_id.isEmpty ? target.device_id : target.player_id,
            ]
            let url = URL(string: "\(config.api_base_url)/messaging-websocket/messaging/sync_command")!
            let body = try JSONSerialization.data(withJSONObject: payload)
            let result = try httpRequest(method: "POST", url: url, headers: headers, jsonBody: body)
            if result.status == 401 { invalidateToken() }
            guard (200..<300).contains(result.status) else {
                return "HTTP \(result.status): \(result.bodyString.prefix(150))"
            }
            let json = (try? JSONSerialization.jsonObject(with: result.body) as? [String: Any]) ?? [:]
            let code = json["response_code"] as? String ?? "NO_RESPONSE"
            return code == "SUCCESS" ? nil : "\(name): \(code)"
        } catch {
            return "\(name): \(error)"
        }
    }

    /// Apply a brightness level to one canvas. Verified live 22 Aug 2026:
    /// the settings-path "brightness" value is inert (current_brightness
    /// doesn't follow it), while the demo command `set_brightness:=N` drives
    /// the real backlight. display_on is the true dark switch for 0%, and
    /// brightness_schedule_enabled must stay false or the device-side
    /// schedule re-overrides the level.
    private func sendBrightnessCommand(value: Int, target: CanvasTarget,
                                       tenant: String, config: Config) -> String? {
        let power: [String: Any] = ["system_properties": [
            "display_on": value > 0,
            "brightness_schedule_enabled": false,
        ]]
        if let error = sendCommand(name: "ops_set_settings", params: power,
                                   target: target, tenant: tenant, config: config) {
            return error
        }
        guard value > 0 else { return nil }   // panel off is all 0% needs
        let demo: [String: Any] = [
            "arg": "set_brightness:=\(value)",
            "command": "demo_command",
            "api_version": 1,
        ]
        return sendCommand(name: "demo_command", params: demo,
                           target: target, tenant: tenant, config: config)
    }

    /// Send brightness to every configured canvas concurrently; each device
    /// acknowledges individually.
    func setBrightness(percent: Int, config: Config) throws -> String {
        let value = max(0, min(255, Int((Double(percent) * 255.0 / 100.0).rounded())))
        let targets = config.readyTargets
        guard !targets.isEmpty else { throw HTTPError.transport("no canvases configured") }
        let fallbackTenant = ((try? availableTenants(config))?.first) ?? config.tenant

        let group = DispatchGroup()
        let resultLock = NSLock()
        var failures: [String] = []
        var succeeded = 0
        for target in targets {
            let t = target
            let tenant = (t.tenant?.isEmpty == false) ? t.tenant! : fallbackTenant
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let failure = self.sendBrightnessCommand(value: value, target: t,
                                                         tenant: tenant, config: config)
                resultLock.lock()
                if let failure = failure {
                    failures.append("\(t.name): \(failure)")
                    log("Brightness \(value)/255 FAILED for \(t.name): \(failure)")
                } else {
                    succeeded += 1
                    log("Brightness \(value)/255 OK for \(t.name)")
                }
                resultLock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 25)
        if succeeded == 0 { throw HTTPError.transport(failures.joined(separator: " | ")) }
        let suffix = failures.isEmpty ? "" : " — \(failures.count) failed: \(failures.joined(separator: "; ").prefix(160))"
        return "Applied \(percent)% to \(succeeded)/\(targets.count) canvases\(suffix)"
    }
}

// MARK: - Auto-update (GitHub-hosted: manifest in repo, zips as release assets)

/// Where every install looks for updates. The manifest lives on the main
/// branch so publishing/rolling back is a normal commit; the zips are
/// GitHub Release assets referenced by absolute URL in the manifest.
let defaultUpdateManifestURL =
    "https://raw.githubusercontent.com/videri-inc/SparkSustain/main/updates/manifest.json"

struct UpdateManifest: Codable {
    struct PlatformEntry: Codable {
        var url: String
        var sha256: String
    }
    var version: String
    var notes: String?
    var mac: PlatformEntry?
    var windows: PlatformEntry?
}

enum Updater {
    static func fetchManifest(from urlString: String) -> UpdateManifest? {
        guard let url = URL(string: urlString),
              let result = try? httpRequest(method: "GET", url: url, headers: [:], jsonBody: nil),
              result.status == 200 else { return nil }
        return try? JSONDecoder().decode(UpdateManifest.self, from: result.body)
    }

    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func shell(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Download, verify, install, relaunch. Returns a status message,
    /// or nil when the swap succeeded and the app is about to restart.
    static func applyUpdate(manifest: UpdateManifest) -> String? {
        guard let entry = manifest.mac else { return "Manifest has no mac entry" }
        guard let downloadURL = URL(string: entry.url) else { return "Bad update URL" }
        let work = URL(fileURLWithPath: "/tmp/sparksustain-update")
        shell("rm -rf '\(work.path)' && mkdir -p '\(work.path)'")
        let zipCopy = work.appendingPathComponent("update.zip")
        do {
            let result = try httpRequest(method: "GET", url: downloadURL, headers: [:], jsonBody: nil)
            guard result.status == 200, !result.body.isEmpty else {
                return "Update download failed (HTTP \(result.status))"
            }
            try result.body.write(to: zipCopy)
        } catch { return "Couldn't download update: \(error)" }
        guard let hash = sha256Hex(of: zipCopy), hash == entry.sha256.lowercased() else {
            log("Update hash mismatch — refusing to install")
            return "Update file failed integrity check — not installed"
        }
        guard shell("cd '\(work.path)' && unzip -oq update.zip") == 0 else {
            return "Couldn't unpack the update"
        }
        // The app may sit at the zip root or one folder down.
        let findApp = "find '\(work.path)' -maxdepth 2 -name 'SparkSustain.app' -print -quit"
        let pipe = Pipe()
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/bin/zsh")
        finder.arguments = ["-c", findApp]
        finder.standardOutput = pipe
        try? finder.run()
        finder.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !found.isEmpty else { return "Update zip contains no SparkSustain.app" }
        let installPath = Bundle.main.bundleURL.path
        log("Installing update \(manifest.version) over \(installPath)")
        let swap = "rm -rf '\(installPath)' && cp -R '\(found)' '\(installPath)' && xattr -cr '\(installPath)'"
        guard shell(swap) == 0 else { return "Couldn't replace the app (check permissions)" }
        // Relaunch after this process exits.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/zsh")
        relaunch.arguments = ["-c", "sleep 1; open '\(installPath)'"]
        try? relaunch.run()
        log("Updated to \(manifest.version) — relaunching")
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return nil
    }
}

// MARK: - Workspace tree checklist (tenants with nested sub-workspaces)

final class WorkspaceTreeView: NSView {
    struct Row {
        let tenant: String
        let uuid: String?      // nil = the tenant root itself
        let title: String
        let depth: Int
    }
    private let rows: [Row]
    private var boxes: [NSButton] = []

    init(rows: [Row], selectedTenants: Set<String>, selectedGroups: Set<String>) {
        self.rows = rows
        let height: CGFloat = min(380, CGFloat(rows.count) * 24 + 12)
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: max(height, 80)))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for row in rows {
            let indent = String(repeating: "      ", count: row.depth)
            let box = NSButton(checkboxWithTitle: indent + row.title, target: nil, action: nil)
            if row.uuid == nil {
                box.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                box.state = selectedTenants.contains(row.tenant) ? .on : .off
            } else {
                box.state = selectedGroups.contains(row.uuid!) ? .on : .off
            }
            boxes.append(box)
            stack.addArrangedSubview(box)
        }
        let scroll = NSScrollView(frame: bounds)
        scroll.hasVerticalScroller = rows.count > 12
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var hasAnySelection: Bool {
        boxes.contains { $0.state == .on }
    }

    /// tenant -> checked group uuids; a tenant checked at the root maps to []
    /// (whole tenant). A root check overrides any group checks beneath it.
    var selection: [String: [String]] {
        var result: [String: [String]] = [:]
        for (index, box) in boxes.enumerated() where box.state == .on {
            let row = rows[index]
            if row.uuid == nil {
                result[row.tenant] = []
            } else if !rootChecked(row.tenant) {
                result[row.tenant, default: []].append(row.uuid!)
            }
        }
        return result
    }

    private func rootChecked(_ tenant: String) -> Bool {
        for (index, box) in boxes.enumerated()
        where rows[index].tenant == tenant && rows[index].uuid == nil {
            return box.state == .on
        }
        return false
    }
}

// MARK: - Canvas picker (checklist with live search)

final class CanvasPickerView: NSView, NSSearchFieldDelegate {
    private let canvases: [CanvasInfo]
    private var checkboxes: [NSButton] = []
    private let searchField = NSSearchField()
    private let stack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")

    init(canvases: [CanvasInfo], preselected: Set<String>) {
        self.canvases = canvases
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        searchField.frame = NSRect(x: 0, y: 312, width: 480, height: 26)
        searchField.placeholderString = "Filter by name, location, or group"
        searchField.delegate = self
        addSubview(searchField)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        for canvas in canvases {
            let box = NSButton(checkboxWithTitle: canvas.label, target: self,
                               action: #selector(selectionChanged))
            box.state = preselected.contains(canvas.jid) ? .on : .off
            box.lineBreakMode = .byTruncatingTail
            checkboxes.append(box)
            stack.addArrangedSubview(box)
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 26, width: 480, height: 278))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let clip = scroll.contentView
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        addSubview(scroll)

        countLabel.frame = NSRect(x: 0, y: 2, width: 480, height: 18)
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        addSubview(countLabel)
        selectionChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func selectionChanged() {
        countLabel.stringValue = "\(selectedJids.count) selected of \(canvases.count) canvases"
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.lowercased()
        for (index, box) in checkboxes.enumerated() {
            let canvas = canvases[index]
            let haystack = "\(canvas.name) \(canvas.location) \(canvas.group) \(canvas.product) \(canvas.tenant)".lowercased()
            box.isHidden = !query.isEmpty && !haystack.contains(query)
        }
    }

    var selectedJids: Set<String> {
        Set(checkboxes.enumerated().compactMap { index, box in
            box.state == .on ? canvases[index].jid : nil
        })
    }

    var selectedTargets: [CanvasTarget] {
        checkboxes.enumerated().compactMap { index, box in
            box.state == .on ? canvases[index].target : nil
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let client = VideriClient()
    private let workQueue = DispatchQueue(label: "sparksustain.work")
    private let pathMonitor = NWPathMonitor()
    private var networkDebounce: DispatchWorkItem?

    private var automationEnabled = true
    private var screensAwake = true
    private var lastApplied: Int?
    private var lastDeskPowerOK: Bool?
    /// Manual hold: while set (and not yet expired), this state wins over all
    /// automation. .distantFuture = until the user resumes automation.
    private var overrideUntil: Date?
    private var overridePercent = 0

    // MARK: Decision logic

    // Sparks are at wake brightness ONLY while the laptop is awake, on the
    // office network, AND (when a desk adapter is captured) drawing power
    // from that adapter. Everything else means sleep brightness.
    private func automaticPercent(_ config: Config) -> Int {
        (screensAwake && isOnOfficeNetwork(config) && isOnDeskPower(config))
            ? config.wake_brightness_percent
            : config.sleep_brightness_percent
    }

    /// True while a manual hold is in effect; expires itself when time is up.
    private func overrideActive() -> Bool {
        guard let until = overrideUntil else { return false }
        if Date() < until { return true }
        overrideUntil = nil
        log("Manual hold expired — automation resumed")
        return false
    }

    private func overrideLabel() -> String {
        guard let until = overrideUntil else { return "" }
        if until == .distantFuture { return "until automation resumes" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "until \(formatter.string(from: until))"
    }

    /// A manual hold takes priority over automation; otherwise the rules run.
    private func desiredPercent(_ config: Config) -> Int {
        overrideActive() ? overridePercent : automaticPercent(config)
    }

    // MARK: Launch

    /// One-time migration from the app's previous name (SparkSync).
    private func migrateFromSparkSync() {
        let oldDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SparkSync")
        guard !FileManager.default.fileExists(atPath: configURL.path),
              FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("config.json").path) else { return }
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        for file in ["config.json", "canvases.json"] {
            try? FileManager.default.copyItem(at: oldDir.appendingPathComponent(file),
                                              to: appSupportDir.appendingPathComponent(file))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: configURL.path)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        log("Migrated configuration from SparkSync")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateFromSparkSync()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(machineDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(machineWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self = self else { return }
            self.networkDebounce?.cancel()
            let work = DispatchWorkItem { self.reconcile(reason: "network changed") }
            self.networkDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
        pathMonitor.start(queue: DispatchQueue(label: "sparksustain.netmon"))
        registerHotKey()
        startControlRequestWatcher()

        // Power-source changes have no push notification, so poll cheaply:
        // act only when the desired state actually flips. Disconnecting the
        // desk power source darkens the Sparks within ~3 seconds.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, let config = loadConfig(), config.isFilledIn else { return }
            if config.desk_power != nil {
                let powerOK = isOnDeskPower(config)
                if powerOK != self.lastDeskPowerOK {
                    self.lastDeskPowerOK = powerOK
                    log("Desk power \(powerOK ? "connected" : "disconnected")")
                }
            }
            guard self.automationEnabled else { return }
            if self.desiredPercent(config) != self.lastApplied {
                self.reconcile(reason: "power source changed")
            }
        }

        // Perpetual enforcement: re-assert the desired state every 10 minutes
        // to heal outside drift (device reboot, portal changes, missed
        // commands while offline).
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self = self, self.automationEnabled,
                  loadConfig()?.isFilledIn == true else { return }
            self.reconcile(reason: "periodic state enforcement", force: true)
        }

        // Auto-update: check shortly after launch, then every 4 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.checkForUpdates(interactive: false)
        }
        Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(interactive: false)
        }

        log("SparkSustain started (v\(appVersion))")
        if let config = loadConfig(), config.isFilledIn {
            reconcile(reason: "app launch")
            if config.schedules_overridden == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.offerScheduleOverride()
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.runSetupAssistant()
            }
        }
    }

    // MARK: Setup Assistant

    @objc func runSetupAssistant() {
        NSApp.activate(ignoringOtherApps: true)
        var config = loadConfig() ?? Config.template

        // -- Step 1: welcome + API key -------------------------------------
        while true {
            let welcome = NSAlert()
            welcome.messageText = "Set up SparkSustain"
            welcome.informativeText = """
            SparkSustain makes the Sparks near your desk follow this Mac: awake at \
            the office → screens on; asleep or away → screens dark.

            You'll need one thing before we start: a Videri developer API key.

            Get it at developer.videri.com/dashboard (API Keys tab) — copy the key \
            right away, it's shown only once. Have your developer username and \
            password ready too.
            """
            welcome.addButton(withTitle: "I Have My API Key")
            welcome.addButton(withTitle: "Open API Keys Page")
            welcome.addButton(withTitle: "Later")
            let response = welcome.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://developer.videri.com/dashboard")!)
                continue
            }
            if response == .alertThirdButtonReturn {
                statusLine = "Setup not finished — run the Setup Assistant from this menu"
                rebuildMenu()
                return
            }
            break
        }

        // -- Step 2: credentials (validated live) --------------------------
        let userField = NSTextField(frame: .zero)
        userField.placeholderString = "you@videri.com"
        userField.stringValue = config.username
        let passField = NSSecureTextField(frame: .zero)
        passField.placeholderString = "developer account password"
        let keyField = NSTextField(frame: .zero)
        keyField.placeholderString = "paste your API key"
        keyField.stringValue = config.api_key
        for field in [userField, passField, keyField] {
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Username"), userField],
            [NSTextField(labelWithString: "Password"), passField],
            [NSTextField(labelWithString: "API key"), keyField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        while true {
            let credentials = NSAlert()
            credentials.messageText = "Pair your API key"
            credentials.informativeText = "These are saved only on this Mac, in a file readable only by you."
            credentials.accessoryView = grid
            credentials.addButton(withTitle: "Verify & Continue")
            credentials.addButton(withTitle: "Cancel")
            credentials.window.initialFirstResponder = userField
            guard credentials.runModal() == .alertFirstButtonReturn else {
                statusLine = "Setup not finished — run the Setup Assistant from this menu"
                rebuildMenu()
                return
            }
            config.username = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.password = passField.stringValue
            config.api_key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard config.hasCredentials else { continue }
            do {
                try client.validateCredentials(config)
                saveConfig(config)
                log("Setup: credentials verified for \(config.username)")
                break
            } catch {
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = "Couldn't sign in"
                failed.informativeText = "\(error)"
                failed.addButton(withTitle: "Try Again")
                failed.runModal()
            }
        }

        // -- Step 2b: choose workspaces (tree, with sub-workspaces) --------
        if let allWorkspaces = try? client.allTokenTenants(config) {
            statusLine = "Loading workspace tree…"
            rebuildMenu()
            var rows: [WorkspaceTreeView.Row] = []
            for tenant in allWorkspaces {
                rows.append(WorkspaceTreeView.Row(tenant: tenant, uuid: nil,
                                                  title: tenant, depth: 0))
                if let tree = try? client.fetchGroupTree(config: config, tenant: tenant) {
                    func add(_ nodes: [VideriClient.GroupNode], _ depth: Int) {
                        for node in nodes {
                            rows.append(WorkspaceTreeView.Row(tenant: tenant, uuid: node.uuid,
                                                              title: node.name, depth: depth))
                            add(node.children, depth + 1)
                        }
                    }
                    add(tree, 1)
                }
            }
            let selectedTenants = Set((config.workspaces ?? []).filter {
                (config.workspace_groups?[$0] ?? []).isEmpty
            })
            let selectedGroups = Set((config.workspace_groups ?? [:]).values.flatMap { $0 })
            if rows.count == 1 {
                config.workspaces = allWorkspaces
                config.workspace_groups = [:]
                saveConfig(config)
            } else {
                let treeView = WorkspaceTreeView(rows: rows,
                                                 selectedTenants: selectedTenants,
                                                 selectedGroups: selectedGroups)
                while true {
                    let pick = NSAlert()
                    pick.messageText = "Choose your workspaces"
                    pick.informativeText = """
                    SparkSustain will only show — and only ever control — displays \
                    in what you check. Check a workspace to include everything \
                    inside it, or check just the sub-workspaces you need. Most \
                    people need a single sub-workspace.
                    """
                    pick.accessoryView = treeView
                    pick.addButton(withTitle: "Continue")
                    pick.addButton(withTitle: "Cancel")
                    guard pick.runModal() == .alertFirstButtonReturn else {
                        statusLine = "Setup not finished — run the Setup Assistant from this menu"
                        rebuildMenu()
                        return
                    }
                    if !treeView.hasAnySelection {
                        let empty = NSAlert()
                        empty.messageText = "Check at least one workspace or sub-workspace"
                        empty.runModal()
                        continue
                    }
                    break
                }
                let selection = treeView.selection
                config.workspaces = Array(selection.keys)
                config.workspace_groups = selection
                saveConfig(config)
                let summary = selection.map { tenant, groups in
                    groups.isEmpty ? tenant : "\(tenant) (\(groups.count) sub-workspaces)"
                }.joined(separator: ", ")
                log("Setup: workspaces scoped to \(summary)")
            }
        }

        // -- Step 3: pick Sparks ------------------------------------------
        let canvases: [CanvasInfo]
        do {
            canvases = try client.fetchCanvasList(config: config)
        } catch {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Couldn't load your canvases"
            failed.informativeText = "\(error)\n\nYour credentials are saved — run the Setup Assistant again from the menu to finish."
            failed.runModal()
            return
        }
        guard !canvases.isEmpty else {
            let none = NSAlert()
            none.messageText = "No canvases visible in the chosen workspaces"
            none.informativeText = "Pick different workspaces, or ask the platform team to grant access, then run the Setup Assistant again."
            none.runModal()
            return
        }
        let preselected = Set(config.canvases.map { $0.device_jid })
        let picker = CanvasPickerView(canvases: canvases, preselected: preselected)
        while true {
            let pick = NSAlert()
            pick.messageText = "Pick the Sparks near your desk"
            pick.informativeText = "Check the canvases SparkSustain should control. Online canvases are listed first."
            pick.accessoryView = picker
            pick.addButton(withTitle: "Continue")
            pick.addButton(withTitle: "Cancel")
            guard pick.runModal() == .alertFirstButtonReturn else {
                statusLine = "Setup not finished — run the Setup Assistant from this menu"
                rebuildMenu()
                return
            }
            if picker.selectedTargets.isEmpty {
                let empty = NSAlert()
                empty.messageText = "Nothing selected"
                empty.informativeText = "Check at least one Spark to continue."
                empty.runModal()
                continue
            }
            break
        }
        config.canvases = picker.selectedTargets
        config.schedules_overridden = nil   // new selection → warn again below
        saveConfig(config)
        log("Setup: selected \(config.canvases.count) canvases")

        // -- Step 4: brightness schedule takeover ---------------------------
        offerScheduleOverride()
        config = loadConfig() ?? config

        // -- Step 5: office network -----------------------------------------
        let prefixes = currentSubnetPrefixes()
        let network = NSAlert()
        network.messageText = "Are you at the office right now?"
        network.informativeText = prefixes.isEmpty
            ? "No active network detected. Skip for now and use “Set Current Network as Office” from the menu when you're at your desk."
            : """
            SparkSustain will remember this network (\(prefixes.joined(separator: ", "))*) as the \
            office. Brightness only comes up when this Mac is on it.

            If you're not at the office, skip this and use “Set Current Network \
            as Office” from the menu when you're at your desk.
            """
        if !prefixes.isEmpty {
            network.addButton(withTitle: "Yes — Remember This Network")
            network.addButton(withTitle: "Not Now")
            if network.runModal() == .alertFirstButtonReturn {
                config.office_network_prefixes = prefixes
                saveConfig(config)
                log("Setup: office network set to \(prefixes.joined(separator: ", "))")
            }
        } else {
            network.runModal()
        }

        // -- Step 6: desk power source (optional wake requirement) ----------
        while true {
            let adapter = currentPowerAdapter()
            let power = NSAlert()
            if adapter.connected {
                let candidate = DeskPower(watts: adapter.watts,
                                          vendor_id: adapter.vendor,
                                          product_id: adapter.product)
                power.messageText = "Require your desk power source?"
                power.informativeText = """
                Your Mac is currently drawing from: \(candidate.label).

                If you require it, your Sparks only light up while plugged \
                into this exact source — on battery, MagSafe, or any other \
                charger they stay dark, even on the office network.

                You'll be asked to unplug and reconnect once so SparkSustain \
                can verify it detects the change.
                """
                power.addButton(withTitle: "Require This Power Source")
                power.addButton(withTitle: "Skip — Decide Later")
                if power.runModal() == .alertFirstButtonReturn {
                    config.desk_power = candidate
                    saveConfig(config)
                    log("Setup: desk power requirement set to \(candidate.label)")
                    verifyDeskSignature(config)
                }
                break
            } else {
                power.messageText = "Desk power source (optional)"
                power.informativeText = """
                No external power detected right now.

                To make your desk charger or dock a wake requirement, connect \
                it and click “Detect Now” — or decide later via “Require \
                Current Power Source (Desk)” in the menu.
                """
                power.addButton(withTitle: "Detect Now")
                power.addButton(withTitle: "Decide Later")
                if power.runModal() == .alertFirstButtonReturn {
                    continue
                }
                break
            }
        }

        // -- Step 7: start at login + first sync ----------------------------
        let finish = NSAlert()
        finish.messageText = "You're set"
        finish.informativeText = "SparkSustain will start automatically at login and sync your Sparks now."
        let loginBox = NSButton(checkboxWithTitle: "Start SparkSustain at login", target: nil, action: nil)
        loginBox.state = .on
        finish.accessoryView = loginBox
        finish.addButton(withTitle: "Finish & Sync Now")
        finish.runModal()
        if loginBox.state == .on, SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() }
            catch { log("Login item registration failed: \(error)") }
        }
        lastApplied = nil
        reconcile(reason: "setup finished")
    }

    // MARK: Desk signature verification

    /// Prove the desk signature actually tracks presence: the user unplugs
    /// (or powers off) the desk source and we confirm it disappears, then
    /// reconnects and we confirm it returns. Catches anchors that linger
    /// (e.g. a monitor that stays "connected" while powered off).
    private func verifyDeskSignature(_ config: Config) {
        NSApp.activate(ignoringOtherApps: true)
        // Phase 1: absence
        while true {
            let alert = NSAlert()
            alert.messageText = "Verify: disconnect your desk power"
            alert.informativeText = """
            To confirm SparkSustain can tell when you leave your desk, unplug \
            the desk power source now (or power off the monitor/dock that \
            supplies it), then click Check.
            """
            alert.addButton(withTitle: "Check")
            alert.addButton(withTitle: "Skip Verification")
            guard alert.runModal() == .alertFirstButtonReturn else {
                log("Desk verification skipped")
                return
            }
            if !isOnDeskPower(config) { break }
            let still = NSAlert()
            still.alertStyle = .warning
            still.messageText = "Still detecting your desk power"
            still.informativeText = """
            The Mac still reports the same power source. If you really \
            disconnected it, this source doesn't reflect your presence and \
            the automation won't notice you leaving — pick a different \
            source, or skip.
            """
            still.addButton(withTitle: "Check Again")
            still.addButton(withTitle: "Skip Verification")
            if still.runModal() != .alertFirstButtonReturn {
                log("Desk verification abandoned (disconnect not detected)")
                return
            }
        }
        log("Desk verification: disconnect detected")
        // Phase 2: return
        while true {
            let alert = NSAlert()
            alert.messageText = "Now reconnect your desk power"
            alert.informativeText = "Plug the desk power source back in, then click Check."
            alert.addButton(withTitle: "Check")
            alert.addButton(withTitle: "Skip")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if isOnDeskPower(config) {
                log("Desk verification: reconnect detected — signature verified")
                let done = NSAlert()
                done.messageText = "Verified"
                done.informativeText = """
                SparkSustain reliably detects when you're at your desk. \
                Disconnecting this power source will darken your Sparks \
                within a few seconds.
                """
                done.runModal()
                return
            }
        }
    }

    // MARK: Brightness schedule override

    private func offerScheduleOverride() {
        guard var config = loadConfig(), config.isFilledIn else { return }
        NSApp.activate(ignoringOtherApps: true)
        let count = config.readyTargets.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SparkSustain will take over brightness control"
        alert.informativeText = """
        Any existing brightness schedules on the \(count) display\(count == 1 ? "" : "s") \
        SparkSustain manages will be permanently DELETED from the Videri \
        platform, so they can't fight SparkSustain's on/off control. \
        This cannot be undone.

        The \(count == 1 ? "display" : "displays") will then default to 0% \
        brightness / display off, and only light up while your MacBook meets \
        the wake conditions (awake, on the office network, and on desk power \
        if required).

        Other displays are not affected.
        """
        alert.addButton(withTitle: "Delete Schedules & Continue")
        alert.addButton(withTitle: "Keep Schedules")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        config.schedules_overridden = accepted
        saveConfig(config)
        guard accepted else {
            statusLine = "Existing brightness schedules kept — they may override SparkSustain"
            log(statusLine)
            rebuildMenu()
            return
        }
        statusLine = "Deleting existing brightness schedules…"
        rebuildMenu()
        workQueue.async {
            do {
                let message = try self.client.deleteBrightnessSchedules(config: config)
                self.statusLine = message
                log("Schedule override: \(message)")
            } catch {
                self.statusLine = "Schedule deletion failed: \(error)"
                log(self.statusLine)
            }
            // New default for managed displays: 0% / display off. The normal
            // reconcile immediately raises them again if the Mac currently
            // meets the wake conditions.
            do {
                _ = try self.client.setBrightness(percent: config.sleep_brightness_percent,
                                                  config: config)
                self.lastApplied = config.sleep_brightness_percent
                writeControlState(on: false)
                log("Takeover baseline applied: managed displays defaulted to 0%/off")
            } catch {
                log("Takeover baseline failed: \(error)")
            }
            DispatchQueue.main.async {
                self.rebuildMenu()
                self.reconcile(reason: "post-takeover baseline")
            }
        }
    }

    // MARK: Control Center control bridge

    private var lastControlRequestStamp: TimeInterval = 0

    private func startControlRequestWatcher() {
        let url = sharedControlDir.appendingPathComponent("control-request.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lastControlRequestStamp = json["requested_at"] as? TimeInterval ?? 0
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = json["requested_at"] as? TimeInterval,
                  stamp > self.lastControlRequestStamp,
                  let on = json["on"] as? Bool else { return }
            self.lastControlRequestStamp = stamp
            log("Control Center request -> \(on ? "on" : "off")")
            self.manualToggle(toOn: on)
        }
    }

    // MARK: Global hotkey (⌃⌥S)

    @objc func toggleSparksFromHotkey() {
        let currentlyOn = (lastApplied ?? 0) > 0
        log("Hotkey toggle -> \(currentlyOn ? "off" : "on")")
        manualToggle(toOn: !currentlyOn)
    }

    private var hotKeyRef: EventHotKeyRef?

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleSparksFromHotkey() }
            return noErr
        }, 1, &eventType, selfPtr, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x53_50_4B_53), id: 1)  // 'SPKS'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_S),
                                         UInt32(controlKey | optionKey),
                                         hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        log(status == noErr ? "Registered global hotkey ⌃⌥S"
                            : "Hotkey registration failed (\(status))")
    }

    // MARK: Sleep/wake events

    @objc private func screensDidWake() { screensAwake = true; reconcile(reason: "screens woke") }
    @objc private func machineDidWake() { screensAwake = true; reconcile(reason: "system woke") }
    @objc private func screensDidSleep() { screensAwake = false; reconcile(reason: "screens slept") }

    @objc private func machineWillSleep() {
        // Run synchronously: macOS holds sleep briefly for apps handling
        // willSleep, so a fast request usually completes before power-down.
        screensAwake = false
        guard automationEnabled, let config = loadConfig(), config.isFilledIn else { return }
        let percent = desiredPercent(config)   // a manual hold survives sleep
        guard lastApplied != percent else { return }
        do {
            _ = try client.setBrightness(percent: percent, config: config)
            lastApplied = percent
            writeControlState(on: percent > 0)
            log("Applied \(percent)% before system sleep")
        } catch {
            log("Failed to apply brightness on willSleep: \(error)")
        }
    }

    // MARK: Reconcile

    private var statusLine = "Waiting for first event"

    /// Compare desired state with what was last sent; send only on change
    /// (or always, when force re-asserts the state to heal outside drift).
    private func reconcile(reason: String, force: Bool = false) {
        guard automationEnabled else {
            log("Automation paused — ignoring \(reason)")
            return
        }
        guard let config = loadConfig(), config.isFilledIn else {
            statusLine = "Setup needed — run the Setup Assistant"
            DispatchQueue.main.async { self.rebuildMenu() }
            return
        }
        let inOffice = isOnOfficeNetwork(config)
        let percent = desiredPercent(config)
        DispatchQueue.main.async {
            self.updateIcon()
            self.rebuildMenu()
        }
        guard force || lastApplied != percent else { return }
        statusLine = "\(stateLabel(inOffice: inOffice)) — applying \(percent)%…"
        workQueue.async {
            do {
                let message = try self.client.setBrightness(percent: percent, config: config)
                self.lastApplied = percent
                writeControlState(on: percent > 0)
                self.statusLine = "\(self.stateLabel(inOffice: inOffice)) — \(message) (\(reason))"
            } catch {
                self.statusLine = "Failed: \(error)"
                log("reconcile error (\(reason)): \(error)")
            }
            DispatchQueue.main.async { self.rebuildMenu() }
        }
    }

    private func stateLabel(inOffice: Bool) -> String {
        if let until = overrideUntil, Date() < until {
            return "Manual hold: \(overridePercent)% \(overrideLabel())"
        }
        let base: String
        switch (screensAwake, inOffice) {
        case (true, true): base = "Awake at office"
        case (true, false): base = "Awake, away from office"
        case (false, true): base = "Asleep at office"
        case (false, false): base = "Asleep, away"
        }
        if screensAwake, inOffice, let config = loadConfig(),
           config.desk_power != nil, !isOnDeskPower(config) {
            return base + ", off desk power"
        }
        return base
    }

    // MARK: Manual holds

    /// Pin a state for a duration; automation enforces the hold, then
    /// resumes its own rules when it expires. nil seconds = indefinite.
    private func manualHold(percent: Int, seconds: TimeInterval?) {
        guard let config = loadConfig(), config.isFilledIn else {
            statusLine = "Setup needed — run the Setup Assistant"
            rebuildMenu()
            return
        }
        _ = config
        overridePercent = percent
        overrideUntil = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        log("Manual hold: \(percent)% \(overrideLabel())")
        lastApplied = nil
        reconcile(reason: "manual hold", force: true)
    }

    @objc private func resumeAutomation() {
        overrideUntil = nil
        log("Manual hold cleared — automation resumed")
        lastApplied = nil
        reconcile(reason: "automation resumed", force: true)
    }

    private static func secondsUntilEndOfDay() -> TimeInterval {
        let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        return max(60, midnight.timeIntervalSinceNow)
    }

    @objc private func holdSelected(_ sender: NSMenuItem) {
        // tag encodes percent * 1_000_000 + duration code
        let percent = sender.tag / 1_000_000
        let code = sender.tag % 1_000_000
        let seconds: TimeInterval?
        switch code {
        case 1: seconds = 1800
        case 2: seconds = 3600
        case 3: seconds = 7200
        case 4: seconds = AppDelegate.secondsUntilEndOfDay()
        default: seconds = nil
        }
        manualHold(percent: percent, seconds: seconds)
    }

    /// Manual toggle (hotkey / Control Center): hold the flipped state for
    /// the configured default duration.
    private func manualToggle(toOn: Bool) {
        guard let config = loadConfig(), config.isFilledIn else {
            statusLine = "Setup needed — run the Setup Assistant"
            rebuildMenu()
            return
        }
        let percent = toOn ? config.wake_brightness_percent : config.sleep_brightness_percent
        let minutes = config.default_override_minutes ?? 60
        manualHold(percent: percent, seconds: TimeInterval(minutes * 60))
    }

    // MARK: Menu

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let config = loadConfig() ?? Config.template
        let on: Bool
        if let until = overrideUntil, Date() < until {
            on = overridePercent > 0
        } else {
            on = screensAwake && isOnOfficeNetwork(config) && isOnDeskPower(config)
        }
        let symbol: String
        let fallback: String
        if !screensAwake {
            symbol = "moon.fill"; fallback = "🌙"
        } else if on {
            symbol = "sun.max.fill"; fallback = "☀️"
        } else {
            symbol = "location.slash"; fallback = "🚫"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SparkSustain") {
            button.image = image
            button.title = ""
        } else {
            button.title = fallback
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let config = loadConfig() ?? Config.template
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let prefixes = config.officePrefixes
        let networkTitle: String
        if prefixes.isEmpty {
            networkTitle = "Office network: not set (automating everywhere)"
        } else {
            let here = isOnOfficeNetwork(config) ? "connected" : "away"
            networkTitle = "Office network: \(prefixes.joined(separator: ", "))* (\(here))"
        }
        let networkStatus = NSMenuItem(title: networkTitle, action: nil, keyEquivalent: "")
        networkStatus.isEnabled = false
        menu.addItem(networkStatus)

        let powerTitle: String
        if let desk = config.desk_power {
            let here = isOnDeskPower(config) ? "connected" : "not connected"
            powerTitle = "Desk power: \(desk.label) (\(here))"
        } else {
            powerTitle = "Desk power: not required"
        }
        let powerStatus = NSMenuItem(title: powerTitle, action: nil, keyEquivalent: "")
        powerStatus.isEnabled = false
        menu.addItem(powerStatus)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Automation Enabled",
                                action: #selector(toggleAutomation), keyEquivalent: "")
        toggle.state = automationEnabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        if let until = overrideUntil, Date() < until {
            let holdStatus = NSMenuItem(
                title: "Manual hold: \(overridePercent)% \(overrideLabel())",
                action: nil, keyEquivalent: "")
            holdStatus.isEnabled = false
            menu.addItem(holdStatus)
            menu.addItem(makeItem("Resume Automation Now", #selector(resumeAutomation)))
            menu.addItem(.separator())
        }

        // Manual holds: pin a state for a chosen time; automation enforces
        // the hold, then takes back over when it expires.
        let durations: [(String, Int)] = [
            ("For 30 Minutes", 1), ("For 1 Hour", 2), ("For 2 Hours", 3),
            ("Until End of Day", 4), ("Until Automation Resumes", 5),
        ]
        func holdSubmenu(title: String, percent: Int) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for (label, code) in durations {
                let item = NSMenuItem(title: label, action: #selector(holdSelected(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = percent * 1_000_000 + code
                sub.addItem(item)
            }
            parent.submenu = sub
            return parent
        }
        menu.addItem(holdSubmenu(title: "Hold Wake Brightness (\(config.wake_brightness_percent)%)",
                                 percent: config.wake_brightness_percent))
        menu.addItem(holdSubmenu(title: "Hold Screens Off (\(config.sleep_brightness_percent)%)",
                                 percent: config.sleep_brightness_percent))

        let wakeLevel = NSMenuItem(title: "Wake Brightness", action: nil, keyEquivalent: "")
        let wakeLevelMenu = NSMenu(title: "Wake Brightness")
        for percent in stride(from: 10, through: 100, by: 10) {
            let item = NSMenuItem(title: "\(percent)%",
                                  action: #selector(wakePercentSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = (percent == config.wake_brightness_percent) ? .on : .off
            wakeLevelMenu.addItem(item)
        }
        wakeLevel.submenu = wakeLevelMenu
        menu.addItem(wakeLevel)

        let hotkeyHint = NSMenuItem(title: "Toggle Sparks anywhere: ⌃⌥S", action: nil, keyEquivalent: "")
        hotkeyHint.isEnabled = false
        menu.addItem(hotkeyHint)
        menu.addItem(.separator())
        menu.addItem(makeItem("Run Setup Assistant…", #selector(setupFromMenu)))
        menu.addItem(makeItem("Set Current Network as Office", #selector(captureOfficeNetwork)))
        let deskItem = makeItem(config.desk_power == nil
                                    ? "Require Current Power Source (Desk)"
                                    : "Stop Requiring Desk Power",
                                #selector(toggleDeskPower))
        deskItem.state = config.desk_power == nil ? .off : .on
        menu.addItem(deskItem)
        menu.addItem(makeItem("Discover Canvases…", #selector(discover)))
        menu.addItem(makeItem("Help", #selector(openManual)))
        menu.addItem(makeItem("View Log", #selector(viewLog)))
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "SparkSustain v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(makeItem("Check for Updates Now", #selector(checkForUpdatesNow)))
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit SparkSustain", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Updates

    /// Compare the GitHub-hosted manifest against the running version and
    /// install when they differ (upgrades AND rollbacks). Network and
    /// download happen off the main thread.
    private func checkForUpdates(interactive: Bool) {
        let config = loadConfig() ?? Config.template
        let manifestURL = config.update_url ?? defaultUpdateManifestURL
        workQueue.async {
            guard let manifest = Updater.fetchManifest(from: manifestURL) else {
                if interactive {
                    self.statusLine = "Couldn't reach the update feed (offline, or the repo is private)"
                    DispatchQueue.main.async { self.rebuildMenu() }
                }
                return
            }
            guard manifest.version != appVersion else {
                if interactive {
                    self.statusLine = "Up to date (v\(appVersion))"
                    DispatchQueue.main.async { self.rebuildMenu() }
                }
                return
            }
            log("Update available: v\(manifest.version) (running v\(appVersion))")
            self.statusLine = "Installing v\(manifest.version)…"
            DispatchQueue.main.async { self.rebuildMenu() }
            if let problem = Updater.applyUpdate(manifest: manifest) {
                self.statusLine = problem
                log("Update failed: \(problem)")
                DispatchQueue.main.async { self.rebuildMenu() }
            }
            // On success the app relaunches itself.
        }
    }

    @objc private func checkForUpdatesNow() { checkForUpdates(interactive: true) }

    // MARK: Menu actions

    @objc private func setupFromMenu() { runSetupAssistant() }

    @objc private func toggleAutomation() {
        automationEnabled.toggle()
        statusLine = automationEnabled ? "Automation resumed" : "Automation paused"
        log(statusLine)
        rebuildMenu()
        if automationEnabled { reconcile(reason: "automation resumed") }
    }

    @objc private func captureOfficeNetwork() {
        let prefixes = currentSubnetPrefixes()
        guard !prefixes.isEmpty else {
            statusLine = "No active IPv4 network found — connect to the office network first"
            rebuildMenu()
            return
        }
        guard var config = loadConfig() else {
            statusLine = "Run the Setup Assistant first"
            rebuildMenu()
            return
        }
        config.office_network_prefixes = prefixes
        saveConfig(config)
        statusLine = "Office network set to \(prefixes.joined(separator: ", "))*"
        log(statusLine)
        rebuildMenu()
        reconcile(reason: "office network captured")
    }

    /// Capture the current adapter as the desk-power requirement (and verify
    /// it), or clear it.
    @objc private func toggleDeskPower() {
        guard var config = loadConfig() else { return }
        if config.desk_power != nil {
            config.desk_power = nil
            saveConfig(config)
            statusLine = "Desk power requirement cleared"
        } else {
            let adapter = currentPowerAdapter()
            guard adapter.connected else {
                statusLine = "Plug into your desk power source first"
                rebuildMenu()
                return
            }
            config.desk_power = DeskPower(watts: adapter.watts,
                                          vendor_id: adapter.vendor,
                                          product_id: adapter.product)
            saveConfig(config)
            statusLine = "Desk power set to \(config.desk_power!.label)"
            log(statusLine)
            verifyDeskSignature(config)
        }
        log(statusLine)
        rebuildMenu()
        reconcile(reason: "desk power requirement changed")
    }

    @objc private func wakePercentSelected(_ sender: NSMenuItem) {
        guard var config = loadConfig() else { return }
        config.wake_brightness_percent = sender.tag
        saveConfig(config)
        log("Wake brightness set to \(sender.tag)%")
        lastApplied = nil
        reconcile(reason: "wake brightness changed to \(sender.tag)%")
    }

    @objc private func discover() {
        guard let config = loadConfig(), config.hasCredentials else {
            statusLine = "Run the Setup Assistant first"
            rebuildMenu()
            return
        }
        statusLine = "Discovering canvases…"
        rebuildMenu()
        workQueue.async {
            do {
                let message = try self.client.discoverCanvases(config: config)
                self.statusLine = message
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(canvasesURL)
                }
            } catch {
                self.statusLine = "Discovery failed: \(error)"
                log("Discovery failed: \(error)")
            }
            DispatchQueue.main.async { self.rebuildMenu() }
        }
    }

    /// Open the bundled instruction manual in the default browser.
    @objc private func openManual() {
        guard let manual = Bundle.main.url(forResource: "Manual", withExtension: "html") else {
            statusLine = "Manual not found in app bundle"
            rebuildMenu()
            return
        }
        NSWorkspace.shared.open(manual)
    }

    @objc private func viewLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(logURL)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            statusLine = "Login item change failed: \(error.localizedDescription)"
            log(statusLine)
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// An accessory app has no menu bar, so ⌘V/⌘C/⌘X/⌘A do nothing in the Setup
// Assistant's fields by default. A minimal main menu with a standard Edit
// menu restores the keyboard shortcuts (it stays invisible for a menu bar app).
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
appMenuItem.submenu = NSMenu()
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
