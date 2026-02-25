import Foundation
import Security

// MARK: - AgentService

@MainActor
class AgentService: ObservableObject {

    // MARK: - Published

    @Published var messages:   [AgentMessage] = []
    @Published var isLoading:  Bool = false
    @Published var hasAPIKey:  Bool = false

    // MARK: - Dependencies (weak to avoid retain cycles with DataService)

    private let tagEngine:      TagEngine
    private let alarmManager:   AlarmManager
    private let hmiScreenStore: HMIScreenStore
    private let opcuaService:   OPCUAClientService

    /// Set by MainView.onAppear — lets tools switch tabs.
    var navigateToTab: ((Tab) -> Void)?

    // MARK: - Conversation (rolling window, 40 messages max)

    private var conversationHistory: [APIMessage] = []
    private let maxHistory = 40

    // MARK: - Constants

    private let apiURL   = URL(string: "https://api.anthropic.com/v1/messages")!
    private let modelID  = "claude-sonnet-4-6"
    private let maxTokens = 4096
    private let maxAgentLoopIterations = 20

    // MARK: - Keychain

    private let keychainService = "com.industrialhmi.agent"
    private let keychainAccount = "anthropic-api-key"

    // MARK: - Init

    init(tagEngine:      TagEngine,
         alarmManager:   AlarmManager,
         hmiScreenStore: HMIScreenStore,
         opcuaService:   OPCUAClientService) {
        self.tagEngine      = tagEngine
        self.alarmManager   = alarmManager
        self.hmiScreenStore = hmiScreenStore
        self.opcuaService   = opcuaService
        self.hasAPIKey      = loadAPIKey() != nil
    }

    // MARK: - Keychain

