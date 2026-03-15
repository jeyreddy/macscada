# Industrial HMI — Claude Code Context

## Project Overview
Native macOS SCADA/HMI application replacing Windows-based industrial control systems.
- **Author:** Jagan (ISA Fellow, 25+ yrs industrial automation, ex-Honeywell Principal Engineer)
- **Version:** 0.1.0 Pre-release
- **Status:** Active development

## Tech Stack
- **Language:** Swift 5.9+, macOS 14+ (arm64 primary)
- **UI:** SwiftUI
- **Build:** Swift Package Manager (`Package.swift`)
- **Database:** SQLite via `SQLite.swift` (SPM dependency)
- **Industrial Protocol:** OPC-UA via `open62541` C library (Homebrew: `brew install open62541`)
- **AI Integration:** Anthropic Claude API (`claude-sonnet-4-6`) in `AgentService`

## Prerequisites
```bash
brew install open62541          # OPC-UA C library → /opt/homebrew/lib/libopen62541.dylib
# Headers at /opt/homebrew/include/open62541/
```

## Build & Run
```bash
swift build                     # build
swift run IndustrialHMI        # run
swift test                      # tests
```
Open `Package.swift` in Xcode and press ⌘R to build and run from IDE.

## Source Layout
```
Sources/IndustrialHMI/
├── IndustrialHMIApp.swift      # @main entry, AppDelegate (single-instance lock), env injection
├── Agent/
│   ├── AgentService.swift      # Claude API agentic loop, 25+ HMI tool calls
│   └── AgentMessage.swift      # Chat message model
├── DataService/
│   ├── DataService.swift       # Central orchestrator — owns ALL services & drivers
│   ├── DataDriver.swift        # DataDriver protocol + DriverConfig + DriverType enum
│   └── Database/
│       └── ConfigDatabase.swift # SQLite store for tags, alarms, driver configs
│   └── Drivers/
│       ├── OPCUAClientService.swift  # open62541 wrapper, polling, auto-reconnect
│       ├── MQTTDriver.swift
│       ├── ModbusDriver.swift
│       ├── ModbusSerialPort.swift
│       └── EtherNetIPDriver.swift
├── Models/
│   ├── Tag.swift               # Tag, TagValue, TagQuality, TagDataType, CompositeMember
│   ├── Alarm.swift             # Alarm, AlarmState (ISA-18.2)
│   ├── OPCUANode.swift
│   ├── OPCUADiscovery.swift
│   ├── Recipe.swift
│   ├── Operator.swift
│   ├── WriteRequest.swift
│   └── CommunityModels.swift
├── Services/
│   ├── TagEngine.swift         # Live tag store, LKG holdoff, deadband, historian batch
│   ├── Historian.swift         # SQLite time-series (actor-isolated async init)
│   ├── AlarmManager.swift      # ISA-18.2 alarm evaluation
│   ├── ExpressionEvaluator.swift # Expression parser for calculated tags
│   ├── RecipeStore.swift
│   ├── SchedulerService.swift + SchedulerModels.swift
│   ├── SessionManager.swift    # Operator auth, roles, inactivity timeout
│   ├── CommunityService.swift + CommunityPeerConnection.swift + CommunityServer.swift
│   ├── OPCUABonjourScanner.swift
│   ├── OPCUADiagnostics.swift
│   └── Historian.swift
├── HMI/
│   ├── Models/                 # HMIObject, HMIScreen, HMI3DModels
│   ├── Services/               # HMIScreenStore, HMI3DSceneStore
│   └── Views/
│       ├── 2D/                 # IndustrialSymbolCanvas
│       ├── 3D/                 # HMI3DDesignerView, SceneKitEquipmentBuilder
│       ├── HMICanvasView.swift
│       ├── HMIDesignerView.swift
│       └── HMIObjectView.swift
├── InfiniteCanvas/             # ProcessCanvasView, ProcessCanvasStore, ProcessCanvasModels
├── Multimodal/                 # SpeechInputService, SpeechOutputService, GestureInputService
├── Views/                      # All top-level SwiftUI views (MainView, MonitorView, etc.)
├── ViewModels/
│   └── OPCUABrowserViewModel.swift
└── Utilities/
    ├── Configuration.swift     # App-wide constants + UserDefaults-backed settings
    └── Logger.swift
Sources/COPC/                   # C-interop module for open62541
```

