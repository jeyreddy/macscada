# Industrial HMI for macOS

A native macOS application for industrial process control and monitoring, built with Swift and SwiftUI.

## Overview

This is a software-based Distributed Control System (DCS) designed to replace Windows-based SCADA/HMI systems with a native macOS solution that provides:

- **Real-time data acquisition** via OPC-UA protocol
- **Native SwiftUI HMI** with trend displays and alarms
- **Historical data storage** using SQLite time-series database
- **Object-oriented control** with device templates
- **Superior security** leveraging macOS architecture

## Project Structure

```
IndustrialHMI/
├── Package.swift                    # Swift Package Manager configuration
├── README.md                        # This file
├── ARCHITECTURE.md                  # Technical architecture document
├── .gitignore                       # Git ignore rules
├── Sources/
│   └── IndustrialHMI/
│       ├── IndustrialHMIApp.swift  # Main app entry point
│       ├── Models/                  # Data models
│       │   ├── Tag.swift           # Tag data structure
│       │   ├── Alarm.swift         # Alarm configuration
│       │   └── DeviceTemplate.swift # Device template protocol
│       ├── Services/                # Business logic layer
│       │   ├── OPCUAClientService.swift  # OPC-UA connection manager
│       │   ├── TagEngine.swift           # Real-time tag database
│       │   ├── Historian.swift           # SQLite time-series storage
│       │   └── AlarmManager.swift        # Alarm detection & management
│       ├── Views/                   # SwiftUI user interface
│       │   ├── MainView.swift      # Main application window
│       │   ├── TagTableView.swift  # Live tag value display
│       │   ├── TrendView.swift     # Real-time trend charts
│       │   ├── AlarmListView.swift # Alarm list with filtering
│       │   └── DeviceFaceplateView.swift  # Device graphics
│       └── Utilities/               # Helper functions
│           ├── Logger.swift        # Application logging
│           └── Configuration.swift # App configuration
└── Tests/
    └── IndustrialHMITests/
        ├── TagEngineTests.swift
        ├── AlarmManagerTests.swift
        └── HistorianTests.swift
```

## System Requirements

### Development
- **macOS:** 13.0 (Ventura) or later
- **Xcode:** 15.0 or later
- **Swift:** 5.9 or later
- **Homebrew:** For installing dependencies

### Runtime
- **macOS:** 13.0 or later
- **Hardware:** Mac Mini M2/M4 recommended for production
- **Network:** Ethernet connection to OPC-UA server

## Dependencies

### External Libraries
1. **SQLite.swift** (via Swift Package Manager)
   - Type-safe SQLite wrapper
   - Automatically downloaded by SPM

2. **open62541** (via Homebrew)
   - OPC-UA protocol stack (C library)
   - Install: `brew install open62541`

### Optional Tools
- **Prosys OPC UA Simulation Server** - For testing/development
- **UaExpert** - OPC-UA client for debugging connections

## Installation & Setup

### 1. Install Prerequisites

```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install open62541 OPC-UA library
brew install open62541

# Verify installation
ls /opt/homebrew/include/open62541/
```

### 2. Clone or Download Project

```bash
# If using Git
git clone <repository-url>
cd IndustrialHMI

# Or extract from ZIP
unzip IndustrialHMI.zip
cd IndustrialHMI
```

### 3. Open in Xcode

```bash
# Option A: Open Package.swift directly
open Package.swift

# Option B: Generate Xcode project (optional)
swift package generate-xcodeproj
open IndustrialHMI.xcodeproj
```

### 4. Configure Build Settings

In Xcode:
1. Select **IndustrialHMI** target
2. Go to **Build Settings** tab
3. Verify these settings:

**Header Search Paths:**
- Add: `/opt/homebrew/include` (for open62541 headers)

**Library Search Paths:**
- Add: `/opt/homebrew/lib` (for open62541 library)

**Other Linker Flags:**
- Add: `-lopen62541`

### 5. Install OPC-UA Test Server