    func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        // Remove existing entry first (avoids errSecDuplicateItem)
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    keychainService,
            kSecAttrAccount:    keychainAccount,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        hasAPIKey = (status == errSecSuccess)
    }

    func loadAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key  = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        hasAPIKey = false
    }

    // MARK: - Public entry point

    func sendMessage(text: String, imageBase64: String? = nil) async {
        guard !isLoading else { return }
        guard let apiKey = loadAPIKey() else {
            appendUI(.error("No API key configured. Enter your Anthropic API key above."))
            return
        }

        isLoading = true
        appendUI(.user(text: text, imageBase64: imageBase64))

        // Build user content blocks
        var userBlocks: [ContentBlock] = []
        if let b64 = imageBase64 {
            userBlocks.append(.image(ImageBlock(
                source: ImageBlock.ImageSource(mediaType: "image/png", data: b64))))
        }
        userBlocks.append(.text(TextBlock(text: text)))
        appendToHistory(APIMessage(role: "user", content: userBlocks))

        await runAgentLoop(apiKey: apiKey)
        isLoading = false
    }

    // MARK: - Agentic Loop

    private func runAgentLoop(apiKey: String) async {
        var iterations = 0
        while iterations < maxAgentLoopIterations {
            iterations += 1
            let response: MessagesResponse
            do {
                response = try await callAPI(apiKey: apiKey)
            } catch {
                appendUI(.error("API error: \(error.localizedDescription)"))
                return
            }

            // Append assistant turn to history
            appendToHistory(APIMessage(role: "assistant", content: response.content))

            // Show text blocks in chat
            let textParts = response.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: "\n")
            if !textParts.isEmpty {
                appendUI(.assistant(text: textParts))
            }

            // Collect tool_use blocks
            let toolUseBlocks = response.content.compactMap { block -> ToolUseBlock? in
                if case .toolUse(let t) = block { return t }
                return nil
            }

            let stopReason = response.stopReason ?? "end_turn"
            if stopReason == "end_turn" || toolUseBlocks.isEmpty { break }

            // Execute tools, collect results
            var resultBlocks: [ContentBlock] = []
            for tu in toolUseBlocks {
                let summary = summarizeInput(tu.input)
                appendUI(.toolCall(toolName: tu.name, inputSummary: summary))

                let result = await executeTool(name: tu.name, input: tu.input)
                appendUI(.toolResult(toolName: tu.name,
                                     resultSummary: result.summary,
                                     isError: result.isError))

                resultBlocks.append(.toolResult(ToolResultBlock(
                    toolUseId: tu.id,
                    content:   result.json)))
            }
            appendToHistory(APIMessage(role: "user", content: resultBlocks))
        }
    }

    // MARK: - API Call

    private func callAPI(apiKey: String) async throws -> MessagesResponse {
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model":      modelID,
            "max_tokens": maxTokens,
            "system":     systemPrompt,
            "tools":      AgentTools.definitions,
            "messages":   encodeHistory()
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgentError.apiError(http.statusCode, body)
        }
        return try JSONDecoder().decode(MessagesResponse.self, from: data)
    }

    // MARK: - Tool Executor Dispatcher

    private struct ToolResult {
        let json:    String
        let summary: String
        let isError: Bool
    }

    private func executeTool(name: String, input: [String: AnyCodable]) async -> ToolResult {
        do {
            switch name {
            case "get_system_status":      return try toolGetSystemStatus()
            case "list_tags":              return try toolListTags(input: input)
            case "get_tag_detail":         return try toolGetTagDetail(input: input)
            case "update_tag_metadata":    return try toolUpdateTagMetadata(input: input)
            case "list_alarm_configs":     return try toolListAlarmConfigs()
            case "get_alarm_config":       return try toolGetAlarmConfig(input: input)
            case "create_alarm_config":    return try toolCreateAlarmConfig(input: input)
            case "update_alarm_config":    return try toolUpdateAlarmConfig(input: input)
            case "delete_alarm_config":    return try toolDeleteAlarmConfig(input: input)
            case "acknowledge_alarm":      return try toolAcknowledgeAlarm(input: input)
            case "acknowledge_all_alarms": return try toolAcknowledgeAllAlarms(input: input)
            case "list_hmi_objects":       return try toolListHMIObjects()
            case "create_hmi_object":      return try toolCreateHMIObject(input: input)
            case "update_hmi_object":      return try toolUpdateHMIObject(input: input)
            case "delete_hmi_object":      return try toolDeleteHMIObject(input: input)
            case "navigate_to_tab":        return try toolNavigateToTab(input: input)
            case "set_opcua_connection":   return try await toolSetOPCUAConnection(input: input)
            default:
                return err("Unknown tool: \(name)")
            }
        } catch {
            return err(error.localizedDescription)
        }
    }

    // MARK: - Tool Implementations

    private func toolGetSystemStatus() throws -> ToolResult {
        let d: [String: Any] = [
            "opcua_state":           opcuaService.connectionState.rawValue,
            "is_polling":            opcuaService.isPolling,
            "total_tags":            tagEngine.tagCount,
            "active_alarms":         alarmManager.activeAlarms.count,
            "unacknowledged_alarms": alarmManager.unacknowledgedCount,
            "alarm_configs":         alarmManager.alarmConfigs.count,
            "hmi_objects":           hmiScreenStore.screen.objects.count
        ]
        return ok(d, "OPC-UA: \(opcuaService.connectionState.rawValue), Tags: \(tagEngine.tagCount), Unack alarms: \(alarmManager.unacknowledgedCount)")
    }

    private func toolListTags(input: [String: AnyCodable]) throws -> ToolResult {
        var tags = tagEngine.getAllTags()
        if let qf = input["quality_filter"]?.value as? String, qf != "all" {
            let q: TagQuality = qf == "good" ? .good : qf == "bad" ? .bad : .uncertain
            tags = tags.filter { $0.quality == q }
        }
        if let search = input["search"]?.value as? String, !search.isEmpty {
            tags = tags.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                ($0.description?.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        let dicts = tags.map { tagToDict($0) }
        return ok(["tags": dicts, "count": dicts.count], "\(dicts.count) tag(s) found")
    }

    private func toolGetTagDetail(input: [String: AnyCodable]) throws -> ToolResult {
        guard let name = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        guard let tag  = tagEngine.getTag(named: name) else { throw AgentError.tagNotFound(name) }
        return ok(tagToDict(tag), "\(name) = \(tag.formattedValue) (\(tag.quality.description))")
    }

    private func toolUpdateTagMetadata(input: [String: AnyCodable]) throws -> ToolResult {
        guard let name = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        guard var tag  = tagEngine.tags[name] else { throw AgentError.tagNotFound(name) }
        var changed: [String] = []
        if let unit = strArg(input, "unit")        { tag.unit        = unit; changed.append("unit=\(unit)") }
        if let desc = strArg(input, "description") { tag.description = desc; changed.append("description set") }
        tagEngine.tags[name] = tag
        return ok(["updated": true, "tag": name], "Updated \(name): \(changed.joined(separator: ", "))")
    }

    private func toolListAlarmConfigs() throws -> ToolResult {
        let configs = alarmManager.alarmConfigs.map { alarmConfigToDict($0) }
        return ok(["configs": configs, "count": configs.count], "\(configs.count) alarm config(s)")
    }

    private func toolGetAlarmConfig(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        if let cfg = alarmManager.alarmConfigs.first(where: { $0.tagName == tagName }) {
            return ok(alarmConfigToDict(cfg), "Alarm config for \(tagName)")
        }
        return ok(["found": false, "tag_name": tagName], "No alarm config for \(tagName)")
    }

    private func toolCreateAlarmConfig(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        // Remove existing if present
        if let existing = alarmManager.alarmConfigs.first(where: { $0.tagName == tagName }) {
            alarmManager.removeAlarmConfig(existing)
        }
        let config = AlarmConfig(
            tagName:  tagName,
            highHigh: dblArg(input, "high_high"),
            high:     dblArg(input, "high"),
            low:      dblArg(input, "low"),
            lowLow:   dblArg(input, "low_low"),
            priority: priorityFromString(strArg(input, "priority")),
            deadband: dblArg(input, "deadband") ?? 0.5,
            enabled:  (input["enabled"]?.value as? Bool) ?? true
        )
        alarmManager.addAlarmConfig(config)
        return ok(alarmConfigToDict(config), "Created alarm config for \(tagName)")
    }

    private func toolUpdateAlarmConfig(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        guard var cfg = alarmManager.alarmConfigs.first(where: { $0.tagName == tagName }) else {
            throw AgentError.alarmConfigNotFound(tagName)
        }
        if let v = dblArg(input, "high_high") { cfg.highHigh = v }
        if let v = dblArg(input, "high")      { cfg.high     = v }
        if let v = dblArg(input, "low")       { cfg.low      = v }
        if let v = dblArg(input, "low_low")   { cfg.lowLow   = v }
        if let v = dblArg(input, "deadband")  { cfg.deadband = v }
        if let p = strArg(input, "priority")  { cfg.priority = priorityFromString(p) }
        if let e = input["enabled"]?.value as? Bool { cfg.enabled = e }
        alarmManager.updateAlarmConfig(cfg)
        return ok(alarmConfigToDict(cfg), "Updated alarm config for \(tagName)")
    }

    private func toolDeleteAlarmConfig(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        guard let cfg = alarmManager.alarmConfigs.first(where: { $0.tagName == tagName }) else {
            throw AgentError.alarmConfigNotFound(tagName)
        }
        alarmManager.removeAlarmConfig(cfg)
        return ok(["deleted": true, "tag_name": tagName], "Deleted alarm config for \(tagName)")
    }

    private func toolAcknowledgeAlarm(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        let by = strArg(input, "operator_name") ?? "AI Agent"
        guard let alarm = alarmManager.activeAlarms.first(where: {
            $0.tagName == tagName && $0.state.requiresAction
        }) else {
            return ok(["found": false], "No unacknowledged alarm for \(tagName)")
        }
        alarmManager.acknowledgeAlarm(alarm, by: by)
        return ok(["acknowledged": true, "tag_name": tagName, "by": by],
                  "Acknowledged alarm for \(tagName) by \(by)")
    }

    private func toolAcknowledgeAllAlarms(input: [String: AnyCodable]) throws -> ToolResult {
        let by    = strArg(input, "operator_name") ?? "AI Agent"
        let count = alarmManager.unacknowledgedCount
        alarmManager.acknowledgeAllAlarms(by: by)
        return ok(["acknowledged_count": count, "by": by],
                  "Acknowledged \(count) alarm(s) by \(by)")
    }

    private func toolListHMIObjects() throws -> ToolResult {
        let objects = hmiScreenStore.screen.objects.map { hmiObjectToDict($0) }
        return ok(["objects": objects, "count": objects.count,
                   "screen_name": hmiScreenStore.screen.name,
                   "canvas": "\(Int(hmiScreenStore.screen.canvasWidth))×\(Int(hmiScreenStore.screen.canvasHeight))"],
                  "\(objects.count) HMI object(s) on '\(hmiScreenStore.screen.name)'")
    }

    private func toolCreateHMIObject(input: [String: AnyCodable]) throws -> ToolResult {
        guard let typeStr = strArg(input, "type"),
              let objType = HMIObjectType(rawValue: typeStr)
        else { throw AgentError.missingParameter("type (rectangle/ellipse/textLabel/numericDisplay/levelBar)") }

        let x = dblArg(input, "x") ?? 100
        let y = dblArg(input, "y") ?? 100
        let w = dblArg(input, "width")  ?? objType.defaultSize.width
        let h = dblArg(input, "height") ?? objType.defaultSize.height

        var obj = HMIObject(type: objType, x: x, y: y)
        obj.width  = w
        obj.height = h

        if let fc = colorArg(input, "fill_color")   { obj.fillColor   = fc }
        if let sc = colorArg(input, "stroke_color") { obj.strokeColor = sc }
        if let t  = strArg(input, "static_text")    { obj.staticText  = t  }
        if let fs = dblArg(input, "font_size")      { obj.fontSize    = fs }
        if let fb = input["font_bold"]?.value as? Bool { obj.fontBold  = fb }
        if let dl = strArg(input, "designer_label") { obj.designerLabel = dl }

        if let bindingDict = input["tag_binding"]?.value as? [String: Any],
           let tagName = bindingDict["tag_name"] as? String {
            var binding = TagBinding(tagName: tagName)
            if let fmt  = bindingDict["number_format"] as? String { binding.numberFormat = fmt }
            if let unit = bindingDict["unit"] as? String          { binding.unit         = unit }
            obj.tagBinding = binding
        }

        hmiScreenStore.addObject(obj)
        return ok(["created": true, "id": obj.id.uuidString, "type": typeStr],
                  "Created \(objType.displayName) at (\(Int(x)),\(Int(y))) id=\(obj.id.uuidString.prefix(8))")
    }

    private func toolUpdateHMIObject(input: [String: AnyCodable]) throws -> ToolResult {
        // Locate by id or designer_label
        var target: HMIObject?
        if let idStr = strArg(input, "object_id"), let uuid = UUID(uuidString: idStr) {
            target = hmiScreenStore.screen.objects.first { $0.id == uuid }
        }
        if target == nil, let label = strArg(input, "designer_label") {
            target = hmiScreenStore.screen.objects.first { $0.designerLabel == label }
        }
        guard var obj = target else {
            throw AgentError.hmiObjectNotFound(strArg(input, "object_id") ?? strArg(input, "designer_label") ?? "?")
        }

        if let v = dblArg(input, "x")          { obj.x          = v }
        if let v = dblArg(input, "y")          { obj.y          = v }
        if let v = dblArg(input, "width")      { obj.width      = v }
        if let v = dblArg(input, "height")     { obj.height     = v }
        if let c = colorArg(input, "fill_color")   { obj.fillColor   = c }
        if let c = colorArg(input, "stroke_color") { obj.strokeColor = c }
        if let t = strArg(input, "static_text")    { obj.staticText  = t }
        if let v = dblArg(input, "font_size")      { obj.fontSize    = v }
        if let b = input["font_bold"]?.value as? Bool { obj.fontBold  = b }

        if let bindingDict = input["tag_binding"]?.value as? [String: Any],
           let tagName = bindingDict["tag_name"] as? String {
            var binding = obj.tagBinding ?? TagBinding(tagName: tagName)
            binding.tagName = tagName
            if let fmt  = bindingDict["number_format"] as? String { binding.numberFormat = fmt }
            if let unit = bindingDict["unit"] as? String          { binding.unit         = unit }
            obj.tagBinding = binding
        }

        hmiScreenStore.updateObject(obj)
        return ok(["updated": true, "id": obj.id.uuidString], "Updated HMI object \(obj.id.uuidString.prefix(8))")
    }

    private func toolDeleteHMIObject(input: [String: AnyCodable]) throws -> ToolResult {
        var target: HMIObject?
        if let idStr = strArg(input, "object_id"), let uuid = UUID(uuidString: idStr) {
            target = hmiScreenStore.screen.objects.first { $0.id == uuid }
        }
        if target == nil, let label = strArg(input, "designer_label") {
            target = hmiScreenStore.screen.objects.first { $0.designerLabel == label }
        }
        guard let obj = target else {
            throw AgentError.hmiObjectNotFound(strArg(input, "object_id") ?? "?")
        }
        hmiScreenStore.deleteObject(id: obj.id)
        return ok(["deleted": true, "id": obj.id.uuidString], "Deleted HMI object \(obj.id.uuidString.prefix(8))")
    }

    private func toolNavigateToTab(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tabStr = strArg(input, "tab") else { throw AgentError.missingParameter("tab") }
        let tab: Tab?
        switch tabStr {
        case "monitor":  tab = .monitor
        case "trends":   tab = .trends
        case "alarms":   tab = .alarms
        case "hmi":      tab = .hmi
        case "settings": tab = .settings
        case "agent":    tab = .agent
        default:         tab = nil
        }
        if let t = tab {
            navigateToTab?(t)
            return ok(["navigated_to": tabStr], "Navigated to \(tabStr)")
        } else {
            return err("Unknown tab: \(tabStr). Valid: monitor, trends, alarms, hmi, settings, agent")
        }
    }

    private func toolSetOPCUAConnection(input: [String: AnyCodable]) async throws -> ToolResult {
        guard let action = strArg(input, "action") else { throw AgentError.missingParameter("action") }
        switch action {
        case "connect":
            try await opcuaService.connect()
            return ok(["action": "connect", "state": opcuaService.connectionState.rawValue], "OPC-UA connect initiated")
        case "disconnect":
            await opcuaService.disconnect()
            return ok(["action": "disconnect"], "OPC-UA disconnected")
        case "start_polling":
            opcuaService.startPolling()
            return ok(["action": "start_polling", "is_polling": true], "Polling started")
        case "pause_polling":
            opcuaService.pausePolling()
            return ok(["action": "pause_polling", "is_polling": false], "Polling paused")
        default:
            return err("Unknown action: \(action). Valid: connect, disconnect, start_polling, pause_polling")
        }
    }

    // MARK: - History Management

    private func appendToHistory(_ message: APIMessage) {
        conversationHistory.append(message)
        // Trim to rolling window: remove from front in pairs (user+assistant)
        while conversationHistory.count > maxHistory {
            conversationHistory.removeFirst()
        }
    }

    private func encodeHistory() -> [[String: Any]] {
        // Strip image blocks from all turns except the most recent user message
        // to keep the payload manageable.
        let lastUserIdx = conversationHistory.indices.last {
            conversationHistory[$0].role == "user" &&
            conversationHistory[$0].content.contains { $0.isImage }
        }

        return conversationHistory.enumerated().compactMap { (i, msg) in
            var content = msg.content
            if let lastImg = lastUserIdx, i < lastImg {
                content = content.filter { !$0.isImage }
            }
            if content.isEmpty { return nil }
            guard let data = try? JSONEncoder().encode(APIMessage(role: msg.role, content: content)),
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    // MARK: - UI Helpers

    private func appendUI(_ kind: AgentMessageKind) {
        messages.append(AgentMessage(kind: kind))
    }

    // MARK: - Serialisation Helpers

    private struct ToolExecResult {
        let json:    String
        let summary: String
        let isError: Bool
    }

    private func ok(_ dict: [String: Any], _ summary: String) -> ToolResult {
        let json = (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolResult(json: json, summary: summary, isError: false)
    }

    private func err(_ message: String) -> ToolResult {
        let json = "{\"error\": \"\(message.replacingOccurrences(of: "\"", with: "'"))\"}"
        return ToolResult(json: json, summary: message, isError: true)
    }

    private func tagToDict(_ tag: Tag) -> [String: Any] {
        var d: [String: Any] = [
            "name":      tag.name,
            "node_id":   tag.nodeId,
            "quality":   tag.quality.description,
            "data_type": tag.dataType.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: tag.timestamp),
            "formatted": tag.formattedValue
        ]
        switch tag.value {
        case .analog(let v):  d["value"] = v
        case .digital(let v): d["value"] = v
        case .string(let v):  d["value"] = v
        case .none:           d["value"] = NSNull()
        }
        if let u = tag.unit        { d["unit"]        = u }
        if let s = tag.description { d["description"] = s }
        return d
    }

    private func alarmConfigToDict(_ c: AlarmConfig) -> [String: Any] {
        var d: [String: Any] = [
            "id":       c.id.uuidString,
            "tag_name": c.tagName,
            "deadband": c.deadband,
            "priority": c.priority.description,
            "enabled":  c.enabled
        ]
        if let v = c.highHigh { d["high_high"] = v }
        if let v = c.high     { d["high"]      = v }
        if let v = c.low      { d["low"]       = v }
        if let v = c.lowLow   { d["low_low"]   = v }
        return d
    }

    private func hmiObjectToDict(_ o: HMIObject) -> [String: Any] {
        var d: [String: Any] = [
            "id":             o.id.uuidString,
            "type":           o.type.rawValue,
            "x":              o.x, "y": o.y,
            "width":          o.width, "height": o.height,
            "designer_label": o.designerLabel,
            "static_text":    o.staticText
        ]
        if let b = o.tagBinding {
            d["tag_binding"] = ["tag_name": b.tagName,
                                "number_format": b.numberFormat,
                                "unit": b.unit]
        }
        return d
    }

    // MARK: - Argument Extractors

    private func strArg(_ input: [String: AnyCodable], _ key: String) -> String? {
        input[key]?.value as? String
    }

    private func dblArg(_ input: [String: AnyCodable], _ key: String) -> Double? {
        if let d = input[key]?.value as? Double { return d }
        if let i = input[key]?.value as? Int    { return Double(i) }
        return nil
    }

    private func colorArg(_ input: [String: AnyCodable], _ key: String) -> CodableColor? {
        guard let dict = input[key]?.value as? [String: Any] else { return nil }
        let r = dict["r"] as? Double ?? 0.5
        let g = dict["g"] as? Double ?? 0.5
        let b = dict["b"] as? Double ?? 0.5
        let a = dict["a"] as? Double ?? 1.0
        return CodableColor(r: r, g: g, b: b, a: a)
    }

    private func priorityFromString(_ s: String?) -> AlarmPriority {
        switch s {
        case "low":      return .low
        case "high":     return .high
        case "critical": return .critical
        default:         return .medium
        }
    }

    private func summarizeInput(_ input: [String: AnyCodable]) -> String {
        input.sorted { $0.key < $1.key }
            .compactMap { k, v -> String? in
                switch v.value {
                case let s as String: return "\(k): \(s)"
                case let d as Double: return "\(k): \(d)"
                case let b as Bool:   return "\(k): \(b)"
                default:              return nil
                }
            }
            .prefix(3)
            .joined(separator: ", ")
    }

    // MARK: - System Prompt

    private let systemPrompt = """
    You are an AI assistant embedded in an industrial SCADA/HMI application called "Industrial HMI". \
    You have direct access to the running system through tools.

    ## Your Capabilities
    - Query real-time tag values, connection status, alarm states, and system statistics
    - Configure alarm setpoints (high-high/critical, high/warning, low/warning, low-low/critical, deadband, priority)
    - Update tag metadata: engineering units and descriptions
    - Design and modify HMI screens: create, update, or delete graphical objects on the canvas
    - Acknowledge alarms (single or all) on behalf of the operator
    - Navigate the application to relevant views
    - Connect/disconnect the OPC-UA server, control polling

    ## Rules
    1. ALWAYS use tools to make configuration changes — never just describe what the user should do without actually doing it.
    2. ALWAYS confirm what you changed after completing tool calls. Be specific: include tag names, values, and IDs.
    3. For HMI design tasks: call list_hmi_objects first to understand the current layout, then create or update objects.
    4. For alarm configuration: verify the tag exists with list_tags or get_tag_detail before configuring.
    5. When a user provides an image of a desired HMI layout: analyze the visual layout, estimate canvas coordinates \
    (default canvas is 1280×800), determine object types, colors, and tag bindings, then create the objects one by one.
    6. Tag names are CASE-SENSITIVE. Always verify with list_tags before referencing a tag name.
    7. All RGBA color values use doubles in range [0.0, 1.0]. Examples: red={r:1,g:0,b:0,a:1}, \
    green={r:0,g:1,b:0,a:1}, blue={r:0.27,g:0.51,b:0.71,a:1}, dark background={r:0.08,g:0.08,b:0.12,a:1}.
    8. This is a safety-critical industrial environment. Be precise. Confirm before making large bulk changes.
    9. If a tag is not found, say so and list available tags.
    """
}

// MARK: - Tool Definitions (JSON schema for Anthropic API)

enum AgentTools {
    static let definitions: [[String: Any]] = [
        tool("get_system_status",
             "Returns a snapshot of the system: OPC-UA connection state, polling status, tag count, and alarm counts.",
             properties: [:], required: []),

        tool("list_tags",
             "Returns all configured tags with current values, quality, units, and descriptions.",
             properties: [
                "quality_filter": strEnum(["good","bad","uncertain","all"], "Filter by data quality. Default: 'all'."),
                "search": str("Substring search on tag name or description.")
             ], required: []),

        tool("get_tag_detail",
             "Returns full detail for a single tag by name.",
             properties: ["tag_name": str("Exact tag name.")],
             required: ["tag_name"]),

        tool("update_tag_metadata",
             "Updates the engineering unit and/or description for a tag. Does not change the live value.",
             properties: [
                "tag_name":    str("The tag to update."),
                "unit":        str("Engineering unit string, e.g. '°C', '%', 'PSI'. Omit to leave unchanged."),
                "description": str("Human-readable description. Omit to leave unchanged.")
             ], required: ["tag_name"]),

        tool("list_alarm_configs",
             "Returns all alarm configurations: tag name, thresholds, priority, deadband, enabled state.",
             properties: [:], required: []),

        tool("get_alarm_config",
             "Returns the alarm configuration for a specific tag.",
             properties: ["tag_name": str("Tag name to look up.")],
             required: ["tag_name"]),

        tool("create_alarm_config",
             "Creates or replaces an alarm configuration for a tag. All threshold fields are optional.",
             properties: [
                "tag_name":  str("Tag to configure alarms on."),
                "high_high": num("Critical high (High-High) alarm threshold."),
                "high":      num("Warning high alarm threshold."),
                "low":       num("Warning low alarm threshold."),
                "low_low":   num("Critical low (Low-Low) alarm threshold."),
                "deadband":  num("Hysteresis band to prevent alarm flapping. Default: 0.5."),
                "priority":  strEnum(["low","medium","high","critical"], "Alarm priority. Default: 'medium'."),
                "enabled":   bool("Whether the alarm is active. Default: true.")
             ], required: ["tag_name"]),

        tool("update_alarm_config",
             "Updates an existing alarm configuration. Only provided fields are changed.",
             properties: [
                "tag_name":  str("Tag to update alarm config for."),
                "high_high": num("Critical high threshold."),
                "high":      num("Warning high threshold."),
                "low":       num("Warning low threshold."),
                "low_low":   num("Critical low threshold."),
                "deadband":  num("Hysteresis band."),
                "priority":  strEnum(["low","medium","high","critical"], "Alarm priority."),
                "enabled":   bool("Whether the alarm is active.")
             ], required: ["tag_name"]),

        tool("delete_alarm_config",
             "Removes the alarm configuration for a tag.",
             properties: ["tag_name": str("Tag to remove alarm config for.")],
             required: ["tag_name"]),

        tool("acknowledge_alarm",
             "Acknowledges the first unacknowledged alarm for a tag.",
             properties: [
                "tag_name":      str("Tag whose alarm to acknowledge."),
                "operator_name": str("Name to record as acknowledger. Default: 'AI Agent'.")
             ], required: ["tag_name"]),

        tool("acknowledge_all_alarms",
             "Acknowledges all currently unacknowledged active alarms.",
             properties: [
                "operator_name": str("Name to record as acknowledger. Default: 'AI Agent'.")
             ], required: []),

        tool("list_hmi_objects",
             "Returns all objects on the current HMI screen with type, position, size, and tag bindings.",
             properties: [:], required: []),

        tool("create_hmi_object",
             "Creates a new graphical object on the HMI canvas.",
             properties: [
                "type":   strEnum(["rectangle","ellipse","textLabel","numericDisplay","levelBar"], "Object type."),
                "x":      num("X position (left edge) on canvas."),
                "y":      num("Y position (top edge) on canvas."),
                "width":  num("Width in canvas points."),
                "height": num("Height in canvas points."),
                "fill_color":   colorSchema("RGBA fill color."),
                "stroke_color": colorSchema("RGBA stroke/border color."),
                "static_text":  str("Label text (for textLabel objects or designer label)."),
                "font_size":    num("Font size in points."),
                "font_bold":    bool("Use bold font."),
                "tag_binding":  tagBindingSchema(),
                "designer_label": str("Internal design-time label for later reference.")
             ], required: ["type", "x", "y"]),

        tool("update_hmi_object",
             "Updates properties of an existing HMI object. Locate by object_id or designer_label.",
             properties: [
                "object_id":      str("UUID string from list_hmi_objects."),
                "designer_label": str("Designer label (alternative to object_id)."),
                "x": num("New X position."), "y": num("New Y position."),
                "width": num("New width."),  "height": num("New height."),
                "fill_color":   colorSchema("New fill color."),
                "stroke_color": colorSchema("New stroke color."),
                "static_text":  str("New label text."),
                "font_size":    num("New font size."),
                "font_bold":    bool("Bold font."),
                "tag_binding":  tagBindingSchema()
             ], required: []),

        tool("delete_hmi_object",
             "Deletes an HMI object from the canvas.",
             properties: [
                "object_id":      str("UUID from list_hmi_objects."),
                "designer_label": str("Designer label (alternative to object_id).")
             ], required: []),

        tool("navigate_to_tab",
             "Switches the main application tab.",
             properties: [
                "tab": strEnum(["monitor","trends","alarms","hmi","settings","agent"], "Tab to navigate to.")
             ], required: ["tab"]),

        tool("set_opcua_connection",
             "Connects to or disconnects from the OPC-UA server, or controls polling.",
             properties: [
                "action": strEnum(["connect","disconnect","start_polling","pause_polling"], "Action to perform.")
             ], required: ["action"])
    ]

    // MARK: - Schema builder helpers

    private static func tool(_ name: String, _ desc: String,
                              properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": desc,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required
            ] as [String: Any]
        ]
    }

    private static func str(_ desc: String) -> [String: Any] {
        ["type": "string", "description": desc]
    }

    private static func num(_ desc: String) -> [String: Any] {
        ["type": "number", "description": desc]
    }

    private static func bool(_ desc: String) -> [String: Any] {
        ["type": "boolean", "description": desc]
    }

    private static func strEnum(_ values: [String], _ desc: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": desc]
    }

    private static func colorSchema(_ desc: String) -> [String: Any] {
        ["type": "object",
         "description": desc + " RGBA components in [0,1].",
         "properties": [
            "r": ["type": "number"], "g": ["type": "number"],
            "b": ["type": "number"], "a": ["type": "number"]
         ] as [String: Any]]
    }

    private static func tagBindingSchema() -> [String: Any] {
        ["type": "object",
         "description": "Bind this object to a process tag.",
         "properties": [
            "tag_name":      ["type": "string", "description": "Exact tag name."],
            "number_format": ["type": "string", "description": "printf format, e.g. '%.2f'"],
            "unit":          ["type": "string", "description": "Unit string shown next to value."]
         ] as [String: Any],
         "required": ["tag_name"]]
    }
}
