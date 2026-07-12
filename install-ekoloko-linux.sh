#!/usr/bin/env bash
# ekoloko linux installer
#
# Downloads the official ekoloko desktop client and sets it up on linux,
# running it inside a sandbox. Works around bugs in the current AppImage
# that otherwise break Flash on Linux.
#
# usage:
#   ./install-ekoloko-linux.sh              install or update
#   ./install-ekoloko-linux.sh --uninstall  remove (keeps sandbox home)
#   ./install-ekoloko-linux.sh --purge      remove everything
#   ./install-ekoloko-linux.sh --help       show options
#
# about the sandbox: the client bundles old Flash and old Chromium and
# runs with --no-sandbox for Flash to load, so a bug runs as your user.
# The launcher wraps it in bubblewrap (or firejail) with a throwaway home
# instead of your real one. If neither tool is installed it still runs,
# just with a warning.
#
# needs bash, curl or wget. no root needed for the app itself.

set -euo pipefail

REPO="ekolokonet/ekoloko-desktop-app"
HOME_JAIL="${XDG_DATA_HOME:-$HOME/.local/share}/ekoloko"
APP="$HOME_JAIL/app"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
LAUNCHER="$BIN_DIR/ekoloko"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_PATH="${XDG_DATA_HOME:-$HOME/.local/share}/icons/ekoloko.png"

# Optional version pinning. Set both to enforce a specific release version.
# When pinned, the installer fetches that release tag instead of latest,
# and verifies the AppImage SHA256. Set PINNED_VERSION="" to disable.
PINNED_VERSION=""
PINNED_SHA256=""

# --- functions

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m + \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m x \033[0m %s\n' "$*" >&2; exit 1; }

show_help() {
    cat <<EOF
ekoloko linux installer

Usage:
  ./install-ekoloko-linux.sh              Install or update ekoloko
  ./install-ekoloko-linux.sh --uninstall  Remove ekoloko (keep sandbox home)
  ./install-ekoloko-linux.sh --purge      Remove everything including data
  ./install-ekoloko-linux.sh --latest     Skip version pinning if set
  ./install-ekoloko-linux.sh --help       Show this help

Environment:
  EKOLOKO_NO_JAIL=1     Run the app unconfined (skip sandbox)
  XDG_DATA_HOME         Override ~/.local/share
  XDG_BIN_HOME          Override ~/.local/bin

The app runs in a sandbox with a throwaway home at:
  $HOME_JAIL
EOF
}

if command -v curl >/dev/null 2>&1; then
    fetch()      { curl -fL --progress-bar -o "$1" "$2"; }
    fetch_text() { curl -fsL "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch()      { wget -q --show-progress -O "$1" "$2"; }
    fetch_text() { wget -qO- "$1"; }
else
    die "Need curl or wget installed."
fi

# Parse command-line flags
SKIP_PIN=0
UNINSTALL=0
PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --help)       show_help; exit 0 ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --purge)      PURGE=1; UNINSTALL=1; shift ;;
        --latest)     SKIP_PIN=1; shift ;;
        *)            die "Unknown flag: $1" ;;
    esac
done

# Warn if --latest bypasses a pin
if [ $SKIP_PIN -eq 1 ] && [ -n "$PINNED_VERSION" ]; then
    warn "Version pinning and checksum verification skipped (--latest flag)."
fi

# --- uninstall

if [ $UNINSTALL -eq 1 ]; then
    rm -f "$LAUNCHER" "$DESKTOP_DIR/ekoloko.desktop" "$ICON_PATH" 2>/dev/null || true
    if [ $PURGE -eq 1 ]; then
        rm -rf "$HOME_JAIL"
        ok "ekoloko removed completely."
    else
        ok "ekoloko removed. Sandbox home kept at: $HOME_JAIL"
    fi
    exit 0
fi

# --- sanity checks

[ "$(uname -s)" = "Linux" ] || die "This installer is for Linux."

ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    die "The bundled Flash plugin is x86_64-only (you have: $ARCH). Flash support requires 64-bit x86."
fi

