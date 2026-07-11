# ekoloko linux installer

Gets the official ekoloko desktop client running on linux and keeps it in a sandbox.

The linux AppImage (1.0.20) has a few bugs that make Flash fail with "Couldn't
load plugin". This script pulls the latest release from GitHub and patches
around them.

## install

```bash
curl -fsSL https://raw.githubusercontent.com/hondacivicc/ekoloko-linux-installer/master/install-ekoloko-linux.sh | bash
```

or clone and run it:

```bash
git clone https://github.com/hondacivicc/ekoloko-linux-installer
cd ekoloko-linux-installer
./install-ekoloko-linux.sh
```

Then run `ekoloko`, or find it in your app menu.

To update, just run the script again (it always grabs the latest release). To
remove it: `./install-ekoloko-linux.sh --uninstall`.

Everything lives under `~/.local/share/ekoloko` (the app plus its sandbox home),
`~/.local/bin/ekoloko` for the launcher, and one `.desktop` file. Uninstall
takes all of it out.

You need bash and curl or wget, plus bubblewrap for the sandbox. The script
installs bubblewrap for you if it's missing, or falls back to firejail. No root,
no FUSE. Tested on Arch and Kali, but it doesn't use anything distro-specific.

## why the sandbox

The client bundles an old Flash and an old Chromium, and it has to run with
`--no-sandbox` for Flash to load at all. That's fine for a single trusted site,
but a bug in Flash or the renderer would run code as your user, with access to
your home dir, ssh keys and so on.

So the launcher wraps it in bubblewrap. Inside the jail the app only sees a
throwaway home (`~/.local/share/ekoloko`) instead of your real one. It gets a
read-only system, network access for play.ekoloko.org, and just the sockets it
needs for graphics and sound. Nothing else from your account is mounted.

If you ever need to run it without the sandbox: `EKOLOKO_NO_JAIL=1 ekoloko`.

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

---

Not affiliated with ekoloko.org. This just downloads the official client from
their GitHub releases and sets it up locally.
