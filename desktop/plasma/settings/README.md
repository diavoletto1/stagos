# StagOS Settings (`stag-settings`)

A Kirigami app in plain QML, run by the Qt 6 `qml` runtime (`qt6-declarative`, `kirigami`,
`qqc2-desktop-style`). No compiled code, no PySide. It edits `~/.config/stagos/desktop.conf` in place
(comments and unknown keys survive) and saves on every change, Mac style: no Apply button.

| File | What |
| --- | --- |
| `stag-settings.sh` | launcher: builds a JSON context (installed apps, wireless interfaces, git version), sets the env the runtime needs, execs `qml` |
| `main.qml`, `*Page.qml`, `PageFrame.qml` | window, sidebar, pages (Top Bar, Dock, Look, Session, Recon, About) |
| `Conf.qml`, `ini.js` | desktop.conf model: in-place INI edit, async write queue with read-back |
| `stag-settings-apply.sh` | what the path unit's service runs |
| `units/` | `stagos-desktop-apply.path` + `.service` (systemd --user) |
| `share/` | `stag-settings.desktop` (launcher, KRunner), the System Settings entry, the icon |

## Why the `qml` runtime can do this

The runtime has no file or process API. Two workarounds, both in the launcher/app:

- **Files**: `XMLHttpRequest` reads and writes `file://` URLs when `QML_XHR_ALLOW_FILE_READ=1` and
  `QML_XHR_ALLOW_FILE_WRITE=1` are set (the launcher sets them). Only the asynchronous PUT writes; the
  status is always 0, so `Conf.qml` reads every write back and records `lastError` on a mismatch.
  `QtCore.Settings` was not used: it rewrites the whole file, drops the comments and would quote
  values containing `;` or `,` (the dock list), which the shell readers do not unquote.
- **Commands**: nothing can be run from QML. A change to `desktop.conf` is picked up by the systemd
  `--user` path unit `stagos-desktop-apply.path`, whose service runs `stag-settings-apply`, i.e.
  `stag-plasma-apply --quiet`. "Reset layout" writes `~/.local/state/stagos/reset-layout.request`;
  the same path unit sees it (`PathExists=`), and the service deletes the file and runs
  `stag-plasma-apply --quiet --reset-layout` instead.

## Plasma System Settings entry

System Settings (Plasma 6, `app/kcmmetadatahelpers.h: findExternalKCMModules`) lists every
`*.desktop` in `<XDG data dir>/plasma/systemsettings/externalmodules/` as an external app
(`IsExternalApp`), placed by `X-KDE-System-Settings-Parent-Category`. The module installs
`share/stag-settings-module.desktop` there under `~/.local/share` (no root needed), category
Workspace, icon `stag-settings`, `Exec=stag-settings`.

## Test hooks

`stag-settings --selftest=set:bar.cpu=false,dock-add:x.desktop,dock-sep,dock-move:0:1,dock-remove:2,reset-layout`
runs the same `conf.set` / `conf.dock*` / `conf.requestResetLayout` the UI handlers call, waits for the
writes and exits (0 = `SELFTEST OK`). `--page=NAME --shot=FILE` saves a screenshot of one page.
`test/plasma-settings.sh` drives both with `QT_QPA_PLATFORM=offscreen`.