Download and install **Prosys OPC UA Simulation Server**:
- URL: https://www.prosysopc.com/products/opc-ua-simulation-server/
- Get free trial license
- Configure 20 test tags (10 analog, 10 digital)
- Start server on `opc.tcp://localhost:4840`

### 6. Build and Run

```bash
# Build from command line
swift build

# Or press ⌘R in Xcode to build and run
```

## Configuration

### OPC-UA Server Settings

Edit `Sources/IndustrialHMI/Utilities/Configuration.swift`:

```swift
struct Configuration {
    static let opcuaServerURL = "opc.tcp://localhost:4840"
    static let connectionTimeout: TimeInterval = 30
    static let subscriptionInterval: TimeInterval = 1.0  // 1 second
}
```

### Database Location

By default, SQLite database is stored at:
```
~/Library/Application Support/IndustrialHMI/historian.db
```

Change in `Historian.swift` if needed.

## Development Workflow

### Week 1-2: Foundation
- [x] Project structure created
- [ ] OPC-UA client service implemented
- [ ] Basic tag engine working
- [ ] Live tag display in SwiftUI

### Week 3-4: Data Persistence
- [ ] SQLite historian implemented
- [ ] Real-time trend charts working
- [ ] Historical data queries functional

### Week 5-6: Alarming
- [ ] Alarm manager implemented
- [ ] Alarm list view created
- [ ] Audio/visual notifications working

### Week 7-8: Device Templates
- [ ] Device template framework built
- [ ] Tank level device template created
- [ ] Control logic executing

### Week 9-10: Polish
- [ ] User authentication added
- [ ] Configuration save/load working
- [ ] Error handling robust

### Week 11-12: Stability Testing
- [ ] 7-day continuous operation test
- [ ] Memory leak testing
- [ ] Documentation complete

## Testing

### Run Unit Tests
```bash
# Command line
swift test

# Or in Xcode: ⌘U
```

### Integration Testing
1. Start Prosys OPC UA Simulation Server
2. Run app and verify connection
3. Check live tag updates
4. Trigger alarms by changing values
5. Verify historical data storage

## Troubleshooting

### "open62541 not found" Error
```bash
# Verify open62541 is installed
brew list open62541

# If not installed
brew install open62541

# Add to Xcode Header Search Paths:
/opt/homebrew/include
```

### "Connection failed" to OPC-UA Server
```bash
# Check server is running
lsof -i :4840

# Test with UaExpert first before debugging Swift code
```

### SwiftUI Preview Crashes
```bash
# Disable if causing issues - run on actual Mac instead
# SwiftUI previews don't work well with C interop
```

## Performance Targets

### MVP (Month 3)
- **Tags:** 500 analog, 200 digital
- **Scan Rate:** 1 Hz (1000ms cycle)
- **Tag Latency:** < 100ms
- **Memory:** < 500MB steady-state
- **CPU:** < 15% average (M2 Mac Mini)

## Security

### Current (MVP)
- Local authentication via macOS user accounts
- File permissions restrict config access
- No network exposure (local only)

### Future (Post-MVP)
- OPC-UA username/password authentication
- TLS encrypted sessions
- Role-based access control (RBAC)
- Audit trail logging

## License

Proprietary - Commercial use requires license agreement.

## Authors

**Jagan** - ISA Fellow, 25+ years industrial automation experience
- Former Principal Engineer, Honeywell Process Solutions
- 10 patents in control systems
- 3 authored books on instrumentation & control

## Contact

For questions, issues, or collaboration:
- Email: [your-email@example.com]
- LinkedIn: [your-linkedin-profile]

## References

- **UCOS (TechnipFMC):** Inspiration for architecture
- **OPC Foundation:** OPC-UA specification
- **ISA-95:** Enterprise-control system integration standards
- **IEC 61131-3:** Programmable controller programming languages

## Acknowledgments

- **Anthropic (Claude):** AI assistance in architecture and development
- **Apple:** Swift language and SwiftUI framework
- **open62541 Project:** OPC-UA implementation
- **Stephen Celis:** SQLite.swift library

---

**Last Updated:** January 30, 2026  
**Version:** 0.1.0 (Pre-release)