[ "$(id -u)" -ne 0 ] || die "Run as a normal user, not root."

# --- ensure sandbox tool

# When bubblewrap can't create user namespaces the sandbox can't start
# ("bwrap: setting up uid map: Permission denied"). The fix is one sysctl,
# but which one depends on the distro; detect the knob this system needs.
userns_sysctl_needed() {
    if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] &&
       [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" != "0" ]; then
        echo "kernel.apparmor_restrict_unprivileged_userns=0"   # Ubuntu 23.10+
    elif [ -f /proc/sys/kernel/unprivileged_userns_clone ] &&
         [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" = "0" ]; then
        echo "kernel.unprivileged_userns_clone=1"               # Debian
    elif [ -f /proc/sys/user/max_user_namespaces ] &&
         [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" = "0" ]; then
        echo "user.max_user_namespaces=15000"                   # Fedora / RHEL
    fi
}

# Offer to apply the userns fix now instead of only printing instructions.
# It loosens a system hardening knob and needs sudo, so it never applies
# without an explicit yes, and skipping just leaves the manual steps.
offer_userns_fix() {
    local setting reply
    setting=$(userns_sysctl_needed)

    warn "bubblewrap can't create user namespaces, so the sandbox can't start"
    warn "(common on Ubuntu 23.10+/24.04 and some Fedora/Debian setups)."

    if [ -z "$setting" ]; then
        warn "See the README's troubleshooting section for the fix, or install firejail."
        return 0
    fi

    warn "The fix writes '$setting' to /etc/sysctl.d/60-userns.conf"
    warn "(persists across reboots, needs sudo). You can also skip it and use firejail."

    # Ask on the terminal itself so this also works via 'curl | bash'.
    if ! { read -r -p "Apply the fix now? [y/N] " reply < /dev/tty; } 2>/dev/null; then
        warn "No terminal to ask on; apply it later with:"
        warn "  echo '$setting' | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system"
        return 0
    fi

    case "$reply" in
        [yY]*)
            if echo "$setting" | sudo tee /etc/sysctl.d/60-userns.conf >/dev/null \
               && sudo sysctl --system >/dev/null; then
                if bwrap --ro-bind / / --unshare-user -- /bin/true >/dev/null 2>&1; then
                    ok "User namespaces enabled; the bubblewrap sandbox works now."
                else
                    warn "Applied, but bubblewrap still can't create user namespaces; see the README."
                fi
            else
                warn "Couldn't apply the sysctl. Do it manually:"
                warn "  echo '$setting' | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system"
            fi
            ;;
        *)
            warn "Skipped. Apply it later with:"
            warn "  echo '$setting' | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system"
            warn "(or install firejail; the launcher uses it automatically)"
            ;;
    esac
}

ensure_sandbox() {
    if command -v bwrap >/dev/null 2>&1; then
        ok "Sandbox: bubblewrap"
        # Unprivileged user namespaces blocked (Ubuntu 24.04, some
        # Fedora/Debian): offer the sysctl fix right away rather than
        # letting the first launch fail.
        if ! bwrap --ro-bind / / --unshare-user -- /bin/true >/dev/null 2>&1; then
            if command -v firejail >/dev/null 2>&1; then
                warn "bubblewrap can't use user namespaces here; firejail will be used instead."
            else
                offer_userns_fix
            fi
        fi
        return 0
    fi
    if command -v firejail >/dev/null 2>&1; then
        ok "Sandbox: firejail"
        return 0
    fi

    info "No sandbox found. Installing bubblewrap (needs sudo)..."

    # Only try sudo if interactive
    if [ ! -t 0 ]; then
        warn "Not running interactively, skipping sudo install. Please install bubblewrap or firejail manually."
        return 0
    fi

    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm bubblewrap || true
    elif command -v apt-get >/dev/null 2>&1; then
        # shellcheck disable=SC2015
        sudo apt-get update -qq && sudo apt-get install -y bubblewrap || true
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y bubblewrap || true
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y bubblewrap || true
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add bubblewrap || true
    elif command -v xbps-install >/dev/null 2>&1; then
        sudo xbps-install -S bubblewrap || true
    fi

    if command -v bwrap >/dev/null 2>&1; then
        ok "Installed bubblewrap."
    else
        warn "Couldn't install a sandbox. The app will run without confinement, so any exploit has full account access. Install bubblewrap or firejail and re-run."
    fi
}
ensure_sandbox

