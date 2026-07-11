#!/usr/bin/env bash
# ekoloko linux installer
#
# Downloads the official ekoloko desktop client and sets it up on linux,
# running it inside a sandbox. Also works around a few bugs in the current
# AppImage that otherwise break Flash.
#
# usage:
#   ./install-ekoloko-linux.sh              install or update
#   ./install-ekoloko-linux.sh --uninstall  remove everything
#
# about the sandbox: the client bundles an old Flash and an old Chromium and
# has to run with --no-sandbox for Flash to load, so a bug in it would run as
# your user. To limit that the launcher wraps it in bubblewrap (or firejail)
# and gives it a throwaway home instead of your real one. If neither is
# installed it still runs, just with a warning. Use EKOLOKO_NO_JAIL=1 ekoloko
# to skip the sandbox.
#
# needs bash and curl or wget. no root needed for the app itself.
set -euo pipefail

REPO="ekolokonet/ekoloko-desktop-app"
HOME_JAIL="${XDG_DATA_HOME:-$HOME/.local/share}/ekoloko"   # sandbox home
APP="$HOME_JAIL/app"                                        # extracted client
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/ekoloko"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_PATH="${XDG_DATA_HOME:-$HOME/.local/share}/icons/ekoloko.png"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m + \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m x \033[0m %s\n' "$*" >&2; exit 1; }

