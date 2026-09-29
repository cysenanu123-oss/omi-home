#!/bin/bash
set -e

###############################################################################
# RESET AND RUN SCRIPT FOR OMI DESKTOP DEVELOPMENT
###############################################################################
#
# This script builds and runs the Omi Desktop app with a clean slate for testing.
# It handles permission resets, app cleanup, and backend services.
#
# PLATFORM SUPPORT:
# =============================================================================
# - macOS  : Full support — Swift app build, sign, install, and launch.
# - Linux  : Partial — Rust backend + acp-bridge + Cloudflare tunnel only.
#            The Swift desktop app is macOS-only and those steps are skipped.
# - Windows: Partial (via WSL, Git Bash, or MSYS2) — same as Linux above.
#            Run this script inside WSL for best compatibility.
#
# CRITICAL (macOS): ORDER OF OPERATIONS MATTERS!
# =============================================================================
# The sequence below was determined through extensive debugging. DO NOT change
# the order without understanding why it matters.
#
# CORRECT ORDER (macOS):
#   1. Kill app processes
#   2. Reset TCC permissions (while app STILL EXISTS in /Applications)
#   3. Delete app bundles
#   4. Reset Launch Services
#   5. Build new app
#   6. Install to /Applications
#   7. Reset UserDefaults
#   8. Launch app
#
# WHY THIS ORDER MATTERS:
# -----------------------
# - tccutil reset requires the app to exist to properly resolve the bundle ID.
#   If you delete the app first, tccutil silently fails to reset permissions.
#   This was discovered after hours of debugging where permissions appeared
#   "stuck" even after running tccutil.
#
# - The app must be killed BEFORE resetting TCC, otherwise the running app
#   may re-acquire permissions immediately.
#
# MACOS TCC (TRANSPARENCY, CONSENT, CONTROL) NOTES:
# =============================================================================
# - User TCC database: ~/Library/Application Support/com.apple.TCC/TCC.db
#   Contains: Microphone, AudioCapture, AppleEvents, Accessibility
#   Can be modified with: tccutil reset, sqlite3 DELETE
#
# - System TCC database: /Library/Application Support/com.apple.TCC/TCC.db
#   Contains: ScreenCapture (Screen Recording)
#   PROTECTED BY SIP - cannot be modified directly, even with sudo
#   Can only be reset via: tccutil reset ScreenCapture <bundle-id>
#   Or manually removed in: System Settings > Privacy & Security > Screen Recording
#
# - CGPreflightScreenCaptureAccess() can return STALE data after app rebuilds.
#   It may say "true" when the permission is actually invalid for the new binary.
#
# - ScreenCaptureKit (macOS 14+) has its OWN consent separate from TCC.
#   SCShareableContent.excludingDesktopWindows() triggers this consent dialog.
#   Don't call it repeatedly - it will show the dialog each time if not granted.
#
# LAUNCH SERVICES POLLUTION:
# =============================================================================
# Launch Services caches app metadata (bundle ID, name, icon) from ALL apps it
# sees, including:
#   - DMG staging directories in /private/tmp
#   - Mounted DMG volumes (/Volumes/Omi Computer, /Volumes/dmg.*)
#   - Apps in Trash
#   - Xcode DerivedData builds
#
# If multiple apps with the same bundle ID exist (even in Trash!), macOS gets
# confused and may:
#   - Show wrong app name in System Settings (e.g., "Omi Computer.app" with .app)
#   - Show generic icon instead of actual app icon
#   - Grant permissions to the wrong app
#
# SOLUTION: Clean up ALL these locations before building:
#   - /private/tmp/omi-dmg-staging-*
#   - ~/.Trash/Omi*, ~/.Trash/OMI*
#   - Mounted volumes: /Volumes/Omi*, /Volumes/dmg.*
#   - Xcode DerivedData Omi builds
#
# The lsregister -kill command is supposed to rebuild the database but is
# disabled on modern macOS. A reboot may be needed for complete cleanup.
#
# DEBUGGING TIPS:
# =============================================================================
# Check TCC entries:
#   sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
#     "SELECT service, client, auth_value FROM access WHERE client LIKE '%omi%';"
#
# Check Launch Services registrations:
#   lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
#   $lsregister -dump | grep -A20 "com.omi.computer-macos"
#
# Check screen recording permission:
#   swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'
#
# Manually reset all TCC for a bundle:
#   tccutil reset All com.omi.desktop-dev
#
###############################################################################

