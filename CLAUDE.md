# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Omarqui is an [Omarchy](https://omarchy.org/) Quickshell **bar-widget plugin** for [Qui](https://github.com/autobrr/qui), a self-hosted qBittorrent management dashboard. It's a single-file QML plugin: a bar chip showing aggregate download speed, expanding into a popup panel to list/filter/search torrents across Qui-managed instances, pause/resume/delete them, and add new ones (magnet link or local `.torrent` file).

There is no build system, package manager, or test suite — this is a runtime-interpreted QML plugin loaded directly by the Omarchy shell (Quickshell). "Development" means editing `Panel.qml`/`manifest.json` in place and reloading the live shell to see the effect.

## Repository layout

- `manifest.json` — plugin metadata (id `marcuspelo.omarqui`), `kinds: ["bar-widget"]`, `entryPoints.barWidget: "Panel.qml"`, and the `barWidget.schema`/`defaults` for the two user settings (`baseUrl`, `refreshIntervalSec`).
- `Panel.qml` — the entire plugin: bar chip + popup panel + all state, HTTP calls, and UI, in one file (~1000 lines). See "Architecture" below.
- `README.md` — user-facing install/setup docs; keep in sync with `manifest.json`'s schema table and any behavior change.
- `preview.png` — marketplace gallery image; **must** live at the repo root (not under `images/`) for the Omarchy plugin marketplace to pick it up.
- `images/desktop.png` — secondary screenshot embedded in the README only.
- Secrets are never stored in this repo: the Qui API key (and an optional base-URL fallback) live in `~/.config/omarqui/.env`, outside the plugin folder, and `.gitignore` defensively excludes `.env` anyway.

## Commands

There's no `npm test` / `make build` here — use the Omarchy CLI directly against the live shell.

```bash
# Validate manifest + structure (also run by the marketplace on submission)
omarchy plugin validate /home/marcus/.config/omarchy/plugins/marcuspelo.omarqui

# Enable / disable the plugin on the running bar
omarchy plugin enable marcuspelo.omarqui [left|center|right]
omarchy plugin disable marcuspelo.omarqui

# Persist a bar-widget setting to shell.json (mirrors what the in-panel
# Settings screen does via updateEntryInline)
omarchy bar set marcuspelo.omarqui baseUrl "http://your-qui-host:7476"
omarchy bar set marcuspelo.omarqui refreshIntervalSec 10

# Reload after editing Panel.qml/manifest.json
omarchy-shell shell rescanPlugins   # usually enough for logic-only edits
omarchy restart shell               # more reliable for structural/layout changes — use this when in doubt

# Debugging
omarchy-shell shell ping
omarchy-shell shell listPlugins
omarchy-shell shell debugBarGeometry   # JSON per bar slot: id/x/y/width/height/visible/itemVisible
tail -f /run/user/1000/quickshell/by-id/*/log.log
```

There's no headless test runner and no mouse/click automation available in a plain shell session, so UI changes are verified visually:

```bash
omarchy capture screenshot fullscreen save
# then crop/zoom the bar or panel area with ImageMagick and Read the result, e.g.:
magick <screenshot>.png -crop <W>x<H>+<X>+<Y> -resize <N>% <out>.png
```

## Architecture (all in `Panel.qml`)

The whole plugin is one `Panel { id: root }` component (from `qs.Ui`), which Omarchy mounts twice: once collapsed as a `WidgetButton` in the bar, and once expanded as a `KeyboardPanel` popup anchored to that button.

**Config resolution** — `baseUrl` and `pollInterval` are computed properties, not plain settings reads, because `settings` (backed by `shell.json`) is wiped whenever the plugin is disabled/re-enabled (`omarchy plugin disable` removes the widget's whole `bar.layout` entry; re-enabling recreates a bare `{id: ...}`). Resolution order for `baseUrl`: `settings.baseUrl` → `BASE_URL` from `~/.config/omarqui/.env` (`envBaseUrl`) → hardcoded `http://localhost:7476`. The API key has no settings-level equivalent at all — it only ever comes from `.env`.

**Secrets/config loading** — a `FileView` watches `~/.config/omarqui/.env` and calls `parseEnv()` on load, which does simple `KEY=value` line parsing for `API_KEY` and `BASE_URL`. `apiKeyLoaded` gates every network call so nothing fires before the file has been read (or confirmed missing).

**Networking** — no XHR/fetch; every Qui API call shells out via `Process` + `curl` (`statsProc`, `instancesProc`, `torrentsProc`, `actionProc`, `categoriesProc`, `addTorrentProc`), each with its own `StdioCollector`. Auth is `X-API-Key: <apiKey>` header. Multipart uploads (`submitAddTorrent`) use `curl -F` and detect magnet/URL vs. local file path by prefix (`magnet:`/`http`) vs. everything else (with `~/` home-dir expansion); the HTTP status is smuggled out via `-w "\n---HTTP:%{http_code}"` and parsed back out in `handleAddTorrentResult`.

**Post-action refresh lag** — qBittorrent/Qui take roughly 1.5–2s to actually apply pause/resume/delete before it's reflected in a subsequent GET. `actionProc`'s `onExited` (on success) restarts two chained `Timer`s (`actionRefreshTimer` at 2000ms, `actionRefreshTimer2` at 4000ms) that each re-fetch torrents + stats, rather than relying on a single quick refetch. Don't "simplify" this back to one timer — it was tuned against measured real backend lag.

**View modes** — `viewMode` (`"list" | "add" | "settings"`) switches which `ColumnLayout` is visible inside the same popup rather than using separate `Panel`s; each mode has its own `open*View()`/`close*View()` pair that resets the relevant draft state.

**Settings persistence** — `saveSettings()` writes to `root.settings` locally for immediate effect, then calls `root.bar.shell.updateEntryInline(root.moduleName, next)` to persist into `shell.json`'s bar-layout entry (guarded by `canPersistSettings()` since `bar`/`shell` may not be wired up in all embedding contexts). This is the same mechanism `omarchy bar set` uses under the hood.

**Layout gotcha** — both the root `Panel` and the `ListView` delegate explicitly bind `implicitWidth`/`implicitHeight` (root) and `height: implicitHeight` (delegate). Omarchy/Quickshell silently renders anything missing these as 0×0 with `visible:false` — no error anywhere — so never drop these bindings when restructuring the layout. (`omarchy-shell shell debugBarGeometry` is the way to confirm a widget's actual on-screen geometry if it goes invisible again.)

**State-string handling** — qBittorrent torrent states are inconsistent (`stalledUP`, `pausedDL`, but also bare `downloading`/`uploading` with no suffix). `stateLabel()`, `stateColor()`, `matchesStatusFilter()`, and `isPaused()` all need to independently handle both forms — they intentionally duplicate this matching logic rather than sharing one classifier function, so keep them in sync if you touch one.