if command -v curl >/dev/null 2>&1; then
    fetch()      { curl -fL --progress-bar -o "$1" "$2"; }
    fetch_text() { curl -fsL "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch()      { wget -q --show-progress -O "$1" "$2"; }
    fetch_text() { wget -qO- "$1"; }
else
    die "Need curl or wget installed."
fi

# uninstall
if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$HOME_JAIL" "$LAUNCHER" "$DESKTOP_DIR/ekoloko.desktop" "$ICON_PATH"
    ok "ekoloko removed (including its sandbox home)."
    exit 0
fi

# sanity checks
[ "$(uname -s)" = "Linux" ]  || die "This installer is for Linux."
[ "$(uname -m)" = "x86_64" ] || die "The bundled Flash plugin is x86_64-only (you have: $(uname -m))."
[ "$(id -u)" -ne 0 ]         || die "Run as a normal user, not root."

# make sure a sandbox tool is around (prefer bubblewrap)
ensure_sandbox() {
    command -v bwrap >/dev/null 2>&1    && { ok "Sandbox: bubblewrap (bwrap)"; return; }
    command -v firejail >/dev/null 2>&1 && { ok "Sandbox: firejail";           return; }
    info "No sandbox found, installing bubblewrap (needs sudo)"
    if   command -v pacman  >/dev/null; then sudo pacman -S --needed --noconfirm bubblewrap || true
    elif command -v apt-get >/dev/null; then sudo apt-get update -qq && sudo apt-get install -y bubblewrap || true
    elif command -v dnf     >/dev/null; then sudo dnf install -y bubblewrap || true
    elif command -v zypper  >/dev/null; then sudo zypper install -y bubblewrap || true
    fi
    if command -v bwrap >/dev/null 2>&1; then ok "Installed bubblewrap."
    else warn "Couldn't install a sandbox. The app will run without one, so an exploit would have full access to your account. Install bubblewrap or firejail and re-run to fix."
    fi
}
ensure_sandbox

# 1. find the latest AppImage
info "Looking up latest release of $REPO"
URL=$(fetch_text "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*\.AppImage"' \
      | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$URL" ] || die "Could not find an AppImage in the latest GitHub release."
ok "Latest: $(basename "$URL")"

# 2. download
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
info "Downloading"
fetch "$TMP/app.AppImage" "$URL"
chmod +x "$TMP/app.AppImage"

# 3. extract it (no FUSE) into the sandbox home
info "Extracting"
( cd "$TMP" && ./app.AppImage --appimage-extract >/dev/null )
[ -d "$TMP/squashfs-root" ] || die "AppImage extraction failed."
rm -rf "$HOME_JAIL"
mkdir -p "$HOME_JAIL"
mv "$TMP/squashfs-root" "$APP"
ok "Installed to $APP"

# 4. find the electron binary (electron-builder names the .desktop after it)
BIN_NAME=""
for d in "$APP"/*.desktop; do
    [ -e "$d" ] || continue
    cand="$(basename "$d" .desktop)"
    [ -f "$APP/$cand" ] && [ -x "$APP/$cand" ] && { BIN_NAME="$cand"; break; }
done
if [ -z "$BIN_NAME" ]; then
    for f in "$APP"/*; do
        base=$(basename "$f"); [ -f "$f" ] && [ -x "$f" ] || continue
        case "$base" in AppRun|chrome-sandbox|*crashpad*|lib*|*.so*) continue;; esac
        head -c4 "$f" 2>/dev/null | grep -q ELF && { BIN_NAME="$base"; break; }
    done
fi
[ -n "$BIN_NAME" ] || die "Could not find the app's main binary in $APP."
ok "Binary: $BIN_NAME"

# 5. flash plugin path fix: the linux code looks for the windows dll
SO="$APP/resources/plugins/linux/libpepflashplayer.so"
DLL_DIR="$APP/resources/plugins/x64"
if [ -f "$SO" ] && [ ! -f "$DLL_DIR/pepflashplayer.dll" ]; then
    mkdir -p "$DLL_DIR"; cp "$SO" "$DLL_DIR/pepflashplayer.dll"
    ok "Flash plugin path workaround applied."
elif [ -f "$DLL_DIR/pepflashplayer.dll" ]; then ok "Flash plugin path already OK."
else warn "No Linux Flash plugin in this release, continuing."
fi

# 6. write the launcher
# it also adds --no-sandbox (the chromium sandbox kills the old flash process)
# and calls the binary directly (AppRun mangles any flags you pass it), all
# inside a bubblewrap/firejail jail whose home is the throwaway dir.
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/bin/bash
# ekoloko launcher. The client bundles old Flash and Chromium and runs with
# --no-sandbox, so it's confined here: it only sees \$HOME_JAIL as its home,
# not your real \$HOME, ssh keys or tokens. Set EKOLOKO_NO_JAIL=1 to skip this.
set -e
HOME_JAIL="$HOME_JAIL"
BIN_NAME="$BIN_NAME"
RT="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
mkdir -p "\$HOME_JAIL"

run_bwrap() {
  local a=(
    --die-with-parent
    --unshare-all --share-net
    --clearenv
    --ro-bind /usr /usr
    --ro-bind /etc /etc
    # /etc/resolv.conf is usually a symlink into /run (systemd-resolved or
    # NetworkManager); bind those dirs so the symlink resolves and DNS works.
    --ro-bind-try /run/systemd/resolve /run/systemd/resolve
    --ro-bind-try /run/NetworkManager /run/NetworkManager
    --ro-bind-try /opt /opt
    --symlink usr/lib /lib
    --ro-bind-try /lib64 /lib64
    --symlink usr/bin /bin
    --symlink usr/bin /sbin
    --proc /proc
    --dev /dev
    --dev-bind-try /dev/dri /dev/dri
    --ro-bind-try /sys/dev/char /sys/dev/char
    --ro-bind-try /sys/devices /sys/devices
    --tmpfs /tmp
    --tmpfs /dev/shm
    --bind "\$HOME_JAIL" "\$HOME"
    --dir "\$RT"
    --chmod 0700 "\$RT"
    --ro-bind-try "\$RT/\$WAYLAND_DISPLAY" "\$RT/\$WAYLAND_DISPLAY"
    --ro-bind-try "\$RT/pipewire-0" "\$RT/pipewire-0"
    --ro-bind-try "\$RT/pulse" "\$RT/pulse"
    --ro-bind-try /etc/machine-id /etc/machine-id
    --ro-bind-try /run/dbus/system_bus_socket /run/dbus/system_bus_socket
    --setenv HOME "\$HOME"
    --setenv USER "\${USER:-user}"
    --setenv PATH "/usr/bin:/bin"
    --setenv XDG_RUNTIME_DIR "\$RT"
    --setenv WAYLAND_DISPLAY "\${WAYLAND_DISPLAY:-}"
    --setenv XDG_SESSION_TYPE "\${XDG_SESSION_TYPE:-wayland}"
    --setenv DISPLAY "\${DISPLAY:-}"
    --setenv LANG "\${LANG:-C.UTF-8}"
  )
  [ -d /tmp/.X11-unix ] && a+=( --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix )
  exec bwrap "\${a[@]}" "\$HOME/app/\$BIN_NAME" --no-sandbox "\$@"
}

run_firejail() {
  exec firejail --quiet --noprofile \\
    --private="\$HOME_JAIL" --private-tmp \\
    --caps.drop=all --nonewprivs --noroot --seccomp \\
    --protocol=unix,inet,inet6,netlink --disable-mnt \\
    "\$HOME/app/\$BIN_NAME" --no-sandbox "\$@"
}

if [ "\${EKOLOKO_NO_JAIL:-0}" = "1" ]; then
  exec "\$HOME_JAIL/app/\$BIN_NAME" --no-sandbox "\$@" 2>/dev/null
elif command -v bwrap >/dev/null 2>&1; then
  run_bwrap "\$@" 2>/dev/null
elif command -v firejail >/dev/null 2>&1; then
  run_firejail "\$@" 2>/dev/null
else
  echo "ekoloko: no sandbox (bwrap/firejail) found, running unconfined." >&2
  exec "\$HOME_JAIL/app/\$BIN_NAME" --no-sandbox "\$@" 2>/dev/null
fi
LAUNCHER_EOF
chmod +x "$LAUNCHER"
ok "Sandboxed launcher: $LAUNCHER"

# 7. desktop entry + icon
mkdir -p "$DESKTOP_DIR" "$(dirname "$ICON_PATH")"
ICON_SRC=$(ls "$APP"/*.png 2>/dev/null | head -1 || true)
[ -n "$ICON_SRC" ] && cp "$ICON_SRC" "$ICON_PATH"
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
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
ok "App-menu entry created."

# 8. PATH
case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc" \
            && printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    done
    command -v fish >/dev/null 2>&1 && fish -c "fish_add_path '$BIN_DIR'" >/dev/null 2>&1 || true
    info "Added $BIN_DIR to PATH, open a new terminal to use the ekoloko command."
esac

echo
printf '\033[1;32m ekoloko is installed (sandboxed) \033[0m\n'
echo   "   Run:  ekoloko            (or find Ekoloko in your app menu)"
echo   "   The app can only see $HOME_JAIL, not your real home."
echo
echo   "   Update:    re-run this script"
echo   "   Uninstall: $0 --uninstall"
echo   "   Skip sandbox: EKOLOKO_NO_JAIL=1 ekoloko"