# =============================================================================
# OS DETECTION
# =============================================================================
OS="$(uname -s)"

is_macos()   { [ "$OS" = "Darwin" ]; }
is_linux()   { [[ "$OS" == Linux* ]]; }
is_windows() { [[ "$OS" == CYGWIN* || "$OS" == MINGW* || "$OS" == MSYS* ]]; }

if is_macos; then
    PLATFORM="macOS"
elif is_linux; then
    PLATFORM="Linux"
elif is_windows; then
    PLATFORM="Windows"
else
    PLATFORM="Unknown ($OS)"
fi

echo "Platform detected: $PLATFORM"
if ! is_macos; then
    echo ""
    echo "NOTE: This is not macOS. The Swift desktop app and all macOS-specific"
    echo "      steps (TCC reset, codesign, lsregister, etc.) will be skipped."
    echo "      The Rust backend, acp-bridge, and Cloudflare tunnel will run normally."
    echo ""
fi

# =============================================================================
# BINARY EXTENSION (Windows needs .exe)
# =============================================================================
EXT=""
is_windows && EXT=".exe"

# =============================================================================
# ENVIRONMENT
# =============================================================================

# Clear system OPENAI_API_KEY so .env takes precedence
unset OPENAI_API_KEY

# Use Xcode's default toolchain to match the SDK version (macOS only)
if is_macos; then
    unset TOOLCHAINS
fi

# =============================================================================
# APP CONFIGURATION (macOS only)
# =============================================================================
BINARY_NAME="Omi Computer"  # Package.swift target — binary paths, pkill, CFBundleExecutable
APP_NAME="Omi Dev"
BUNDLE_ID="com.omi.desktop-dev"
BUNDLE_ID_PROD="com.omi.computer-macos"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"

# Auto-detect signing identity (macOS only)
SIGN_IDENTITY=""
if is_macos; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    fi
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "ERROR: No signing identity found"
        exit 1
    fi
    echo "Signing identity: $SIGN_IDENTITY"
fi

# =============================================================================
# BACKEND CONFIGURATION (Rust — cross-platform)
# =============================================================================
BACKEND_DIR="$(dirname "$0")/Backend-Rust"
BACKEND_BINARY="target/release/omi-desktop-backend${EXT}"
BACKEND_PID=""
TUNNEL_PID=""
TUNNEL_URL="${TUNNEL_URL:-}"

