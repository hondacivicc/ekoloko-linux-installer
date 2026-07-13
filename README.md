# ekoloko linux installer

Gets the official ekoloko desktop client running on linux and keeps it in a sandbox.

The linux AppImage (1.0.20) has a few bugs that make Flash fail with "Couldn't
load plugin". This script pulls the official release from GitHub and patches
around them.

## install

Clone it (so you can read the script first), then run it:

```bash
git clone https://github.com/hondacivicc/ekoloko-linux-installer
cd ekoloko-linux-installer
./install-ekoloko-linux.sh
```

Then run `ekoloko`, or find it in your app menu.

The download is pinned to a known release and checksum-verified; use
`--latest` if you want the newest upstream release instead.

To update, just run the script again. To remove it:
`./install-ekoloko-linux.sh --uninstall`.

Everything lives under `~/.local/share/ekoloko` (the app plus its sandbox home),
`~/.local/bin/ekoloko` for the launcher, and one `.desktop` file. Uninstall
takes all of it out.

No root for the app itself, no FUSE. Tested on Arch, Kali and Ubuntu.

## requirements

To fetch and sandbox the app you need `bash` and `curl` or `wget`, plus
`bubblewrap` (the script installs it for you if it's missing).

The app itself is Electron/Chromium, and the sandbox runs it against your
system's libraries, so those need to be installed on the host. On a minimal
install they usually aren't. Grab them all at once:

**Debian / Ubuntu / Kali**

```bash
sudo apt install libxss1 libnss3 libnspr4 libgbm1 libasound2t64 libgtk-3-0 \
  libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxtst6 libpangocairo-1.0-0
```

On Ubuntu 22.04 and Debian, use `libasound2` instead of `libasound2t64` (the
`t64` name is the 24.04 time_t transition). apt remaps the other names for you.


**Fedora / RHEL**

```bash
sudo dnf install nss atk at-spi2-atk gtk3 libXScrnSaver libXtst \
  alsa-lib mesa-libgbm cups-libs libxkbcommon libXcomposite libXrandr
```

**Arch**

```bash
sudo pacman -S --needed nss atk at-spi2-atk gtk3 libxss libxtst \
  alsa-lib mesa libxkbcommon libxcomposite libxrandr
```

The installer runs `ldd` after downloading and prints exactly which libraries
are missing, so if it launches clean you don't need any of this.

## why the sandbox

The client bundles an old Flash and an old Chromium, and it has to run with
`--no-sandbox` for Flash to load at all. Run that way it isn't secure, so the
launcher wraps it in bubblewrap. Inside the jail the app only sees a throwaway
home (`~/.local/share/ekoloko`) instead of your real one, a read-only system,
and just the sockets it needs for graphics and sound. Nothing else from your
account is exposed.

For the same reason it runs through Xwayland with the native Wayland socket
withheld, and doesn't bind the GPU (it renders in software anyway) — passing
those in would be less secure. Set `EKOLOKO_WAYLAND=1` or `EKOLOKO_GPU=1` to
enable them if you need to.

If you ever need to run it without the sandbox: `EKOLOKO_NO_JAIL=1 ekoloko` (not
secure — the app runs with your account's normal access).

If no working sandbox is available at launch (bwrap blocked or not installed),
the launcher never drops confinement silently: it
asks first. From a terminal that's a y/N prompt; from the desktop icon it's a
popup (zenity, kdialog, yad or xmessage — whichever the system has). If it has
no way to ask, it refuses to start and sends a desktop notification saying why.

## the bugs it works around

1. Wrong Flash plugin path. `main.js` only handles the Windows path in its
   platform switch, so on linux it looks for `plugins/x64/pepflashplayer.dll`
   and never touches the bundled `plugins/linux/libpepflashplayer.so`. Fix: copy
   the `.so` to the path it expects. Chromium dlopens by path and doesn't care
   about the extension.

2. The Chromium sandbox kills the old Flash process on modern kernels, silently.
   Fix: launch with `--no-sandbox`.

3. `AppRun` can't pass flags. It uses `$1` in its own AppDir-detection loop, so
   any flag you pass breaks startup. Fix: extract the AppImage and run the
   Electron binary directly.

Upstream could kill bugs 1 and 2 with two lines in `main.js`:

- `case "linux": y = "linux/libpepflashplayer.so"` in the platform switch
- `if (process.platform === "linux") app.commandLine.appendSwitch("no-sandbox")`

If something breaks, the logs are at `~/.config/ekoloko-rewritten/logs/ekoloko.log`.

## troubleshooting

**`bwrap: setting up uid map: Permission denied`** — your system blocks
unprivileged user namespaces (common on Ubuntu 23.10+ and some Fedora/Debian).
The installer detects this, picks the right sysctl for your distro and offers
to apply it during install (it asks first — the change needs sudo and persists
across reboots). If you skipped that, enable them manually, then re-run
`ekoloko`:

```bash
# Ubuntu 23.10+ / 24.04
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system
# Debian / older kernels
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system
# Fedora / RHEL
echo 'user.max_user_namespaces=15000' | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system
```

Or make bwrap setuid-root: `sudo chmod u+s "$(command -v bwrap)"`.

**Can't type your second keyboard layout (Hebrew, Russian, ...) in chat** —
the client's old Chromium ignores XKB group switching, so only the first
layout ever types. On Hyprland the launcher works around this automatically
(needs `setxkbmap` and `python3`); on other compositors it's still broken.

**`error while loading shared libraries: ...cannot open shared object file`** —
a system library is missing. Install the packages from [requirements](#requirements)
above; the installer also lists the exact ones on its last line.

**It starts but no window appears** — usually the same missing-library problem;
check the log path above, and make sure the requirements are installed.

**Audio artifact plays for a few seconds after logging in** — a sound effect or
background audio starts briefly after login and entering the game (usually clears
itself).

---

Not affiliated with ekoloko.org. This just downloads the official client from
their GitHub releases and sets it up locally.
