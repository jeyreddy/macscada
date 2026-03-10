import Foundation

// MARK: - AgentService.swift
//
// Claude AI integration for the IndustrialHMI operator assistant.
//
// ── Overview ──────────────────────────────────────────────────────────────────
//   AgentService connects to the Anthropic Messages API (claude-sonnet-4-6) and
//   provides a multi-turn agentic conversation loop with 25+ HMI tool calls.
//   It is the backend for AgentView (text chat UI) and MultimodalInputService
//   (voice/gesture input forwarding).
//
// ── Agentic loop ──────────────────────────────────────────────────────────────
//   sendMessage(text:imageBase64:) is the single public entry point.
//   runAgentLoop() iterates up to maxAgentLoopIterations (20) until the API
//   returns stop_reason = "end_turn" or no more tool_use blocks:
//
//     1. callAPI() → POST /v1/messages with conversationHistory + tool definitions
//     2. Parse MessagesResponse.content for text blocks and tool_use blocks
//     3. Show text in chat as .assistant(text:)
//     4. For each tool_use block: executeTool() → append .toolCall + .toolResult UI
//     5. Append tool results to history as a "user" turn (Anthropic agentic pattern)
//     6. Loop back to step 1 until end_turn
//
// ── Tool catalog (25 tools) ───────────────────────────────────────────────────
//   System:
//     get_system_status         — OPC-UA state, tag count, alarm counts
//
//   Tags:
//     list_tags                 — filtered/searched tag list with values + quality
//     get_tag_detail            — full detail for one tag
//     update_tag_metadata       — set unit, description
//     create_calculated_tag     — create an expression-based derived tag
//     create_totalizer_tag      — create a running accumulator tag
//     reset_totalizer           — reset accumulator to zero
//     delete_tag                — remove a tag
//     write_tag_values          — write one or more tag values (requires operator role)
//     get_tag_history           — query Historian for historical samples
//
//   Alarms:
//     list_alarm_configs        — all alarm setpoint configs
//     get_alarm_config          — config for one tag
//     create_alarm_config       — create/replace alarm config for a tag
//     update_alarm_config       — modify thresholds, deadband, priority
//     delete_alarm_config       — remove alarm config
//     acknowledge_alarm         — ack one active alarm by tag name
//     acknowledge_all_alarms    — ack all unacknowledged alarms
//     shelve_alarm              — ISA-18.2 temporary suppression
//     unshelve_alarm            — restore shelved alarm to service
//     put_alarm_out_of_service  — maintenance mode
//     return_alarm_to_service   — restore OOS alarm
//
//   HMI Objects:
//     list_hmi_objects          — all objects on current screen
//     create_hmi_object         — add a new object to the designer
//     update_hmi_object         — modify object properties
//     delete_hmi_object         — remove an object
//
//   Navigation:
//     navigate_to_tab           — switch the app to a specific tab
//     set_opcua_connection      — change server URL and reconnect
//
//   Recipes:
//     list_recipes              — all saved recipes with setpoints
//     activate_recipe           — apply a recipe to the live process
//
// ── API key storage ───────────────────────────────────────────────────────────
//   Primary:  ~/Library/Application Support/IndustrialHMI/.agentkey (mode 0600)
//   Fallback: in-memory sessionKey (if operator chose not to persist, or file failed)
//   hasAPIKey = true means the key is available via loadAPIKey().
//
// ── Conversation history ──────────────────────────────────────────────────────
//   conversationHistory is a rolling window of up to maxHistory (40) APIMessages.
//   Older messages are dropped from the front of the array to stay within context limits.
//   The UI message list (messages: [AgentMessage]) is append-only and never truncated.
//
// ── Error handling ────────────────────────────────────────────────────────────
//   callAPI() throws AgentError typed errors.  Tool errors are caught individually
//   inside executeTool() and returned as ToolResult(isError: true) so the agent
//   sees the error text and can respond gracefully without crashing the loop.
//
// ── System prompt ─────────────────────────────────────────────────────────────
//   Defined in `systemPrompt` computed property — describes the operator assistant
//   role, safety constraints, and formatting preferences.

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

    /// Injected by DataService after init — provides recipe list and activation.
    var recipeStore: RecipeStore?

    /// Injected by DataService after init — executes OPC-UA write + historian log.
    var confirmWrite: ((WriteRequest) async throws -> Void)?

    /// Injected by DataService after init — gives the agent full Process Canvas CRUD access.
    var canvasStore: ProcessCanvasStore?

    // MARK: - Conversation (rolling window, 40 messages max)

    private var conversationHistory: [APIMessage] = []
    private let maxHistory = 40

    // MARK: - Constants

    private let apiURL   = URL(string: "https://api.anthropic.com/v1/messages")!
    private let modelID  = "claude-sonnet-4-6"
    private let maxTokens = 4096
    private let maxAgentLoopIterations = 20

    // MARK: - API Key storage
    // Primary: file at ~/Library/Application Support/IndustrialHMI/.agentkey (mode 0600)
    // Fallback: in-memory session key (user opted for session-only, or file write failed)

    private static let apiKeyFileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support
            .appendingPathComponent("IndustrialHMI", isDirectory: true)
            .appendingPathComponent(".agentkey")
    }()

    /// Session-only key — used when the user chose not to persist, or file write failed.
    private var sessionKey: String? = nil

    // MARK: - Init

    init(tagEngine:      TagEngine,
         alarmManager:   AlarmManager,
         hmiScreenStore: HMIScreenStore,
         opcuaService:   OPCUAClientService) {
        self.tagEngine      = tagEngine
        self.alarmManager   = alarmManager
        self.hmiScreenStore = hmiScreenStore
        self.opcuaService   = opcuaService
        self.hasAPIKey      = Self.loadFromFile() != nil
    }

    // MARK: - API Key CRUD

    func saveAPIKey(_ key: String, sessionOnly: Bool = false) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if sessionOnly {
            sessionKey = trimmed
            hasAPIKey  = true
            Logger.shared.info("AgentService: API key stored for this session only")
            return
        }

        let url = Self.apiKeyFileURL
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(trimmed.utf8).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            hasAPIKey = true
            Logger.shared.info("AgentService: API key saved to file")
        } catch {
            sessionKey = trimmed
            hasAPIKey  = true
            Logger.shared.error("AgentService: file save failed (\(error)) — key kept for this session only")
        }
    }

    func loadAPIKey() -> String? {
        if let k = sessionKey { return k }
        return Self.loadFromFile()
    }

    func deleteAPIKey() {
        sessionKey = nil
        try? FileManager.default.removeItem(at: Self.apiKeyFileURL)
        hasAPIKey = false
    }

    private static func loadFromFile() -> String? {
        guard let data = try? Data(contentsOf: apiKeyFileURL),
              let key  = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            case "list_hmi_objects":       return try toolListHMIObjects(input: input)
            case "create_hmi_object":      return try toolCreateHMIObject(input: input)
            case "update_hmi_object":      return try toolUpdateHMIObject(input: input)
            case "delete_hmi_object":      return try toolDeleteHMIObject(input: input)
            case "navigate_to_tab":            return try    toolNavigateToTab(input: input)
            case "set_opcua_connection":       return try await toolSetOPCUAConnection(input: input)
            // Phase 12 — Power Tools
            case "list_recipes":               return try    toolListRecipes()
            case "activate_recipe":            return try await toolActivateRecipe(input: input)
            case "shelve_alarm":               return try    toolShelveAlarm(input: input)
            case "unshelve_alarm":             return try    toolUnshelveAlarm(input: input)
            case "put_alarm_out_of_service":   return try    toolPutAlarmOutOfService(input: input)
            case "return_alarm_to_service":    return try    toolReturnAlarmToService(input: input)
            case "get_tag_history":            return try await toolGetTagHistory(input: input)
            case "create_calculated_tag":      return try    toolCreateCalculatedTag(input: input)
            case "create_totalizer_tag":       return try    toolCreateTotalizerTag(input: input)
            case "create_composite_tag":       return try    toolCreateCompositeTag(input: input)
            case "reset_totalizer":            return try    toolResetTotalizer(input: input)
            case "delete_tag":                 return try    toolDeleteTag(input: input)
            case "write_tag_values":           return try await toolWriteTagValues(input: input)
            case "list_all_screens":           return try    toolListAllScreens()
            case "create_hmi_screen":          return try    toolCreateHMIScreen(input: input)
            // Process Canvas tools
            case "list_canvases":              return try    toolListCanvases()
            case "create_canvas":              return try    toolCreateCanvas(input: input)
            case "switch_canvas":              return try    toolSwitchCanvas(input: input)
            case "list_canvas_blocks":         return try    toolListCanvasBlocks()
            case "add_canvas_block":           return try    toolAddCanvasBlock(input: input)
            case "update_canvas_block":        return try    toolUpdateCanvasBlock(input: input)
            case "delete_canvas_block":        return try    toolDeleteCanvasBlock(input: input)
            case "arrange_canvas_grid":        return try    toolArrangeCanvasGrid(input: input)
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
        // Digital status labels (on_label / off_label — also appear in alarm messages)
        if let onL  = input["on_label"]?.value  as? String {
            tag.onLabel  = onL.isEmpty ? nil : onL; changed.append("on_label=\(onL)")
        }
        if let offL = input["off_label"]?.value as? String {
            tag.offLabel = offL.isEmpty ? nil : offL; changed.append("off_label=\(offL)")
        }
        tagEngine.tags[name] = tag
        if let h = tagEngine.historian { Task { try? await h.saveTagConfig(tag) } }
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

    /// Resolve screen by name or return the current active screen.
    /// Returns nil when `screenName` is provided but not found.
    private func resolveScreen(_ screenName: String?) -> HMIScreen? {
        guard let name = screenName, !name.isEmpty, name != "current" else {
            return hmiScreenStore.screen
        }
        if let meta = hmiScreenStore.allScreenMeta.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return hmiScreenStore.loadScreen(id: meta.id)
        }
        return nil
    }

    private func toolListHMIObjects(input: [String: AnyCodable] = [:]) throws -> ToolResult {
        let screenName = strArg(input, "screen_name")
        guard let scr = resolveScreen(screenName) else {
            let available = hmiScreenStore.allScreenMeta.map(\.name).joined(separator: ", ")
            return err("Screen '\(screenName!)' not found. Available: \(available)")
        }
        let objects = scr.objects.map { hmiObjectToDict($0) }
        return ok(["objects": objects, "count": objects.count,
                   "screen_name": scr.name,
                   "canvas": "\(Int(scr.canvasWidth))×\(Int(scr.canvasHeight))"],
                  "\(objects.count) HMI object(s) on '\(scr.name)'")
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

        let screenName = strArg(input, "screen_name")
        if let name = screenName, !name.isEmpty, name != "current" {
            // Targeted screen: add to a named screen without switching the active screen
            guard let meta = hmiScreenStore.allScreenMeta.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                let available = hmiScreenStore.allScreenMeta.map(\.name).joined(separator: ", ")
                return err("Screen '\(name)' not found. Available: \(available)")
            }
            hmiScreenStore.addObjectToScreen(id: meta.id, obj)
            return ok(["created": true, "id": obj.id.uuidString, "type": typeStr, "screen": name],
                      "Created \(objType.displayName) on '\(name)' at (\(Int(x)),\(Int(y))) id=\(obj.id.uuidString.prefix(8))")
        } else {
            hmiScreenStore.addObject(obj)
            return ok(["created": true, "id": obj.id.uuidString, "type": typeStr,
                       "screen": hmiScreenStore.screen.name],
                      "Created \(objType.displayName) at (\(Int(x)),\(Int(y))) id=\(obj.id.uuidString.prefix(8))")
        }
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
        case "recipes":  tab = .recipes
        case "hmi":      tab = .hmi
        case "settings": tab = .settings
        case "agent":    tab = .agent
        case "auditLog":   tab = .auditLog
        case "community":  tab = .community
        case "scheduler":  tab = .scheduler
        default:           tab = nil
        }
        if let t = tab {
            navigateToTab?(t)
            return ok(["navigated_to": tabStr], "Navigated to \(tabStr)")
        } else {
            return err("Unknown tab: \(tabStr). Valid: monitor, trends, alarms, community, auditLog, recipes, scheduler, hmi, settings, agent")
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

    private func toolListAllScreens() throws -> ToolResult {
        let screens: [[String: Any]] = hmiScreenStore.allScreenMeta.map { meta in
            let isCurrent = meta.id == hmiScreenStore.currentScreenId
            let scr       = hmiScreenStore.loadScreen(id: meta.id)
            return [
                "name":       meta.name,
                "id":         meta.id.uuidString,
                "is_current": isCurrent,
                "object_count": scr?.objects.count ?? 0
            ]
        }
        return ok(["screens": screens, "count": screens.count,
                   "current": hmiScreenStore.screen.name],
                  "\(screens.count) HMI screen(s); current: '\(hmiScreenStore.screen.name)'")
    }

    private func toolCreateHMIScreen(input: [String: AnyCodable]) throws -> ToolResult {
        let name = strArg(input, "name") ?? "New Screen"
        hmiScreenStore.createScreen(name: name)
        return ok(["created": name], "HMI screen '\(name)' created and switched to it.")
    }

    // MARK: - Process Canvas Tools

    private func requireCanvas() throws -> ProcessCanvasStore {
        guard let cs = canvasStore else { throw AgentError.missingParameter("canvas store not available") }
        return cs
    }

    private func canvasBlockToDict(_ b: CanvasBlock) -> [String: Any] {
        var d: [String: Any] = [
            "id":         b.id.uuidString,
            "title":      b.title,
            "kind":       b.content.kind,
            "x": b.x, "y": b.y, "w": b.w, "h": b.h,
            "bg_hex":     b.bgHex,
            "border_hex": b.borderHex,
            "show_title": b.showTitle
        ]
        switch b.content.kind {
        case "tagMonitor", "statusGrid":
            d["tag_ids"] = b.content.tagIDs
        case "trendMini":
            d["tag_ids"] = b.content.tagIDs
            d["minutes"] = b.content.minutes
        case "alarmPanel":
            d["max_alarms"] = b.content.maxAlarms
        case "equipment":
            d["equip_kind"]   = b.content.equipKind
            d["equip_tag_id"] = b.content.equipTagID
        case "navButton":
            d["nav_label"] = b.content.navLabel
            d["nav_x"]     = b.content.navX
            d["nav_y"]     = b.content.navY
            d["nav_scale"] = b.content.navScale
        case "hmiScreen":
            d["hmi_screen_id"]   = b.content.hmiScreenID
            d["hmi_screen_name"] = b.content.hmiScreenName
        case "label":
            d["text"]      = b.content.text
            d["font_size"] = b.content.fontSize
        case "region":
            d["text"]             = b.content.text
            d["region_color_hex"] = b.content.regionColorHex
        default: break
        }
        return d
    }

    private func toolListCanvases() throws -> ToolResult {
        let cs = try requireCanvas()
        let list: [[String: Any]] = cs.canvases.map { c in
            ["id":          c.id.uuidString,
             "name":        c.name,
             "block_count": c.blocks.count,
             "is_active":   c.id == cs.activeID]
        }
        return ok(["canvases": list, "count": list.count,
                   "active": cs.active?.name ?? "none"],
                  "\(list.count) canvas(es); active: '\(cs.active?.name ?? "none")'")
    }

    private func toolCreateCanvas(input: [String: AnyCodable]) throws -> ToolResult {
        let cs   = try requireCanvas()
        let name = strArg(input, "name") ?? "New Canvas"
        cs.newCanvas(name: name)
        return ok(["created": name, "id": cs.activeID?.uuidString ?? ""],
                  "Canvas '\(name)' created and activated.")
    }

    private func toolSwitchCanvas(input: [String: AnyCodable]) throws -> ToolResult {
        let cs   = try requireCanvas()
        guard let name = strArg(input, "name") else { throw AgentError.missingParameter("name") }
        guard let target = cs.canvases.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            let available = cs.canvases.map(\.name).joined(separator: ", ")
            return err("Canvas '\(name)' not found. Available: \(available)")
        }
        cs.activeID = target.id
        return ok(["switched_to": target.name, "block_count": target.blocks.count],
                  "Switched to canvas '\(target.name)' (\(target.blocks.count) blocks).")
    }

    private func toolListCanvasBlocks() throws -> ToolResult {
        let cs = try requireCanvas()
        guard let canvas = cs.active else { return err("No active canvas.") }
        let blocks = canvas.blocks.map { canvasBlockToDict($0) }
        return ok(["canvas": canvas.name, "blocks": blocks, "count": blocks.count],
                  "\(blocks.count) block(s) on canvas '\(canvas.name)'")
    }

    private func toolAddCanvasBlock(input: [String: AnyCodable]) throws -> ToolResult {
        let cs   = try requireCanvas()
        guard cs.active != nil else { return err("No active canvas.") }
        guard let kind = strArg(input, "kind") else { throw AgentError.missingParameter("kind") }

        let title  = strArg(input, "title") ?? kind
        let x      = dblArg(input, "x") ?? 100
        let y      = dblArg(input, "y") ?? 100
        let bgHex  = strArg(input, "bg_hex") ?? "#161B22"
        let borHex = strArg(input, "border_hex") ?? "#30363D"

        // Default sizes per block kind
        let (defaultW, defaultH): (Double, Double) = {
            switch kind {
            case "label":      return (260, 80)
            case "region":     return (500, 350)
            case "alarmPanel": return (420, 200)
            case "navButton":  return (220, 70)
            case "equipment":  return (200, 200)
            case "trendMini":  return (380, 180)
            default:           return (320, 220)
            }
        }()
        let w = dblArg(input, "w") ?? defaultW
        let h = dblArg(input, "h") ?? defaultH

        // Build BlockContent from kind + kind-specific args
        let tagIDsRaw = input["tag_ids"]?.value as? [Any] ?? []
        let tagIDs = tagIDsRaw.compactMap { $0 as? String }

        let content: BlockContent
        switch kind {
        case "tagMonitor":
            content = .tagMonitor(tagIDs)
        case "statusGrid":
            content = .statusGrid(tagIDs)
        case "alarmPanel":
            content = .alarmPanel(max: (input["max_alarms"]?.value as? Int) ?? 5)
        case "equipment":
            let ek    = strArg(input, "equip_kind") ?? "pump"
            let etID  = strArg(input, "equip_tag_id") ?? ""
            content   = .equipment(ek, tagID: etID)
        case "trendMini":
            let mins  = (input["minutes"]?.value as? Int) ?? 30
            content   = .trendMini(tagIDs, minutes: mins)
        case "navButton":
            let lbl   = strArg(input, "nav_label") ?? "Navigate →"
            let nx    = dblArg(input, "nav_x") ?? 0
            let ny    = dblArg(input, "nav_y") ?? 0
            let ns    = dblArg(input, "nav_scale") ?? 1.0
            content   = .navButton(label: lbl, x: nx, y: ny, scale: ns)
        case "region":
            let txt   = strArg(input, "text") ?? title
            let col   = strArg(input, "region_color_hex") ?? "#1D4ED8"
            content   = .region(txt, colorHex: col)
        case "label":
            let txt   = strArg(input, "text") ?? title
            let fs    = dblArg(input, "font_size") ?? 28
            content   = .label(txt, size: fs)
        case "hmiScreen":
            let sid   = strArg(input, "hmi_screen_id") ?? ""
            let sname = strArg(input, "hmi_screen_name") ?? ""
            if let uuid = UUID(uuidString: sid) {
                content = .hmiScreen(id: uuid, name: sname)
            } else {
                // Try to find screen by name
                if let meta = hmiScreenStore.allScreenMeta.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(sname) == .orderedSame
                }) {
                    content = .hmiScreen(id: meta.id, name: meta.name)
                } else {
                    return err("HMI screen '\(sname)' not found. Use list_all_screens to get IDs.")
                }
            }
        case "screenGroup":
            content = .screenGroup(cols: (input["cols"]?.value as? Int) ?? 2)
        default:
            return err("Unknown block kind '\(kind)'. Valid: label, tagMonitor, statusGrid, alarmPanel, equipment, trendMini, navButton, hmiScreen, screenGroup, region")
        }

        let block = CanvasBlock(title: title, showTitle: true,
                                x: x, y: y, w: w, h: h,
                                bgHex: bgHex, borderHex: borHex,
                                content: content)
        cs.addBlock(block)
        return ok(canvasBlockToDict(block),
                  "Added '\(title)' (\(kind)) block at (\(Int(x)),\(Int(y))) on canvas '\(cs.active?.name ?? "")'")
    }

    private func toolUpdateCanvasBlock(input: [String: AnyCodable]) throws -> ToolResult {
        let cs = try requireCanvas()
        guard var canvas = cs.active else { return err("No active canvas.") }

        // Find block by ID or title
        var block: CanvasBlock?
        if let idStr = strArg(input, "block_id"), let uuid = UUID(uuidString: idStr) {
            block = canvas.blocks.first { $0.id == uuid }
        }
        if block == nil, let title = strArg(input, "block_title") {
            block = canvas.blocks.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        }
        guard var b = block else {
            let titles = canvas.blocks.map(\.title).joined(separator: ", ")
            return err("Block not found. Available: \(titles)")
        }

        // Apply updates
        if let v = strArg(input, "title")      { b.title     = v }
        if let v = dblArg(input, "x")          { b.x         = v }
        if let v = dblArg(input, "y")          { b.y         = v }
        if let v = dblArg(input, "w")          { b.w         = v }
        if let v = dblArg(input, "h")          { b.h         = v }
        if let v = strArg(input, "bg_hex")     { b.bgHex     = v }
        if let v = strArg(input, "border_hex") { b.borderHex = v }
        if let v = input["show_title"]?.value as? Bool { b.showTitle = v }

        // Content updates
        if let tagIDsRaw = input["tag_ids"]?.value as? [Any] {
            b.content.tagIDs = tagIDsRaw.compactMap { $0 as? String }
        }
        if let v = strArg(input, "equip_kind")   { b.content.equipKind   = v }
        if let v = strArg(input, "equip_tag_id") { b.content.equipTagID  = v }
        if let v = strArg(input, "nav_label")    { b.content.navLabel    = v }
        if let v = dblArg(input, "nav_x")        { b.content.navX        = v }
        if let v = dblArg(input, "nav_y")        { b.content.navY        = v }
        if let v = dblArg(input, "nav_scale")    { b.content.navScale    = v }
        if let v = strArg(input, "text")         { b.content.text        = v }
        if let v = dblArg(input, "font_size")    { b.content.fontSize    = v }
        if let v = strArg(input, "region_color_hex") { b.content.regionColorHex = v }
        if let v = input["max_alarms"]?.value as? Int { b.content.maxAlarms = v }
        if let v = input["minutes"]?.value as? Int    { b.content.minutes    = v }

        cs.updateBlock(b)
        return ok(canvasBlockToDict(b), "Updated block '\(b.title)' on canvas '\(canvas.name)'")
    }

    private func toolDeleteCanvasBlock(input: [String: AnyCodable]) throws -> ToolResult {
        let cs = try requireCanvas()
        guard let canvas = cs.active else { return err("No active canvas.") }

        var block: CanvasBlock?
        if let idStr = strArg(input, "block_id"), let uuid = UUID(uuidString: idStr) {
            block = canvas.blocks.first { $0.id == uuid }
        }
        if block == nil, let title = strArg(input, "block_title") {
            block = canvas.blocks.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        }
        guard let b = block else {
            let titles = canvas.blocks.map(\.title).joined(separator: ", ")
            return err("Block not found. Available blocks: \(titles)")
        }
        cs.deleteBlock(b.id)
        return ok(["deleted": b.title, "id": b.id.uuidString],
                  "Deleted block '\(b.title)' from canvas '\(canvas.name)'")
    }

    /// Arrange all blocks (or a filtered subset) in a tidy grid layout.
    private func toolArrangeCanvasGrid(input: [String: AnyCodable]) throws -> ToolResult {
        let cs = try requireCanvas()
        guard var canvas = cs.active else { return err("No active canvas.") }

        let cols     = (input["cols"]?.value as? Int) ?? 3
        let spacingX = dblArg(input, "spacing_x") ?? 40
        let spacingY = dblArg(input, "spacing_y") ?? 40
        let startX   = dblArg(input, "start_x") ?? 60
        let startY   = dblArg(input, "start_y") ?? 60

        // Optionally filter to a specific kind
        let kindFilter = strArg(input, "kind_filter")
        var targets = canvas.blocks
        if let kf = kindFilter {
            targets = targets.filter { $0.content.kind == kf }
        }
        // Sort by current Y then X (top-to-bottom reading order before rearranging)
        targets.sort { a, b in
            if abs(a.y - b.y) > 50 { return a.y < b.y }
            return a.x < b.x
        }

        // Compute row heights: each row is as tall as the tallest block in that row
        var col = 0, rowX = startX, rowY = startY
        var rowMaxH: Double = 0
        var updated: [(UUID, Double, Double)] = []

        for block in targets {
            updated.append((block.id, rowX, rowY))
            rowMaxH = max(rowMaxH, block.h)
            col += 1
            if col >= cols {
                rowY  += rowMaxH + spacingY
                rowX   = startX
                rowMaxH = 0
                col    = 0
            } else {
                rowX += block.w + spacingX
            }
        }

        // Apply positions
        for (id, nx, ny) in updated {
            if let idx = canvas.blocks.firstIndex(where: { $0.id == id }) {
                canvas.blocks[idx].x = nx
                canvas.blocks[idx].y = ny
            }
        }
        cs.active = canvas
        cs.save()

        return ok(["arranged_count": updated.count, "cols": cols,
                   "canvas": canvas.name],
                  "Arranged \(updated.count) block(s) in \(cols)-column grid on '\(canvas.name)'")
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

    // MARK: - Phase 12: Recipe Tools

    private func toolListRecipes() throws -> ToolResult {
        guard let store = recipeStore else { return err("Recipe store not available.") }
        let fmt = ISO8601DateFormatter()
        let list: [[String: Any]] = store.recipes.map { r in
            var d: [String: Any] = [
                "name":           r.name,
                "setpoint_count": r.setpoints.count,
                "version":        r.version,
                "last_activated": r.lastActivatedAt.map { fmt.string(from: $0) } ?? "Never",
                "last_activated_by": r.lastActivatedBy ?? "—"
            ]
            if !r.description.isEmpty { d["description"] = r.description }
            return d
        }
        return ok(["recipes": list, "count": list.count],
                  list.isEmpty ? "No recipes configured." : "Found \(list.count) recipe(s).")
    }

    private func toolActivateRecipe(input: [String: AnyCodable]) async throws -> ToolResult {
        guard let name = strArg(input, "recipe_name") else {
            throw AgentError.missingParameter("recipe_name")
        }
        guard let store = recipeStore else { return err("Recipe store not available.") }
        guard let recipe = store.recipes.first(where: { $0.name == name }) else {
            let available = store.recipes.map(\.name).joined(separator: ", ")
            return err("Recipe '\(name)' not found. Available: \(available.isEmpty ? "none" : available)")
        }
        let opName = (input["operator_name"]?.value as? String) ?? "AI Agent"
        let result = await store.activateRecipe(recipe, by: opName)
        let failedList = result.failed.map {
            ["tag_name": $0.tagName, "reason": $0.reason] as [String: Any]
        }
        let d: [String: Any] = [
            "recipe_name":     name,
            "total_setpoints": result.recipe.setpoints.count,
            "succeeded_count": result.succeeded.count,
            "succeeded_tags":  result.succeeded,
            "failed_count":    result.failed.count,
            "failed":          failedList
        ]
        return ok(d, "Recipe '\(name)': \(result.succeeded.count)/\(result.recipe.setpoints.count) setpoints written successfully.")
    }

    // MARK: - Phase 12: Alarm Shelve / OOS Tools

    private func toolShelveAlarm(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else {
            throw AgentError.missingParameter("tag_name")
        }
        guard let alarm = alarmManager.activeAlarms.first(where: { $0.tagName == tagName }) else {
            return err("No active alarm found for tag '\(tagName)'.")
        }
        let hours    = dblArg(input, "duration_hours")
        let reason   = input["reason"]?.value as? String
        let duration = hours.map { $0 * 3600 }
        alarmManager.shelveAlarm(alarm, by: "AI Agent", duration: duration, reason: reason)
        let durStr = hours.map { " for \(Int($0))h" } ?? " indefinitely"
        return ok(["shelved": tagName], "Alarm for '\(tagName)' shelved\(durStr).")
    }

    private func toolUnshelveAlarm(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else {
            throw AgentError.missingParameter("tag_name")
        }
        guard let alarm = alarmManager.shelvedAlarms.first(where: { $0.tagName == tagName }) else {
            return err("No shelved alarm found for tag '\(tagName)'.")
        }
        alarmManager.unshelveAlarm(id: alarm.id, by: "AI Agent")
        return ok(["unshelved": tagName], "Alarm for '\(tagName)' unshelved and returned to normal monitoring.")
    }

    private func toolPutAlarmOutOfService(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else {
            throw AgentError.missingParameter("tag_name")
        }
        guard let config = alarmManager.alarmConfigs.first(where: { $0.tagName == tagName }) else {
            return err("No alarm config found for tag '\(tagName)'.")
        }
        let reason = input["reason"]?.value as? String
        alarmManager.putOutOfService(config.id, by: "AI Agent", reason: reason)
        return ok(["out_of_service": tagName], "Alarm for '\(tagName)' put out of service (ISA-18.2 OOS).")
    }

    private func toolReturnAlarmToService(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else {
            throw AgentError.missingParameter("tag_name")
        }
        guard let config = alarmManager.alarmConfigs.first(where: { $0.tagName == tagName }) else {
            return err("No alarm config found for tag '\(tagName)'.")
        }
        alarmManager.returnToService(config.id, by: "AI Agent")
        return ok(["returned_to_service": tagName], "Alarm for '\(tagName)' returned to service.")
    }

    // MARK: - Phase 12: Historical Data Tool

    private func toolGetTagHistory(input: [String: AnyCodable]) async throws -> ToolResult {
        // tag_names can arrive as [String] or [Any] from JSON decoding
        let raw = input["tag_names"]?.value
        var tagNames: [String] = []
        if let arr = raw as? [Any] {
            tagNames = arr.compactMap { $0 as? String }
        } else if let s = raw as? String {
            tagNames = [s]
        }
        guard !tagNames.isEmpty else { throw AgentError.missingParameter("tag_names") }

        let hours = dblArg(input, "hours") ?? 24.0
        let from  = Date().addingTimeInterval(-hours * 3600)
        let data  = await tagEngine.getHistoricalData(
            for: tagNames, from: from, to: Date(), maxPoints: 2000
        )
        let fmt = ISO8601DateFormatter()
        var summary: [String: Any] = [:]
        for tagName in tagNames {
            let pts = data[tagName] ?? []
            if pts.isEmpty {
                summary[tagName] = ["count": 0, "note": "No historical data found in the requested range."]
            } else {
                let vals = pts.map(\.value)
                summary[tagName] = [
                    "count":      pts.count,
                    "min":        vals.min()!,
                    "max":        vals.max()!,
                    "average":    vals.reduce(0, +) / Double(vals.count),
                    "last_value": vals.last!,
                    "from":       fmt.string(from: from),
                    "to":         fmt.string(from: Date())
                ]
            }
        }
        return ok(["hours": hours, "tags": summary],
                  "Historical summary for \(tagNames.count) tag(s) over last \(Int(hours))h.")
    }

    // MARK: - Phase 12: Calculated / Totalizer Tag Tools

    private func toolCreateCalculatedTag(input: [String: AnyCodable]) throws -> ToolResult {
        guard let name       = strArg(input, "name")       else { throw AgentError.missingParameter("name") }
        guard let expression = strArg(input, "expression") else { throw AgentError.missingParameter("expression") }
        let unit        = input["unit"]?.value        as? String
        let description = input["description"]?.value as? String
        do {
            try tagEngine.addCalculatedTag(name: name, expression: expression,
                                           unit: unit, description: description, dataType: .calculated)
            return ok(["created": name, "expression": expression],
                      "Calculated tag '\(name)' created with expression: \(expression)")
        } catch {
            return err("Failed to create calculated tag '\(name)': \(error.localizedDescription)")
        }
    }

    private func toolCreateTotalizerTag(input: [String: AnyCodable]) throws -> ToolResult {
        guard let name          = strArg(input, "name")            else { throw AgentError.missingParameter("name") }
        guard let sourceTagName = strArg(input, "source_tag_name") else { throw AgentError.missingParameter("source_tag_name") }
        let unit        = input["unit"]?.value        as? String
        let description = input["description"]?.value as? String
        do {
            try tagEngine.addTotalizerTag(name: name, sourceTagName: sourceTagName,
                                          unit: unit, description: description)
            return ok(["created": name, "source_tag_name": sourceTagName],
                      "Totalizer tag '\(name)' created. It will integrate '\(sourceTagName)' over time (∑ value × Δt).")
        } catch {
            return err("Failed to create totalizer '\(name)': \(error.localizedDescription)")
        }
    }

    private func toolResetTotalizer(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        guard let tag = tagEngine.getTag(named: tagName) else { return err("Tag '\(tagName)' not found.") }
        guard tag.dataType == .totalizer else {
            return err("Tag '\(tagName)' is not a totalizer (type: \(tag.dataType.rawValue)).")
        }
        tagEngine.resetTotalizer(name: tagName)
        return ok(["reset": tagName], "Totalizer '\(tagName)' reset to 0.")
    }

    private func toolDeleteTag(input: [String: AnyCodable]) throws -> ToolResult {
        guard let tagName = strArg(input, "tag_name") else { throw AgentError.missingParameter("tag_name") }
        guard let tag = tagEngine.getTag(named: tagName) else { return err("Tag '\(tagName)' not found.") }
        switch tag.dataType {
        case .calculated:
            tagEngine.removeCalculatedTag(name: tagName)
            return ok(["deleted": tagName], "Calculated tag '\(tagName)' deleted.")
        case .totalizer:
            tagEngine.removeTotalizerTag(name: tagName)
            return ok(["deleted": tagName], "Totalizer tag '\(tagName)' deleted.")
        case .composite:
            tagEngine.removeCompositeTag(name: tagName)
            return ok(["deleted": tagName], "Composite tag '\(tagName)' deleted.")
        default:
            return err("Tag '\(tagName)' is a hardware tag (type: \(tag.dataType.rawValue)). Only calculated, totalizer, and composite tags can be deleted via agent.")
        }
    }

    private func toolCreateCompositeTag(input: [String: AnyCodable]) throws -> ToolResult {
        guard let name = strArg(input, "name") else { throw AgentError.missingParameter("name") }
        guard let aggStr = strArg(input, "aggregation") else { throw AgentError.missingParameter("aggregation") }
        guard let aggregation = CompositeAggregation(rawValue: aggStr) else {
            return err("Unknown aggregation '\(aggStr)'. Valid: average, sum, minimum, maximum, and_all, or_any")
        }
        let raw = input["members"]?.value
        guard let membersRaw = raw as? [Any], !membersRaw.isEmpty else {
            throw AgentError.missingParameter("members (array of {alias, tag_name})")
        }
        let members: [CompositeMember] = membersRaw.compactMap { item in
            guard let d = item as? [String: Any],
                  let tagName = d["tag_name"] as? String else { return nil }
            return CompositeMember(alias: d["alias"] as? String ?? "", tagName: tagName)
        }
        guard !members.isEmpty else { return err("No valid members provided.") }

        let unit        = strArg(input, "unit")
        let description = strArg(input, "description")
        do {
            try tagEngine.addCompositeTag(name: name, members: members, aggregation: aggregation,
                                          unit: unit, description: description)
            let memberNames = members.map { $0.tagName }.joined(separator: ", ")
            return ok(["created": name, "aggregation": aggStr, "member_count": members.count],
                      "Composite tag '\(name)' created (\(aggStr) of: \(memberNames))")
        } catch {
            return err("Failed to create composite tag '\(name)': \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 12: Batch Write Tool

    private func toolWriteTagValues(input: [String: AnyCodable]) async throws -> ToolResult {
        guard let writeFn = confirmWrite else {
            return err("Write function not available — please restart the application.")
        }
        let raw = input["writes"]?.value
        guard let writesRaw = raw as? [Any], !writesRaw.isEmpty else {
            throw AgentError.missingParameter("writes")
        }
        let opName = (input["operator_name"]?.value as? String) ?? "AI Agent"

        var succeeded: [String]       = []
        var failed:    [[String: Any]] = []

        for item in writesRaw {
            guard let dict    = item as? [String: Any],
                  let tagName = dict["tag_name"] as? String,
                  let value   = dict["value"] as? Double else {
                failed.append(["tag_name": "unknown", "reason": "Invalid entry format (need tag_name and value)."])
                continue
            }
            guard let req = tagEngine.requestWrite(
                tagName: tagName, newValue: .analog(value), requestedBy: opName
            ) else {
                failed.append(["tag_name": tagName, "reason": "Tag not found."])
                continue
            }
            do {
                try await writeFn(req)
                succeeded.append(tagName)
            } catch {
                tagEngine.cancelWrite(req)
                failed.append(["tag_name": tagName, "reason": error.localizedDescription])
            }
        }

        let d: [String: Any] = [
            "total":           writesRaw.count,
            "succeeded_count": succeeded.count,
            "succeeded":       succeeded,
            "failed_count":    failed.count,
            "failed":          failed
        ]
        return ok(d, "Batch write: \(succeeded.count)/\(writesRaw.count) tag(s) written successfully.")
    }

    // MARK: - System Prompt

    private let systemPrompt = """
    You are an AI assistant embedded in an industrial SCADA/HMI application called "Industrial HMI". \
    You have direct access to the running system through tools.

    ## Your Capabilities
    - Query real-time tag values, connection status, alarm states, and system statistics
    - Configure alarm setpoints (high-high/critical, high/warning, low/warning, low-low/critical, deadband, priority)
    - Acknowledge, shelve, unshelve, put out-of-service, and return alarms to service (ISA-18.2)
    - Update tag metadata: engineering units and descriptions
    - Create calculated tags (formula expressions, e.g. avg(TempA, TempB) or TempA + Offset)
    - Create totalizer tags that accumulate ∑(source_value × Δt) over time (e.g. flow totalizers); reset them on demand
    - Delete calculated or totalizer tags (hardware/OPC-UA tags cannot be deleted via agent)
    - Batch-write values to multiple tags in a single operation
    - List and activate recipes (batch setpoint downloads to multiple tags)
    - Query historical trend data: min/avg/max/last values over a time range
    - Design and modify HMI screens: create, update, or delete graphical objects on the canvas
    - **Process Canvas (plant overview spatial layout)**: Full control over canvases and every block on them:
        - List all canvases and blocks (list_canvases, list_canvas_blocks)
        - Create / rename canvases for different plant areas (create_canvas, switch_canvas)
        - Add blocks of any kind: tag monitors, equipment icons, alarm panels, status grids, \
    trend sparklines, navigation buttons, region labels, HMI screen links (add_canvas_block)
        - Update block position, size, title, content, colors (update_canvas_block)
        - Delete blocks (delete_canvas_block)
        - Auto-arrange all blocks into a tidy matrix/grid layout (arrange_canvas_grid)
    - Navigate the application to relevant views
    - Connect/disconnect the OPC-UA server, control polling

    ## Process Canvas Block Kinds
    | kind        | key fields                                              |
    |-------------|--------------------------------------------------------|
    | tagMonitor  | tag_ids: [tag names] — live value table                |
    | statusGrid  | tag_ids: [tag names] — colored status tiles            |
    | alarmPanel  | max_alarms: int — ISA-18.2 active alarm list           |
    | equipment   | equip_kind: pump/motor/valve/tank/exchanger/compressor, equip_tag_id: status tag |
    | trendMini   | tag_ids: [tag names], minutes: int — sparkline chart   |
    | navButton   | nav_label, nav_x, nav_y, nav_scale — viewport jump btn |
    | region      | text: label, region_color_hex: "#RRGGBB" — area marker |
    | label       | text: heading text, font_size: pt                      |
    | hmiScreen   | hmi_screen_id or hmi_screen_name — link to HMI screen  |

    ## Canvas Coordinate System
    Canvas units = logical points. Origin (0, 0) is top-left. Typical plant overview:
    - Screen width spans 0–2000+ units, height spans 0–1500+ units
    - Block sizes: tagMonitor 320×220, equipment 200×200, alarmPanel 420×200, region 500×350
    - Grid layout: use arrange_canvas_grid to auto-place blocks in rows and columns
    - Background hex: "#0D1117" (dark), border hex: "#30363D" (subtle)
    - Equipment color: pumps "#0A1628"/"#1D4ED8", alarms "#1A0A0A"/"#7F1D1D"

    ## Canvas Design Workflow (for layout requests)
    1. call list_canvases to see what exists
    2. call list_canvas_blocks to see the current layout
    3. Add/update/delete blocks as needed
    4. If user wants a matrix/grid arrangement, call arrange_canvas_grid at the end

    ## Rules
    1. ALWAYS use tools to make configuration changes — never just describe what the user should do without actually doing it.
    2. ALWAYS confirm what you changed after completing tool calls. Be specific: include block titles, positions, and IDs.
    3. For HMI design tasks: call list_hmi_objects first to understand the current layout, then create or update objects.
    4. For canvas design tasks: call list_canvas_blocks first, then add/update/delete blocks.
    5. For alarm configuration: verify the tag exists with list_tags or get_tag_detail before configuring.
    6. When a user describes a plant layout (areas, equipment, tags): map it to canvas blocks, choose coordinates \
    that mirror the physical plant (e.g. feed area top-left, reaction centre, utilities top-right), \
    then create all blocks. Finish with arrange_canvas_grid if a matrix layout is preferred.
    7. Tag names are CASE-SENSITIVE. Always verify with list_tags before referencing a tag name.
    8. All RGBA color values use doubles in range [0.0, 1.0]. Examples: red={r:1,g:0,b:0,a:1}, \
    green={r:0,g:1,b:0,a:1}, dark background={r:0.08,g:0.08,b:0.12,a:1}.
    9. This is a safety-critical industrial environment. Be precise. Confirm before making large bulk changes.
    10. If a tag is not found, say so and list available tags.
    11. Totalizer tags accumulate value·time automatically; use reset_totalizer to zero them. \
    Source tag must already exist before creating a totalizer.
    12. For batch writes, the agent is logged as the operator; all writes appear in the Audit Log.
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
             "Updates engineering unit, description, and/or custom on/off state labels for a tag. " +
             "on_label and off_label are shown in formattedValue and in alarm messages for digital tags.",
             properties: [
                "tag_name":    str("The tag to update."),
                "unit":        str("Engineering unit string, e.g. '°C', '%', 'PSI'. Omit to leave unchanged."),
                "description": str("Human-readable description. Omit to leave unchanged."),
                "on_label":    str("Custom text shown when a digital tag is true, e.g. 'Running', 'Open', 'Energized'."),
                "off_label":   str("Custom text shown when a digital tag is false, e.g. 'Stopped', 'Closed', 'De-energized'.")
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
                "tab": strEnum(["monitor","trends","alarms","community","auditLog","recipes","scheduler","hmi","settings","agent"], "Tab to navigate to.")
             ], required: ["tab"]),

        tool("set_opcua_connection",
             "Connects to or disconnects from the OPC-UA server, or controls polling.",
             properties: [
                "action": strEnum(["connect","disconnect","start_polling","pause_polling"], "Action to perform.")
             ], required: ["action"]),

        // Phase 12 — Power Tools

        tool("list_recipes",
             "Lists all saved recipes with name, setpoint count, and last activation info.",
             properties: [:], required: []),

        tool("activate_recipe",
             "Activates a recipe by name, writing all its setpoints to their target tags.",
             properties: [
                "recipe_name":   str("Exact recipe name (case-sensitive)."),
                "operator_name": str("Operator to log the activation as. Default: 'AI Agent'.")
             ], required: ["recipe_name"]),

        tool("shelve_alarm",
             "Shelves (temporarily suppresses) an active alarm for a tag (ISA-18.2 shelving).",
             properties: [
                "tag_name":       str("Tag name with the active alarm to shelve."),
                "duration_hours": num("Shelve duration in hours. Omit for indefinite shelving."),
                "reason":         str("Reason for shelving, recorded in the alarm journal.")
             ], required: ["tag_name"]),

        tool("unshelve_alarm",
             "Manually unshelves a shelved alarm, returning it to normal monitoring.",
             properties: ["tag_name": str("Tag name of the shelved alarm.")],
             required: ["tag_name"]),

        tool("put_alarm_out_of_service",
             "Puts an alarm config out of service (ISA-18.2 OOS) — alarm detection is fully suppressed until returned.",
             properties: [
                "tag_name": str("Tag whose alarm config to put out of service."),
                "reason":   str("Maintenance or calibration reason (audit trail).")
             ], required: ["tag_name"]),

        tool("return_alarm_to_service",
             "Returns an alarm config from out-of-service back to normal alarm monitoring.",
             properties: ["tag_name": str("Tag name to return to service.")],
             required: ["tag_name"]),

        tool("get_tag_history",
             "Returns aggregated historical data (min/avg/max/last/count) for one or more tags over a time window.",
             properties: [
                "tag_names": ["type": "array",
                              "items": ["type": "string"] as [String: Any],
                              "description": "Tag names to query (case-sensitive)."] as [String: Any],
                "hours": num("Hours of history to retrieve. Default: 24.")
             ], required: ["tag_names"]),

        tool("create_calculated_tag",
             "Creates a new tag whose live value is computed from a formula over other tag values. " +
             "Supported: arithmetic (+,-,*,/), comparison, logic, ternary, IF/THEN/ELSE, " +
             "and functions: abs, sqrt, round, floor, ceil, sign, min, max, avg, sum, clamp.",
             properties: [
                "name":        str("Unique tag name for the calculated tag."),
                "expression":  str("Formula, e.g. 'avg(TempA, TempB)' or '(Flow1 + Flow2) / 2'."),
                "unit":        str("Engineering unit (optional)."),
                "description": str("Human-readable description (optional).")
             ], required: ["name", "expression"]),

        tool("create_totalizer_tag",
             "Creates a totalizer tag that continuously integrates a source tag value over time: " +
             "accumulated = ∑(source_value × Δt). Useful for flow totalizers, energy accumulators, etc. " +
             "The source tag must already exist. Use reset_totalizer to zero the accumulator.",
             properties: [
                "name":            str("Unique name for the totalizer tag."),
                "source_tag_name": str("Name of the tag whose value is integrated (must exist)."),
                "unit":            str("Engineering unit for the accumulated result, e.g. 'm³', 'kWh'."),
                "description":     str("Description (optional).")
             ], required: ["name", "source_tag_name"]),

        tool("reset_totalizer",
             "Resets a totalizer tag's accumulated value back to zero.",
             properties: ["tag_name": str("Name of the totalizer tag to reset.")],
             required: ["tag_name"]),

        tool("delete_tag",
             "Deletes a calculated or totalizer tag. Hardware/OPC-UA/Modbus/MQTT tags cannot be deleted via agent.",
             properties: ["tag_name": str("Name of the calculated or totalizer tag to delete.")],
             required: ["tag_name"]),

        tool("write_tag_values",
             "Batch-writes values to multiple tags in a single operation. All writes are logged to the Audit Log.",
             properties: [
                "writes": ["type": "array",
                           "description": "List of {tag_name, value} write pairs.",
                           "items": ["type": "object",
                                     "properties": [
                                        "tag_name": ["type": "string", "description": "Exact tag name."],
                                        "value":    ["type": "number", "description": "Numeric value to write."]
                                     ] as [String: Any],
                                     "required": ["tag_name", "value"]] as [String: Any]] as [String: Any],
                "operator_name": str("Operator to record in the write audit log. Default: 'AI Agent'.")
             ], required: ["writes"]),

        // ── Process Canvas tools ─────────────────────────────────────────────

        tool("list_canvases",
             "Lists all Process Canvas documents with name, block count, and active flag.",
             properties: [:], required: []),

        tool("create_canvas",
             "Creates a new empty Process Canvas with the given name and makes it active.",
             properties: ["name": str("Name for the new canvas, e.g. 'Utilities Area'.")],
             required: []),

        tool("switch_canvas",
             "Switches the active canvas by name.",
             properties: ["name": str("Canvas name to activate (case-insensitive).")],
             required: ["name"]),

        tool("list_canvas_blocks",
             "Returns all blocks on the active canvas: kind, title, position (x,y), size (w,h), and content fields.",
             properties: [:], required: []),

        tool("add_canvas_block",
             "Adds a new block to the active Process Canvas. " +
             "Block kinds: tagMonitor (live tag table), statusGrid (colored tiles), alarmPanel (ISA-18.2 list), " +
             "equipment (pump/motor/valve/tank icon), trendMini (sparklines), navButton (viewport jump), " +
             "region (translucent area label), label (static heading), hmiScreen (link to HMI screen).",
             properties: [
                "kind":    strEnum(["tagMonitor","statusGrid","alarmPanel","equipment","trendMini",
                                    "navButton","region","label","hmiScreen","screenGroup"],
                                   "Block type to create."),
                "title":   str("Block title shown in the header bar."),
                "x":       num("Canvas X position (left edge). Default: 100."),
                "y":       num("Canvas Y position (top edge). Default: 100."),
                "w":       num("Width in canvas units. Defaults vary by kind."),
                "h":       num("Height in canvas units. Defaults vary by kind."),
                "bg_hex":  str("Background hex color, e.g. '#161B22'. Default: '#161B22'."),
                "border_hex": str("Border hex color, e.g. '#30363D'. Default: '#30363D'."),
                // tagMonitor / statusGrid / trendMini
                "tag_ids": ["type": "array", "items": ["type": "string"] as [String: Any],
                            "description": "Tag names to display (for tagMonitor, statusGrid, trendMini)."] as [String: Any],
                "minutes": num("History window in minutes for trendMini. Default: 30."),
                // alarmPanel
                "max_alarms": ["type": "integer", "description": "Max alarm rows shown. Default: 5."] as [String: Any],
                // equipment
                "equip_kind":   strEnum(["pump","motor","valve","tank","exchanger","compressor"],
                                        "Equipment icon type."),
                "equip_tag_id": str("Tag name whose value drives running/stopped color of the equipment icon."),
                // navButton
                "nav_label": str("Button label text, e.g. 'Go to Mixing →'."),
                "nav_x":     num("Canvas X of viewport centre after navigation."),
                "nav_y":     num("Canvas Y of viewport centre after navigation."),
                "nav_scale": num("Zoom level after navigation (1.0 = 100%). Default: 1."),
                // label / region
                "text":             str("Displayed text for label or region blocks."),
                "font_size":        num("Font size in points for label blocks. Default: 28."),
                "region_color_hex": str("Hex tint for region background, e.g. '#1D4ED8'. Default: '#1D4ED8'."),
                // hmiScreen
                "hmi_screen_id":   str("UUID string of the linked HMI screen."),
                "hmi_screen_name": str("Name of the HMI screen to link (alternative to ID).")
             ], required: ["kind"]),

        tool("update_canvas_block",
             "Updates properties of an existing canvas block. Locate by block_id (UUID) or block_title.",
             properties: [
                "block_id":    str("UUID string from list_canvas_blocks."),
                "block_title": str("Block title (case-insensitive, alternative to block_id)."),
                "title":       str("New title."),
                "x": num("New X."), "y": num("New Y."),
                "w": num("New width."), "h": num("New height."),
                "bg_hex":      str("New background hex."),
                "border_hex":  str("New border hex."),
                "show_title":  bool("Show/hide the title bar."),
                "tag_ids": ["type": "array", "items": ["type": "string"] as [String: Any],
                            "description": "Replace the block's tag list."] as [String: Any],
                "max_alarms":       ["type": "integer", "description": "Max alarm rows."] as [String: Any],
                "equip_kind":       str("New equipment icon type."),
                "equip_tag_id":     str("New status tag for equipment."),
                "nav_label":        str("New nav button label."),
                "nav_x":            num("New nav target X."),
                "nav_y":            num("New nav target Y."),
                "nav_scale":        num("New nav target scale."),
                "text":             str("New text for label or region."),
                "font_size":        num("New font size."),
                "region_color_hex": str("New region tint hex."),
                "minutes":          num("New trend window minutes.")
             ], required: []),

        tool("delete_canvas_block",
             "Removes a block from the active canvas by title or ID.",
             properties: [
                "block_id":    str("UUID from list_canvas_blocks."),
                "block_title": str("Block title (case-insensitive, alternative to block_id).")
             ], required: []),

        tool("arrange_canvas_grid",
             "Rearranges blocks on the active canvas into a tidy grid (matrix) layout. " +
             "Blocks keep their original size; only their x/y positions are updated. " +
             "Sort order: current top-to-bottom, left-to-right reading order.",
             properties: [
                "cols":        ["type": "integer", "description": "Number of columns. Default: 3."] as [String: Any],
                "spacing_x":   num("Horizontal gap between blocks. Default: 40."),
                "spacing_y":   num("Vertical gap between rows. Default: 40."),
                "start_x":     num("X coordinate of the top-left block. Default: 60."),
                "start_y":     num("Y coordinate of the top-left block. Default: 60."),
                "kind_filter": strEnum(["tagMonitor","statusGrid","alarmPanel","equipment","trendMini",
                                        "navButton","region","label","hmiScreen","screenGroup"],
                                       "Only rearrange blocks of this kind. Omit to arrange all blocks.")
             ], required: [])
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