# --- fetch release

info "Looking up release of $REPO"

get_download_url() {
    local api_response
    local url
    local release_url

    # Determine which release to fetch
    if [ -n "$PINNED_VERSION" ] && [ $SKIP_PIN -eq 0 ]; then
        release_url="https://api.github.com/repos/$REPO/releases/tags/$PINNED_VERSION"
    else
        release_url="https://api.github.com/repos/$REPO/releases/latest"
    fi

    if ! api_response=$(fetch_text "$release_url" 2>&1); then
        return 1
    fi

    # Detect rate limiting (GitHub's actual format has no inner quotes)
    if echo "$api_response" | grep -q '"message".*rate limit'; then
        die "GitHub API rate limited. Wait a few minutes or visit https://github.com/ekolokonet/ekoloko-desktop-app/releases"
    fi

    # Detect API errors (e.g., pinned version not found)
    if echo "$api_response" | grep -q '"message"' && ! echo "$api_response" | grep -q 'browser_download_url'; then
        die "GitHub API error: $(echo "$api_response" | grep -o '"message":"[^"]*"' | head -1)"
    fi

    # Extract AppImage URL (multiple assets; take first .AppImage)
    url=$(echo "$api_response" | grep -o '"browser_download_url": *"[^"]*\.AppImage"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    [ -n "$url" ] && echo "$url"
}

URL=$(get_download_url) || die "Could not fetch release info. Visit https://github.com/ekolokonet/ekoloko-desktop-app/releases"
[ -n "$URL" ] || die "Could not find an AppImage in the latest release."
if [ -n "$PINNED_VERSION" ] && [ $SKIP_PIN -eq 0 ]; then
    ok "Pinned release: $(basename "$URL")"
else
    ok "Latest: $(basename "$URL")"
fi

# --- download and verify

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

info "Downloading"
fetch "$TMP/app.AppImage" "$URL"
chmod +x "$TMP/app.AppImage"

# Verify checksum if pinned
if [ -n "$PINNED_VERSION" ] && [ -n "$PINNED_SHA256" ] && [ $SKIP_PIN -eq 0 ]; then
    info "Verifying checksum..."
    ACTUAL_SHA=$(sha256sum "$TMP/app.AppImage" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$PINNED_SHA256" ]; then
        die "Checksum mismatch. Expected: $PINNED_SHA256, got: $ACTUAL_SHA"
    fi
    ok "Checksum verified."
fi

# --- extract

info "Extracting AppImage"
( cd "$TMP" && ./app.AppImage --appimage-extract >/dev/null 2>&1 ) || die "AppImage extraction failed."
[ -d "$TMP/squashfs-root" ] || die "Extracted directory not found; AppImage may be corrupt."

# Verify essential structure before swapping
if [ ! -f "$TMP/squashfs-root/AppRun" ]; then
    die "Extracted AppImage missing AppRun; structure is unexpected."
fi

# --- find binary

find_binary() {
    local d cand f base

    # Try to match binary from .desktop file
    for d in "$TMP/squashfs-root"/*.desktop; do
        [ -e "$d" ] || continue
        cand=$(basename "$d" .desktop)
        if [ -f "$TMP/squashfs-root/$cand" ] && [ -x "$TMP/squashfs-root/$cand" ]; then
            echo "$cand"
            return 0
        fi
    done

    # Fallback: find first ELF executable that's not a library
    for f in "$TMP/squashfs-root"/*; do
        # shellcheck disable=SC2015
        [ -f "$f" ] && [ -x "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            AppRun|chrome-sandbox|*crashpad*|lib*|*.so*)
                continue
                ;;
        esac
        # Check for ELF header (first 4 bytes: 0x7f 'E' 'L' 'F')
        if head -c4 "$f" 2>/dev/null | grep -q ELF; then
            echo "$base"
            return 0
        fi
    done

    return 1
}

BIN_NAME=$(find_binary) || die "Could not find the app's main binary in extracted AppImage."
ok "Binary: $BIN_NAME"

# --- apply flash workaround

SO="$TMP/squashfs-root/resources/plugins/linux/libpepflashplayer.so"
DLL_DIR="$TMP/squashfs-root/resources/plugins/x64"

if [ -f "$SO" ] && [ ! -f "$DLL_DIR/pepflashplayer.dll" ]; then
    mkdir -p "$DLL_DIR"
    cp "$SO" "$DLL_DIR/pepflashplayer.dll"
    ok "Flash plugin path workaround applied."
elif [ -f "$DLL_DIR/pepflashplayer.dll" ]; then
    ok "Flash plugin path already correct."
else
    warn "No Linux Flash plugin found in this release; Flash may not work."
fi

# --- apply view-bounds fix
#
# The app maximizes its window right after creating it and immediately sizes
# the game BrowserView from the window's content bounds. On compositors that
# apply the maximize asynchronously (Hyprland, sway, other tiling/Wayland
# WMs), those bounds are still the default 800x600, so the game sits small
# in the top-left corner until the window is resized by hand. Electron loads
# resources/app in preference to resources/app.asar, so drop in a tiny shim
# that runs the original app unchanged and re-syncs the view bounds after
# startup, after resizes, and once after the game page loads.

apply_view_bounds_fix() {
    local shim_dir="$TMP/squashfs-root/resources/app"
    local asar="$TMP/squashfs-root/resources/app.asar"

    [ -f "$asar" ] || { warn "No app.asar found; skipping view-bounds fix."; return 0; }

    mkdir -p "$shim_dir"

    # The shim needs the app's own package.json next to it so the app keeps
    # its real name and version (the updater compares versions, and userData
    # paths derive from the name). Read it straight out of the asar header;
    # fall back to a minimal one built from the binary name and release tag.
    if command -v python3 >/dev/null 2>&1 && python3 - "$asar" > "$shim_dir/package.json" <<'PYEOF'
import json, struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(4)
    header_size = struct.unpack("<I", f.read(4))[0]
    f.seek(12)
    json_len = struct.unpack("<I", f.read(4))[0]
    header = json.loads(f.read(json_len))
    entry = header["files"]["package.json"]
    f.seek(8 + header_size + int(entry["offset"]))
    sys.stdout.buffer.write(f.read(int(entry["size"])))
PYEOF
    then
        : # got the original package.json
    else
        local ver
        ver=$(basename "$URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        printf '{"name":"%s","version":"%s","main":"main.js"}\n' \
            "$BIN_NAME" "${ver:-0.0.0}" > "$shim_dir/package.json"
        warn "python3 not found; wrote a minimal package.json for the shim."
    fi

    cat > "$shim_dir/main.js" <<'SHIM_EOF'
// ekoloko view-bounds fix (added by the linux installer).
//
// The app maximizes its window right after creating it and sizes the game
// BrowserView from the window's content bounds. On compositors that apply
// the maximize asynchronously (Hyprland, sway, other tiling/Wayland WMs)
// the view keeps its pre-maximize 800x600 size and the game renders small
// in the top-left corner until the window is resized by hand. This shim
// loads the real app from app.asar unchanged and re-syncs the view bounds
// where the app trusts them too early.

const path = require("path");
const { app } = require("electron");

// Control bar height; must match setViewBounds() in the app's main.js.
const BAR_HEIGHT = 100;

function wantedBounds(win) {
  const c = win.getContentBounds();
  return {
    x: 0,
    y: BAR_HEIGHT,
    width: c.width,
    height: Math.max(0, c.height - BAR_HEIGHT),
  };
}

function syncViewBounds(win) {
  if (win.isDestroyed()) return;
  const view = win.getBrowserView && win.getBrowserView();
  if (view) view.setBounds(wantedBounds(win));
}

// The page may have laid out while the view was still 800x600, and setting
// identical bounds produces no resize event, so bounce the height by 1px to
// force Flash to recompute its stage size against the real view.
function nudgeView(win) {
  if (win.isDestroyed()) return;
  const view = win.getBrowserView && win.getBrowserView();
  if (!view) return;
  const want = wantedBounds(win);
  view.setBounds({ x: want.x, y: want.y, width: want.width, height: want.height + 1 });
  setTimeout(() => syncViewBounds(win), 60);
}

app.on("browser-window-created", (_event, win) => {
  // The game view is attached right after the window is constructed.
  setImmediate(() => {
    if (win.isDestroyed()) return;
    if (!(win.getBrowserView && win.getBrowserView())) return; // popups have no view

    // The maximize can land well after startup; keep re-syncing briefly.
    [300, 700, 1500, 3000, 6000].forEach((ms) =>
      setTimeout(() => syncViewBounds(win), ms)
    );

    // Compositor-driven resizes can report stale bounds inside the app's
    // own resize handler; re-check after they settle.
    win.on("resize", () => setTimeout(() => syncViewBounds(win), 150));

    // Once the game page has loaded, deliver one real resize so it lays
    // out against the final view size, not the one it loaded into.
    win.getBrowserView().webContents.on("did-finish-load", () =>
      setTimeout(() => nudgeView(win), 500)
    );
  });
});

require(path.join(process.resourcesPath, "app.asar"));
SHIM_EOF

    ok "View-bounds fix applied (resources/app shim)."
}
apply_view_bounds_fix

# --- install app (preserve user data)

if [ -d "$APP" ]; then
    info "Updating app (preserving sandbox home)..."
    rm -rf "$APP"
fi

mkdir -p "$HOME_JAIL"
mv "$TMP/squashfs-root" "$APP"
ok "Installed to $APP"

# --- check runtime libraries
#
# The sandbox binds the host's /usr, so any library the app needs but the
# system doesn't have shows up as a crash on launch ("cannot open shared
# object file"). Catch them all now with ldd instead of one at a time. On
# Ubuntu note that `apt install chromium` is a snap and installs no libs.

check_runtime_libs() {
    command -v ldd >/dev/null 2>&1 || return 0

    local missing
    missing=$(ldd "$APP/$BIN_NAME" 2>/dev/null | awk '/not found/ {print $1}' | sort -u || true)

    if [ -z "$missing" ]; then
        ok "Runtime libraries: all present."
        return 0
    fi

    warn "The app needs these system libraries, which aren't installed:"
    printf '       %s\n' $missing >&2
    warn "The sandbox uses your system's libraries, so install them on the host:"

    if command -v apt-get >/dev/null 2>&1; then
        warn "  sudo apt install libxss1 libnss3 libnspr4 libgbm1 libasound2t64 libgtk-3-0 \\"
        warn "    libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 libxkbcommon0 \\"
        warn "    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxtst6 libpangocairo-1.0-0"
        warn "  (on Ubuntu 22.04/Debian use libasound2 instead of libasound2t64)"
        warn "  (heads up: 'apt install chromium' on Ubuntu is a snap and installs no libraries)"
    elif command -v dnf >/dev/null 2>&1; then
        warn "  sudo dnf install nss atk at-spi2-atk gtk3 libXScrnSaver libXtst \\"
        warn "    alsa-lib mesa-libgbm cups-libs libxkbcommon libXcomposite libXrandr"
    elif command -v pacman >/dev/null 2>&1; then
        warn "  sudo pacman -S --needed nss atk at-spi2-atk gtk3 libxss libxtst \\"
        warn "    alsa-lib mesa libxkbcommon libxcomposite libxrandr"
    elif command -v zypper >/dev/null 2>&1; then
        warn "  sudo zypper install libXss1 mozilla-nss libgtk-3-0 at-spi2-atk libXtst6 \\"
        warn "    libasound2 libgbm1 cups-libs libxkbcommon0"
    else
        warn "  Install the package that provides each library listed above."
    fi
}
check_runtime_libs

# --- write launcher

mkdir -p "$BIN_DIR"

cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/bin/bash
# ekoloko launcher: runs the client in a bubblewrap or firejail sandbox.
# The app bundles old Flash and Chromium and requires --no-sandbox to run,
# so this wrapper confines it with a throwaway home (not your real one).
# Set EKOLOKO_NO_JAIL=1 to skip the sandbox.

set -euo pipefail

LAUNCHER_EOF

# Inject installer-time variables
cat >> "$LAUNCHER" <<LAUNCHER_VARS
HOME_JAIL="$HOME_JAIL"
BIN_NAME="$BIN_NAME"
LAUNCHER_VARS

cat >> "$LAUNCHER" <<'LAUNCHER_EOF'

RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Ensure app home exists; runtime dir is checked later
mkdir -p "$HOME_JAIL"

run_bwrap() {
    local -a a=(
        --die-with-parent
        --new-session
        --unshare-all --share-net
        --clearenv
        --ro-bind /usr /usr
        --ro-bind-try /etc/ssl /etc/ssl
        --ro-bind-try /etc/pki /etc/pki
        --ro-bind-try /etc/ca-certificates /etc/ca-certificates
        --ro-bind-try /etc/hosts /etc/hosts
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf
        --ro-bind-try /etc/fonts /etc/fonts
        --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache
        --ro-bind-try /etc/passwd /etc/passwd
        --ro-bind-try /etc/group /etc/group
        --ro-bind-try /etc/localtime /etc/localtime
        --ro-bind-try /run/systemd/resolve /run/systemd/resolve
        --ro-bind-try /run/NetworkManager /run/NetworkManager
        --ro-bind-try /opt /opt
        --proc /proc
        --dev /dev
        --tmpfs /tmp
        --tmpfs /dev/shm
    )

    # Recreate the host's /lib, /bin, etc. exactly as they are, rather than
    # assuming one distro's layout. Merged-/usr systems (Arch, modern Debian/
    # Ubuntu/Kali/Fedora) make these symlinks into /usr; older systems keep
    # them as real dirs holding the loader and core libs. Hardcoding Arch's
    # shape put ld-linux and the multiarch libs in the wrong place on Debian
    # family, so the app's binary couldn't start and exited with no window.
    for d in /lib /lib64 /lib32 /libx32 /bin /sbin; do
        if [ -L "$d" ]; then
            a+=( --symlink "$(readlink "$d")" "$d" )
        elif [ -d "$d" ]; then
            a+=( --ro-bind "$d" "$d" )
        fi
    done

    # GPU access (DRI)
    [ -d /dev/dri ] && a+=( --dev-bind-try /dev/dri /dev/dri )
    [ -d /sys/dev/char ] && a+=( --ro-bind-try /sys/dev/char /sys/dev/char )
    [ -d /sys/devices ] && a+=( --ro-bind-try /sys/devices /sys/devices )

    # GPU access (NVIDIA): bind all existing /dev/nvidia* nodes
    for nv_dev in /dev/nvidia*; do
        [ -e "$nv_dev" ] && a+=( --dev-bind-try "$nv_dev" "$nv_dev" )
    done

    # Runtime directory: use resolved path or fallback to temp
    local rt_to_use="$RT"
    if [ ! -d "$RT" ] || [ ! -w "$RT" ]; then
        rt_to_use=$(mktemp -d)
        trap 'rm -rf "$rt_to_use"' EXIT
    fi
    a+=( --dir "$rt_to_use" --chmod 0700 "$rt_to_use" )

    # Wayland socket: only bind if variable is set AND socket exists
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$RT/$WAYLAND_DISPLAY" ]; then
        a+=( --ro-bind-try "$RT/$WAYLAND_DISPLAY" "$RT/$WAYLAND_DISPLAY" )
    fi

    # Audio (PipeWire native socket + PulseAudio socket)
    [ -S "$RT/pipewire-0" ] && a+=( --ro-bind-try "$RT/pipewire-0" "$RT/pipewire-0" )
    [ -S "$RT/pulse/native" ] && a+=( --ro-bind-try "$RT/pulse/native" "$RT/pulse/native" )

    # X11 socket
    [ -d /tmp/.X11-unix ] && a+=( --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix )

    # Home and environment
    a+=(
        --bind "$HOME_JAIL" "$HOME"
        --setenv HOME "$HOME"
        --setenv USER "${USER:-user}"
        --setenv PATH /usr/bin:/bin
        --setenv XDG_RUNTIME_DIR "$rt_to_use"
        --setenv LANG "${LANG:-C.UTF-8}"
    )

    # X11 auth cookie: on X11/Xwayland the server checks a MIT-MAGIC-COOKIE
    # from ~/.Xauthority. That lives in your real home, but the jail gets a
    # throwaway one, so without this the app fails with "Authorization
    # required ... cannot open display". Bind the host's cookie in read-only.
    if [ -n "${DISPLAY:-}" ]; then
        local xauth_src="${XAUTHORITY:-$HOME/.Xauthority}"
        if [ -f "$xauth_src" ]; then
            a+=(
                --ro-bind "$xauth_src" "$HOME/.Xauthority"
                --setenv XAUTHORITY "$HOME/.Xauthority"
            )
        fi
    fi

    # Session environment (only if set to avoid blank expansions)
    [ -n "${WAYLAND_DISPLAY:-}" ] && a+=( --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY" )
    [ -n "${DISPLAY:-}" ] && a+=( --setenv DISPLAY "$DISPLAY" )
    [ -n "${XDG_SESSION_TYPE:-}" ] && a+=( --setenv XDG_SESSION_TYPE "$XDG_SESSION_TYPE" )

    # X11 access warning
    if [ -n "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        echo "Warning: X11 session; X11 clients can observe keystrokes and screenshots from the app." >&2
    fi

    exec bwrap "${a[@]}" "$HOME/app/$BIN_NAME" --no-sandbox "$@"
}

run_firejail() {
    # --private mounts $HOME_JAIL over $HOME, and the command runs inside
    # that mount namespace, so the binary must be addressed as $HOME/app/...
    # ($HOME_JAIL/app/... no longer exists from the sandbox's view).
    exec firejail --quiet --noprofile \
        --private="$HOME_JAIL" --private-tmp \
        --caps.drop=all --nonewprivs --noroot --seccomp \
        --protocol=unix,inet,inet6,netlink --disable-mnt \
        "$HOME/app/$BIN_NAME" --no-sandbox "$@"
}

# Probe whether bubblewrap can actually create a user namespace. On systems
# that block unprivileged user namespaces (Ubuntu 23.10+/24.04 AppArmor, some
# Fedora/Debian), bwrap fails with "setting up uid map: Permission denied".
bwrap_works() {
    bwrap --ro-bind / / --unshare-user -- /bin/true >/dev/null 2>&1
}

# Explain the userns restriction and how to fix it for the common distros.
userns_help() {
    cat >&2 <<'MSG'
ekoloko: the bubblewrap sandbox can't start because your system blocks
unprivileged user namespaces ("bwrap: setting up uid map: Permission denied").

This is common on Ubuntu 23.10+/24.04 and some Fedora/Debian setups. Pick ONE
fix below (each persists across reboots), then re-run: ekoloko

  Ubuntu 23.10+ / 24.04 (AppArmor restriction):
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' | \
      sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system

  Debian / older kernels (userns disabled):
    echo 'kernel.unprivileged_userns_clone=1' | \
      sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system

  Fedora / RHEL (namespaces capped at 0):
    echo 'user.max_user_namespaces=15000' | \
      sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system

  Or make bubblewrap setuid-root (works everywhere, one-time root):
    sudo chmod u+s "$(command -v bwrap)"

  Or install firejail (used automatically if present):
    sudo apt install firejail   # or dnf/pacman/zypper

To run right now WITHOUT the sandbox (LESS SECURE: the app runs unconfined
with your account's full access):
    EKOLOKO_NO_JAIL=1 ekoloko
MSG
}

# Main dispatcher
if [ "${EKOLOKO_NO_JAIL:-0}" = "1" ]; then
    exec "$HOME_JAIL/app/$BIN_NAME" --no-sandbox "$@"
elif command -v bwrap >/dev/null 2>&1 && bwrap_works; then
    run_bwrap "$@"
elif command -v firejail >/dev/null 2>&1; then
    # bwrap missing or userns blocked; firejail is setuid so it still works.
    run_firejail "$@"
elif command -v bwrap >/dev/null 2>&1; then
    # bwrap present but user namespaces are blocked, and no firejail fallback.
    # Don't silently drop confinement: guide the user to a real fix.
    userns_help
    exit 1
else
    echo "ekoloko: no sandbox (bwrap/firejail) found; running unconfined." >&2
    exec "$HOME_JAIL/app/$BIN_NAME" --no-sandbox "$@"
fi
LAUNCHER_EOF

chmod +x "$LAUNCHER"
ok "Sandboxed launcher: $LAUNCHER"

# --- desktop entry + icon

mkdir -p "$DESKTOP_DIR" "$(dirname "$ICON_PATH")"

ICON_SRC=$(find "$APP" -maxdepth 1 -name "*.png" 2>/dev/null | head -1 || true)
if [ -n "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$ICON_PATH"
fi

cat > "$DESKTOP_DIR/ekoloko.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ekoloko
Comment=ekoloko desktop client (sandboxed), play.ekoloko.org
Exec=$LAUNCHER
Icon=$ICON_PATH
Categories=Game;
Terminal=false
EOF

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
fi
ok "Desktop entry created."

# --- PATH management (idempotent)

add_to_path() {
    local shell_rc="$1"
    local bin_dir="$2"

    if [ ! -f "$shell_rc" ]; then
        return 0
    fi

    # Already has the path?
    if grep -q "['\"]${bin_dir}['\"]" "$shell_rc" || grep -q "\.local/bin" "$shell_rc"; then
        return 0
    fi

    echo "" >> "$shell_rc"
    echo "export PATH=\"$bin_dir:\$PATH\"" >> "$shell_rc"
    return 0
}

# Only modify if not already in PATH
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
    info "Adding $BIN_DIR to PATH (open a new terminal to use: ekoloko)"

    add_to_path "$HOME/.bashrc" "$BIN_DIR"
    add_to_path "$HOME/.zshrc" "$BIN_DIR"

    # Fish: use the more modern approach if available
    if command -v fish >/dev/null 2>&1; then
        if ! fish -c "contains $BIN_DIR \$fish_user_paths" 2>/dev/null; then
            fish -c "set -U fish_user_paths $BIN_DIR \$fish_user_paths" 2>/dev/null || true
        fi
    fi
fi

# --- summary

echo ""
echo "==============================================="
echo " ekoloko is installed (sandboxed)"
echo "==============================================="
echo ""
echo "Run:        ekoloko"
echo "            (or find 'Ekoloko' in your app menu)"
echo ""
echo "Sandbox:    $HOME_JAIL"
echo "            (app can only see this, not your real home)"
echo ""
echo "Update:     re-run this script"
echo "Uninstall:  $0 --uninstall"
echo "Purge:      $0 --purge"
echo ""
echo "Skip jail:  EKOLOKO_NO_JAIL=1 ekoloko"
echo ""