# =============================================================================
# CLEANUP FUNCTION
# =============================================================================
cleanup() {
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "Stopping tunnel (PID: $TUNNEL_PID)..."
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# =============================================================================
# STEP 1: KILL EXISTING INSTANCES
# =============================================================================
echo "Killing existing instances..."

# Kill the app (macOS only — it's a .app bundle)
if is_macos; then
    pkill -f "$APP_NAME.app" 2>/dev/null || true
fi

# Kill whatever is using port 8080 — cross-platform
kill_port() {
    local port="${1:-8080}"
    if is_macos || is_linux; then
        # lsof works on both macOS and Linux
        lsof -ti:"$port" 2>/dev/null | xargs kill -9 2>/dev/null || \
        fuser -k "${port}/tcp" 2>/dev/null || true
    elif is_windows; then
        # Windows (Git Bash / MSYS2): use netstat + taskkill
        netstat -ano 2>/dev/null | grep ":${port} " | awk '{print $5}' | sort -u | \
            xargs -I{} taskkill /PID {} /F 2>/dev/null || true
    fi
}
kill_port 8080

# Clear log file for fresh run
LOG_FILE="/tmp/omi.log"
rm -f "$LOG_FILE" 2>/dev/null || true

# =============================================================================
# STEP 2: RESET TCC PERMISSIONS (macOS only)
# =============================================================================
if is_macos; then
    # CRITICAL: This MUST happen BEFORE deleting the app from /Applications!
    # tccutil needs the app to exist to resolve the bundle ID.
    echo "Resetting TCC permissions (before deleting apps)..."
    tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset All "$BUNDLE_ID_PROD" 2>/dev/null || true

    # Belt-and-suspenders: Also clean user TCC database directly via sqlite3
    sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
        "DELETE FROM access WHERE client LIKE '%com.omi.computer-macos%';" 2>/dev/null || true
    sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
        "DELETE FROM access WHERE client LIKE '%com.omi.desktop%';" 2>/dev/null || true
else
    # =========================================================================
    # LINUX / WINDOWS: RESET APP PERMISSIONS & CLEAR STALE DATA
    # =========================================================================
    #
    # macOS has TCC (Transparency, Consent & Control) for microphone, screen
    # capture, and accessibility — stored in a SQLite database. Linux and
    # Windows have their own equivalents:
    #
    # Linux: permissions are managed by the kernel, PulseAudio/Pipewire, and
    #        the desktop environment. Clearing cached app data and .desktop
    #        entries is the equivalent of resetting TCC.
    #
    # Windows: Privacy settings live in the registry under
    #   HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager
    #   We call PowerShell (from inside WSL or Git Bash) to reset them.
    #

    # Detect WSL so we can invoke Windows PowerShell for registry operations
    IS_WSL=false
    if is_linux && grep -qi microsoft /proc/version 2>/dev/null; then
        IS_WSL=true
    fi

    # -----------------------------------------------------------------
    # LINUX: clear Omi app config / data directories
    # (equivalent of macOS 'defaults delete com.omi.desktop-dev')
    # -----------------------------------------------------------------
    echo "Clearing Omi app config/data directories..."
    rm -rf \
        "$HOME/.config/omi-dev" \
        "$HOME/.config/omi" \
        "$HOME/.config/com.omi.desktop-dev" \
        "$HOME/.config/com.omi.computer-macos" \
        "$HOME/.local/share/omi-dev" \
        "$HOME/.local/share/omi" \
        "$HOME/.local/share/com.omi.desktop-dev" \
        2>/dev/null || true

    # -----------------------------------------------------------------
    # LINUX: check audio group membership
    # (equivalent of macOS microphone TCC grant)
    # -----------------------------------------------------------------
    if is_linux && [ -d /dev/snd ]; then
        if groups 2>/dev/null | grep -qE '\baudio\b|\bpulseaudio\b|\bpipewire\b'; then
            echo "Audio group: OK"
        else
            echo "WARNING: User '$USER' is not in the 'audio' group."
            echo "         Microphone access may be denied."
            echo "         Fix: sudo usermod -aG audio $USER   (then log out and back in)"
        fi
    fi

    # -----------------------------------------------------------------
    # LINUX: open port 8080 in the local firewall
    # (equivalent of macOS granting network access to the app)
    # -----------------------------------------------------------------
    if is_linux; then
        echo "Configuring local firewall for backend port 8080..."
        if command -v ufw >/dev/null 2>&1; then
            sudo ufw allow 8080/tcp 2>/dev/null && echo "  ufw: port 8080 allowed" || \
                echo "  ufw: could not update rules (try: sudo ufw allow 8080/tcp)"
        elif command -v firewall-cmd >/dev/null 2>&1; then
            sudo firewall-cmd --add-port=8080/tcp --permanent 2>/dev/null && \
            sudo firewall-cmd --reload 2>/dev/null && echo "  firewalld: port 8080 allowed" || true
        elif command -v iptables >/dev/null 2>&1; then
            sudo iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || \
            sudo iptables -I INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null && \
                echo "  iptables: port 8080 allowed" || true
        else
            echo "  No firewall tool found (ufw/firewalld/iptables) — skipping"
        fi
    fi

    # -----------------------------------------------------------------
    # WINDOWS (via WSL): reset Privacy permissions + Firewall + app data
    # (equivalent of macOS tccutil reset + defaults delete)
    # -----------------------------------------------------------------
    if $IS_WSL; then
        echo "Applying Windows-side permission resets via PowerShell..."

        # Resolve Windows username and AppData paths accessible from WSL
        WIN_USER=$(powershell.exe -NoProfile -Command \
            "[System.Environment]::UserName" 2>/dev/null | tr -d '\r')
        WIN_APPDATA="/mnt/c/Users/$WIN_USER/AppData/Roaming"
        WIN_LOCALAPPDATA="/mnt/c/Users/$WIN_USER/AppData/Local"

        # -- 1. Microphone privacy (CapabilityAccessManager registry key) --
        echo "  Resetting Windows microphone privacy settings..."
        powershell.exe -NoProfile -Command "
            \$micPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            if (Test-Path \$micPath) {
                Get-ChildItem \$micPath |
                    Where-Object { \$_.Name -like '*omi*' -or \$_.Name -like '*Omi*' } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path \$micPath -Name 'Value' -Value 'Allow' -ErrorAction SilentlyContinue
                Write-Host '  Microphone: reset to Allow'
            } else {
                Write-Host '  Microphone: registry path not found (likely unrestricted)'
            }
        " 2>/dev/null || echo "  WARNING: could not reset microphone permissions"

        # -- 2. Camera privacy ---------------------------------------------
        echo "  Resetting Windows camera privacy settings..."
        powershell.exe -NoProfile -Command "
            \$camPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
            if (Test-Path \$camPath) {
                Get-ChildItem \$camPath |
                    Where-Object { \$_.Name -like '*omi*' -or \$_.Name -like '*Omi*' } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path \$camPath -Name 'Value' -Value 'Allow' -ErrorAction SilentlyContinue
                Write-Host '  Camera: reset to Allow'
            } else {
                Write-Host '  Camera: registry path not found'
            }
        " 2>/dev/null || echo "  WARNING: could not reset camera permissions"

        # -- 3. Windows Firewall — inbound rule for backend port 8080 ------
        echo "  Adding Windows Firewall inbound rule for port 8080..."
        powershell.exe -NoProfile -Command "
            \$ruleName = 'Omi Desktop Backend (port 8080)'
            Remove-NetFirewallRule -DisplayName \$ruleName -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName \$ruleName -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
            Write-Host '  Firewall: inbound TCP 8080 rule added'
        " 2>/dev/null || \
        powershell.exe -NoProfile -Command "
            netsh advfirewall firewall delete rule name='Omi Desktop Backend (port 8080)' 2>\$null
            netsh advfirewall firewall add rule name='Omi Desktop Backend (port 8080)' dir=in action=allow protocol=TCP localport=8080
            Write-Host '  Firewall: rule added (netsh fallback)'
        " 2>/dev/null || echo "  WARNING: could not add firewall rule (try running terminal as Administrator)"

        # -- 4. Clear Windows-side Omi app data ----------------------------
        echo "  Clearing Windows Omi app data..."
        rm -rf \
            "$WIN_APPDATA/Omi"* \
            "$WIN_APPDATA/com.omi"* \
            "$WIN_LOCALAPPDATA/Omi"* \
            "$WIN_LOCALAPPDATA/com.omi"* \
            2>/dev/null || true
        echo "  App data cleared"

        # -- 5. Remove stale Windows URL scheme registry keys --------------
        # (equivalent of macOS lsregister cleanup)
        echo "  Removing stale Windows URL scheme registrations..."
        powershell.exe -NoProfile -Command "
            \$schemes = @('omi-computer-dev', 'omi-computer', 'omi')
            foreach (\$s in \$schemes) {
                \$key = \"HKCU:\SOFTWARE\Classes\\\$s\"
                if (Test-Path \$key) {
                    Remove-Item -Path \$key -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host \"  Removed URL scheme: \${s}://\"
                }
            }
        " 2>/dev/null || true
    fi
fi

# =============================================================================
# STEP 3: DELETE ALL CONFLICTING APP BUNDLES (macOS only)
# =============================================================================
if is_macos; then
    echo "Cleaning up conflicting app bundles..."
    CONFLICTING_APPS=(
        "/Applications/Omi.app"
        "/Applications/Omi Computer.app"
        "/Applications/Omi Dev.app"
        "$APP_BUNDLE"  # Local build folder
        "$HOME/Desktop/Omi.app"
        "$HOME/Downloads/Omi.app"
        # Flutter app builds (with and without -prod suffix)
        "$(dirname "$0")/../omi/app/build/macos/Build/Products/Debug/Omi.app"
        "$(dirname "$0")/../omi/app/build/macos/Build/Products/Release/Omi.app"
        "$(dirname "$0")/../omi/app/build/macos/Build/Products/Debug-prod/Omi.app"
        "$(dirname "$0")/../omi/app/build/macos/Build/Products/Release-prod/Omi.app"
        "$(dirname "$0")/../omi-computer/build/macos/Build/Products/Debug/Omi.app"
        "$(dirname "$0")/../omi-computer/build/macos/Build/Products/Release/Omi.app"
    )

    echo "Scanning for stale Omi Dev.app in other locations..."
    find "$HOME" -maxdepth 4 -name "Omi Dev.app" -type d \
        -not -path "$APP_BUNDLE" -not -path "$APP_PATH" 2>/dev/null | while read stale; do
        echo "  Removing stale clone: $stale"
        rm -rf "$stale"
    done

    echo "Cleaning Xcode DerivedData..."
    for app_name in "Omi.app" "Omi Computer.app" "Omi Dev.app"; do
        find "$HOME/Library/Developer/Xcode/DerivedData" -name "$app_name" -type d 2>/dev/null | while read app; do
            echo "  Removing: $app"
            rm -rf "$app"
        done
    done

    echo "Cleaning DMG staging directories..."
    rm -rf /private/tmp/omi-dmg-staging-* /private/tmp/omi-dmg-test-* 2>/dev/null || true

    echo "Cleaning Omi apps from Trash..."
    rm -rf "$HOME/.Trash/OMI"* "$HOME/.Trash/Omi"* 2>/dev/null || true

    echo "Ejecting mounted Omi DMG volumes..."
    for vol in /Volumes/Omi* /Volumes/OMI* /Volumes/dmg.*; do
        if [ -d "$vol" ]; then
            echo "  Ejecting: $vol"
            diskutil eject "$vol" 2>/dev/null || hdiutil detach "$vol" 2>/dev/null || true
        fi
    done

    for app in "${CONFLICTING_APPS[@]}"; do
        if [ -d "$app" ]; then
            echo "  Removing: $app"
            rm -rf "$app"
        fi
    done
else
    # =========================================================================
    # LINUX / WINDOWS: REMOVE STALE APP REGISTRATIONS
    # =========================================================================
    # macOS has .app bundles registered in LaunchServices. On Linux the
    # equivalent is .desktop files in ~/.local/share/applications/ and the
    # XDG MIME database. On Windows (WSL) URL scheme keys were cleaned in
    # Step 2 above — nothing more needed here.
    #
    if is_linux; then
        echo "Removing stale Omi .desktop / MIME entries..."
        rm -f \
            "$HOME/.local/share/applications/omi"*.desktop \
            "$HOME/.local/share/applications/com.omi"*.desktop \
            2>/dev/null || true

        # Rebuild desktop entry DB so the OS forgets the stale entries
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
            echo "  Desktop database updated"
        fi
        # Clear any XDG MIME default handler pointing at old Omi entries
        if command -v xdg-mime >/dev/null 2>&1; then
            xdg-mime default /dev/null x-scheme-handler/omi-computer-dev 2>/dev/null || true
            xdg-mime default /dev/null x-scheme-handler/omi-computer    2>/dev/null || true
        fi
    fi
    # Windows: URL scheme keys already removed in Step 2.
fi

# =============================================================================
# STEP 4: RESET LAUNCH SERVICES DATABASE (macOS only)
# =============================================================================
if is_macos; then
    echo "Resetting Launch Services database..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -kill -r -domain local -domain user 2>/dev/null || true
else
    # =========================================================================
    # LINUX: REFRESH XDG MIME / APPLICATION DATABASE
    # =========================================================================
    # macOS resets its Launch Services DB with lsregister -kill.
    # On Linux, the equivalent is rebuilding the XDG MIME + app cache.
    # (The .desktop entries were removed in Step 3 above.)
    if is_linux; then
        echo "Refreshing XDG MIME/application cache..."
        if command -v update-mime-database >/dev/null 2>&1; then
            update-mime-database "$HOME/.local/share/mime" 2>/dev/null || true
            echo "  MIME database refreshed"
        fi
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache "$HOME/.local/share/icons" 2>/dev/null || true
        fi
    fi
    # Windows: registry URL scheme cleanup was handled in Step 2.
fi

# =============================================================================
# STEP 5: START CLOUDFLARE TUNNEL (cross-platform)
# =============================================================================
if command -v cloudflared >/dev/null 2>&1; then
    echo "Starting Cloudflare quick tunnel..."
    TUNNEL_LOG=$(mktemp /tmp/cloudflared-XXXXXX.log)
    cloudflared tunnel --url http://localhost:8080 > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    for i in {1..20}; do
        TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then break; fi
        sleep 0.5
    done
    if [ -n "$TUNNEL_URL" ]; then
        rm -f "$TUNNEL_LOG"
    else
        echo "Warning: Could not get tunnel URL — using localhost (see $TUNNEL_LOG for details)"
        TUNNEL_URL="http://localhost:8080"
    fi
else
    echo "cloudflared not found — skipping tunnel"
    TUNNEL_URL="http://localhost:8080"
fi

# =============================================================================
# STEP 6: START RUST BACKEND (cross-platform)
# =============================================================================
echo "Starting Rust backend..."
cd "$BACKEND_DIR"

# Copy .env if not present
if [ ! -f ".env" ] && [ -f "../Backend/.env" ]; then
    cp "../Backend/.env" ".env"
fi

# Symlink google-credentials.json if not present (skip on Windows — symlinks need admin)
if [ ! -f "google-credentials.json" ] && [ -f "../Backend/google-credentials.json" ]; then
    if is_windows; then
        cp "../Backend/google-credentials.json" "google-credentials.json"
    else
        ln -sf "../Backend/google-credentials.json" "google-credentials.json"
    fi
fi

# Build if binary doesn't exist or source is newer
if [ ! -f "$BACKEND_BINARY" ] || [ -n "$(find src -newer "$BACKEND_BINARY" 2>/dev/null)" ]; then
    echo "Building Rust backend..."
    cargo build --release
fi

./"$BACKEND_BINARY" &
BACKEND_PID=$!
cd - > /dev/null

# Wait for backend to be ready
echo "Waiting for backend to start..."
for i in {1..30}; do
    if curl -s http://localhost:8080 > /dev/null 2>&1; then
        echo "Backend is ready!"
        break
    fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Backend failed to start"
        exit 1
    fi
    sleep 0.5
done

# =============================================================================
# STEP 7: BUILD ACP-BRIDGE (cross-platform)
# =============================================================================
echo "Building acp-bridge..."
ACP_BRIDGE_DIR="$(dirname "$0")/acp-bridge"
if [ -d "$ACP_BRIDGE_DIR" ]; then
    cd "$ACP_BRIDGE_DIR"
    if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules/.package-lock.json" ]; then
        npm install --no-fund --no-audit 2>&1 | tail -1
    fi
    npx tsc
    cd - > /dev/null
fi

# =============================================================================
# STEP 8: BUILD + INSTALL SWIFT APP (macOS only)
# =============================================================================
if is_macos; then
    # Build debug
    echo "Building app..."
    xcrun swift build -c debug --package-path Desktop

    # Remove old app bundles to avoid permission issues with signed apps
    rm -rf "$APP_BUNDLE" "$BUILD_DIR/Omi Computer.app"

    # Create app bundle
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    # Copy binary
    cp "Desktop/.build/debug/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

    # Add rpath for Frameworks folder (needed for Sparkle)
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

    # Copy Sparkle framework (keep original signatures intact)
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    SPARKLE_FRAMEWORK="Desktop/.build/arm64-apple-macosx/debug/Sparkle.framework"
    if [ -d "$SPARKLE_FRAMEWORK" ]; then
        rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
        cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
        echo "  Copied Sparkle.framework"
    fi

    # Copy resource bundle (contains app assets like permissions.gif, herologo.png, etc.)
    RESOURCE_BUNDLE="Desktop/.build/arm64-apple-macosx/debug/Omi Computer_Omi Computer.bundle"
    if [ -d "$RESOURCE_BUNDLE" ]; then
        cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
        echo "  Copied resource bundle"
    fi

    # Copy acp-bridge
    if [ -d "$ACP_BRIDGE_DIR/dist" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/acp-bridge"
        cp -Rf "$ACP_BRIDGE_DIR/dist" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
        cp -f "$ACP_BRIDGE_DIR/package.json" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
        cp -Rf "$ACP_BRIDGE_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
        echo "  Copied acp-bridge to bundle"
    fi

    # Embed provisioning profile (required for Apple Development signing + restricted entitlements)
    if [ -f "Desktop/embedded-dev.provisionprofile" ]; then
        cp "Desktop/embedded-dev.provisionprofile" "$APP_BUNDLE/Contents/embedded.provisionprofile"
        echo "  Copied dev provisioning profile"
    elif [ -f "Desktop/embedded.provisionprofile" ]; then
        cp "Desktop/embedded.provisionprofile" "$APP_BUNDLE/Contents/embedded.provisionprofile"
        echo "  Copied provisioning profile"
    fi

    # Copy and fix Info.plist
    cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME"              "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID"                "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME"                       "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME"                "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 omi-computer-dev" "$APP_BUNDLE/Contents/Info.plist"

    # Copy GoogleService-Info.plist for Firebase
    cp Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"

    # Copy .env.app (app runtime secrets only) and add API URL
    if [ -f ".env.app" ]; then
        cp .env.app "$APP_BUNDLE/Contents/Resources/.env"
    else
        touch "$APP_BUNDLE/Contents/Resources/.env"
    fi
    # Set API URL to tunnel for development (overrides production default)
    echo "OMI_API_URL=$TUNNEL_URL" >> "$APP_BUNDLE/Contents/Resources/.env"
    echo "Using backend: $TUNNEL_URL"

    # Copy app icon
    cp omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns" 2>/dev/null || true

    # Create PkgInfo
    echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

    # Strip extended attributes before signing
    xattr -cr "$APP_BUNDLE"

    # Sign Sparkle framework components individually (like release.sh does)
    echo "Signing Sparkle framework components..."
    SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        codesign --force --options runtime --sign "$SIGN_IDENTITY" \
            "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
        codesign --force --options runtime --sign "$SIGN_IDENTITY" \
            "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
        codesign --force --options runtime --sign "$SIGN_IDENTITY" \
            "$SPARKLE_FW/Versions/B/Autoupdate" 2>/dev/null || true
        codesign --force --options runtime --sign "$SIGN_IDENTITY" \
            "$SPARKLE_FW/Versions/B/Updater.app" 2>/dev/null || true
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
    fi

    # Sign main app
    echo "Signing app..."
    codesign --force --options runtime \
        --entitlements Desktop/Omi.entitlements \
        --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

    # Install to /Applications
    echo "Installing to /Applications..."
    rm -rf "$APP_PATH"
    ditto "$APP_BUNDLE" "$APP_PATH"

    # Reset app data (UserDefaults, onboarding state, etc.)
    echo "Resetting app data..."
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    defaults delete "$BUNDLE_ID_PROD" 2>/dev/null || true

    # Clear delivered notifications
    echo "Clearing notifications..."
    osascript -e "tell application \"System Events\" to tell process \"NotificationCenter\" to click button 1 of every window" 2>/dev/null || true

    echo "Note: Notification permissions can only be reset manually in System Settings"
else
    echo "[macOS only — skipped] Swift build, app bundle creation, signing, installation"
    echo ""
    echo "To develop the macOS desktop app, run this script on a Mac."
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=== Services Running ==="
echo "Backend:  http://localhost:8080 (PID: $BACKEND_PID)"
echo "Tunnel:   $TUNNEL_URL (PID: $TUNNEL_PID)"
if is_macos; then
    echo "App:      $APP_PATH"
fi
echo "========================"
echo ""

# =============================================================================
# STEP 9: REGISTER + LAUNCH APP (macOS only)
# =============================================================================
if is_macos; then
    # Re-register with LaunchServices (clear stale launch-disabled flags)
    echo "Re-registering with LaunchServices..."
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    $LSREGISTER -u "$APP_PATH" 2>/dev/null || true
    $LSREGISTER -f "$APP_PATH" 2>/dev/null || true

    # Remove quarantine and start app from /Applications
    echo "Starting app..."
    xattr -cr "$APP_PATH"
    open "$APP_PATH" || "$APP_PATH/Contents/MacOS/$BINARY_NAME" &
fi

# Wait for backend process (keeps script running and shows logs)
echo "Press Ctrl+C to stop all services..."
wait "$BACKEND_PID"