## Key Architecture Decisions

### Service Ownership
`DataService` is the single `@StateObject` that creates and owns ALL services. Individual services are injected as `@EnvironmentObject` into SwiftUI views. This is by design — do not create services elsewhere.

### Thread Safety
- All UI-facing services are `@MainActor`
- OPC-UA C API calls run on a dedicated serial `opcuaQueue` (DispatchQueue)
- `Historian` is a Swift `actor` (async init — wire up after `onHistorianReady` callback fires)
- `OPCUAHandle` wraps `OpaquePointer` as `@unchecked Sendable` — safe because only `opcuaQueue` touches the pointer

### Historian Async Init
`TagEngine.init()` starts an async `Task` to create `Historian`. Services that need historian (AlarmManager, RecipeStore, SchedulerService) receive it via the `onHistorianReady` callback — NOT in their own `init()`. Do not assume `tagEngine.historian` is non-nil synchronously.

### Write Confirmation Pattern
Two-phase operator writes:
1. `TagEngine.requestWrite()` → creates `WriteRequest`, appends to `pendingWriteRequests`
2. `DataService.confirmWrite()` → executes OPC-UA write, calls `resolveWrite()`, logs to audit trail

### Tag Types
| DataType | Description |
|---|---|
| `.analog` | Continuous float (temperature, pressure, level) |
| `.digital` | Binary on/off |
| `.string` | Text data |
| `.calculated` | Expression-based: `{TagA} + {TagB}`, IF/THEN/ELSE, math functions |
| `.totalizer` | Running accumulator: ∑(value × Δt) |
| `.composite` | Aggregation (avg/sum/min/max/AND/OR) across multiple driver tags |

### Expression Syntax (calculated tags)
- Tag refs: `{TagName}`
- Arithmetic: `+ - * /`
- Comparisons: `> < >= <= == !=`
- Logical: `&& || !`
- Ternary: `condition ? a : b`
- IF/THEN/ELSE: `IF {A} > 80 THEN 1 ELSE 0`
- Functions: `abs sqrt round floor ceil sign min max avg sum clamp if`

## Key Configuration (Configuration.swift)
| Setting | Default | Notes |
|---|---|---|
| `opcuaServerURL` | `""` (UserDefaults) | Set via Settings UI |
| `simulationMode` | `false` | Set `true` for dev without hardware |
| `verboseLogging` | `true` | Writes to `/tmp/hmi_diag.log` |
| `analogDeadband` | `0.1` | Suppress historian writes below this delta |
| `lkgHoldoffPolls` | `3` | Bad-quality polls before propagating to UI |
| `historianBatchSize` | `100` | Max pending writes before immediate flush |
| `historianWriteInterval` | `5.0s` | Batch flush interval |
| `pollingInterval` | `500ms` | OPC-UA read cycle |

## Database
- **Location:** `~/Library/Application Support/IndustrialHMI/historian.db`
- Tag configs, alarm configs, driver configs, historical values, write audit log all in one SQLite file.

## AgentService (Claude AI)
- Model: `claude-sonnet-4-6`
- Endpoint: `/v1/messages`
- Agentic loop: up to 20 iterations until `end_turn`
- 25+ HMI tool calls covering: tag CRUD, alarm management, write requests, recipe execution, HMI screen design, system status

## Protocols / Standards
- **OPC-UA** (IEC 62541) — primary data acquisition
- **ISA-18.2** — alarm management state machine
- **ISA-95** — enterprise-control integration model
- **IEC 61131-3** — control logic concepts

## Single-Instance Enforcement
Lock file at `/tmp/IndustrialHMI.lock` (PID file). On duplicate launch: alert → SIGTERM old PID → SIGKILL after 2s if needed.

## Diagnostic Log
`/tmp/hmi_diag.log` — written by `diagLog()` global function when `Configuration.verboseLogging = true`.

## Performance Targets (MVP)
- 500 analog + 200 digital tags
- 1 Hz scan rate
- Tag latency < 100ms
- Memory < 500MB steady-state
- CPU < 15% (M2 Mac Mini)
