# Industrial HMI - Quick Start Guide

## Prerequisites Installation (20 minutes)

### Step 1: Install Xcode
If not already installed:
```bash
# Open App Store
open -a "App Store"
# Search for Xcode and install (or update to latest)
```

### Step 2: Install Homebrew
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Step 3: Install open62541 (OPC-UA Library)
```bash
# Install the OPC-UA C library
brew install open62541

# Verify installation
ls /opt/homebrew/include/open62541/
# Should show: client.h, client_config.h, etc.

ls /opt/homebrew/lib | grep open62541
# Should show: libopen62541.dylib
```

### Step 4: Install OPC-UA Test Server
1. Download Prosys OPC UA Simulation Server:
   - URL: https://www.prosysopc.com/products/opc-ua-simulation-server/
   - Download the macOS version
   - Install the application
   - Request free trial license (via email)

2. Configure Prosys Server:
   - Launch the application
   - Click "Options" → "Server Endpoints"
   - Ensure endpoint is: `opc.tcp://localhost:4840`
   - Go to "Simulation" tab
   - Click "Add Simulation"
   - Add these simulation nodes:
     * 5 Temperature tags (Random range: 240-260)
     * 5 Pressure tags (Random range: 120-130)
     * 5 Level tags (Random range: 70-90)
     * 5 Digital status tags (Boolean random)
   - Click "Start" to begin simulation

### Step 5: Install UaExpert (Optional but Recommended)
```bash
# Download from:
open https://www.unified-automation.com/downloads/opc-ua-clients.html

# Install UaExpert-macOS.dmg
# This tool lets you browse and test OPC-UA connections
```

## Project Setup (10 minutes)

### Step 1: Open Project in Xcode
```bash
cd /path/to/IndustrialHMI
open Package.swift
```

Xcode will open and automatically resolve Swift Package Manager dependencies.

### Step 2: Configure Build Settings

**CRITICAL:** You must add open62541 library paths to Xcode:

1. In Xcode, select the **IndustrialHMI** project in the navigator
2. Select the **IndustrialHMI** target
3. Go to **Build Settings** tab
4. Search for "Header Search Paths"
   - Add: `/opt/homebrew/include`
5. Search for "Library Search Paths"
   - Add: `/opt/homebrew/lib`
6. Search for "Other Linker Flags"
   - Add: `-lopen62541`

**Verify Build Settings:**
```
Header Search Paths: /opt/homebrew/include
Library Search Paths: /opt/homebrew/lib
Other Linker Flags: -lopen62541
```

### Step 3: Resolve Dependencies

Xcode should automatically download SQLite.swift package.

If not:
1. File → Add Package Dependencies
2. Enter URL: `https://github.com/stephencelis/SQLite.swift`
3. Click "Add Package"

### Step 4: Build the Project

```bash
# Option A: Build from Xcode
# Press: ⌘B (Command+B)

# Option B: Build from terminal
swift build
```

**Expected Output:**
```
Building for debugging...
[1/1] Compiling IndustrialHMI...
Build complete!
```

### Step 5: Run the Application

```bash
# Option A: Run from Xcode
# Press: ⌘R (Command+R)

# Option B: Run from terminal
swift run
```

## Verify Installation (5 minutes)

### Check 1: Application Launches
- Industrial HMI window should open
- You should see the sidebar with tabs: Overview, Tags, Trends, Alarms, etc.

### Check 2: Simulated Data Flowing
- Click "Tags" in sidebar
- You should see 5 sample tags with values updating every 1 second
- Values should be changing (this is simulation mode)

### Check 3: Test Connection to Prosys (When Ready)
1. In `Configuration.swift`, set:
   ```swift
   static let simulationMode = false
   ```
2. Rebuild and run
3. Toolbar should show green "Connected" indicator
4. Tags should update with real OPC-UA data from Prosys

## Troubleshooting

### Problem: "open62541 not found" error
**Solution:**
```bash
# Reinstall open62541
brew reinstall open62541

# Verify paths
echo /opt/homebrew/include/open62541
echo /opt/homebrew/lib/libopen62541.dylib

# Both should exist
```

### Problem: "Cannot find 'SQLite' in scope"
**Solution:**
1. File → Add Package Dependencies
2. URL: `https://github.com/stephencelis/SQLite.swift`
3. Add to IndustrialHMI target

### Problem: Build succeeds but app won't run
**Solution:**
Check Console for errors:
```bash
# Open Console.app
open -a Console

# Filter for "IndustrialHMI"
# Look for crash logs or error messages
```

### Problem: Cannot connect to OPC-UA server
**Solution:**
```bash
# 1. Verify Prosys is running
lsof -i :4840
# Should show: Prosys OPC UA Simulation Server

# 2. Test with UaExpert first
# Open UaExpert
# Add Server: opc.tcp://localhost:4840
# If UaExpert can't connect, problem is with Prosys, not our app
```

### Problem: No tags showing in table
**Solution:**
1. Ensure `Configuration.simulationMode = true` for testing without OPC-UA
2. Check TagEngine initialization in logs
3. Verify sample tags loaded: Should show 5 tags

## Next Steps

### Week 1 Tasks:
- [x] Project setup complete
- [ ] Implement real OPC-UA client (replace simulation)
- [ ] Connect to Prosys and read live tags
- [ ] Display live OPC-UA data in TagTableView

### Resources:
- **open62541 Documentation:** https://open62541.org/doc/current/
- **OPC-UA Specification:** https://opcfoundation.org/developer-tools/specifications-unified-architecture
- **Swift Documentation:** https://docs.swift.org/swift-book/
- **SwiftUI Tutorial:** https://developer.apple.com/tutorials/swiftui

## Getting Help

If you encounter issues:
1. Check logs in `/var/log/system.log`
2. Review Console.app for runtime errors
3. Verify all prerequisites installed correctly
4. Test OPC-UA connection with UaExpert first

## Development Tips

### Enable Verbose Logging
In `Configuration.swift`:
```swift
static let verboseLogging = true
```

### Test Without OPC-UA Server
Keep simulation mode enabled:
```swift
static let simulationMode = true
```

### Quick Rebuild
```bash
# Clean build folder
rm -rf .build/

# Rebuild
swift build
```

---

**You're ready to start development!**

Next: Begin implementing OPC-UA client integration in Week 1.
