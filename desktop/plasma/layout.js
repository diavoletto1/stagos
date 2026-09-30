// StagOS Plasma layout: Mac-style top bar + floating bottom dock, no desktop icons.
// stag-plasma-apply turns this into the StagOS global theme's default layout (header vars +
// dock.js + this file) and runs it on the first Plasma login and on --reset-layout.
// Widget slots for p2: each "// STAGOS_WIDGET <name>" line up to its "// END_STAGOS_WIDGET <name>"
// line is replaced by the org.stagos.* plasmoid; the stock widgets in between are stand-ins.

panels().forEach(function (p) { p.remove(); });

// ---- top bar: full width, opaque #0a0a0a with a hairline bottom (StagOS Plasma theme) ----
var bar = new Panel("org.kde.panel");
bar.location = "top";
bar.height = 26;
bar.lengthMode = "fill";
bar.floating = false;
bar.hiding = "none";
bar.opacity = "opaque";
bar.currentConfigGroup = ["General"];
bar.writeConfig("stagosRole", "bar");

// STAGOS_WIDGET menu
// the STAG menu (org.stagos.menu, p2): about, settings, stag apps, session actions
bar.addWidget("org.stagos.menu");
// END_STAGOS_WIDGET menu
bar.addWidget("org.kde.plasma.appmenu");
bar.addWidget("org.kde.plasma.panelspacer");
// STAGOS_WIDGET status
// Stock system tray for third-party tray icons only (Spotify, Obsidian, ...). Plasma's own network, volume,
// battery, bluetooth, brightness and media applets are not loaded: the StagOS readouts and Control Center
// replace them, and their keys/OSD/agents live in kded (audioshortcutsservice, mprisservice, powerdevil,
// plasma-nm, bluedevil). Notifications stays loaded (hidden) so notification popups keep working;
// clipboard stays loaded (hidden) for its history and Meta+V. knownItems stops Plasma from adding the
// dropped applets back later.
var tray = bar.addWidget("org.kde.plasma.systemtray");
var trayId = tray.readConfig("SystrayContainmentId");
var trayBox = trayId ? desktopById(trayId) : null;
if (trayBox) {
    trayBox.currentConfigGroup = ["General"];
    trayBox.writeConfig("extraItems", ["org.kde.plasma.notifications", "org.kde.plasma.clipboard",
        "org.kde.plasma.devicenotifier", "org.kde.plasma.cameraindicator", "org.kde.plasma.manage-inputmethod",
        "org.kde.plasma.keyboardlayout"]);
    trayBox.writeConfig("hiddenItems", ["org.kde.plasma.notifications", "org.kde.plasma.clipboard"]);
    trayBox.writeConfig("knownItems", ["org.kde.plasma.notifications", "org.kde.plasma.clipboard",
        "org.kde.plasma.devicenotifier", "org.kde.plasma.cameraindicator", "org.kde.plasma.manage-inputmethod",
        "org.kde.plasma.keyboardlayout", "org.kde.plasma.keyboardindicator", "org.kde.plasma.networkmanagement",
        "org.kde.plasma.bluetooth", "org.kde.plasma.volume", "org.kde.plasma.battery", "org.kde.plasma.brightness",
        "org.kde.plasma.mediacontroller", "org.kde.plasma.printmanager", "org.kde.plasma.vault", "org.kde.kdeconnect",
        "org.kde.plasma.weather", "org.kde.plasma.diskquota", "org.kde.plasma.addons.katesessions", "org.kde.plasma.trash"]);
    trayBox.reloadConfig();
} else {
    print("stagos layout: no system tray containment, stock tray applets left as they are");
}
// the readouts (org.stagos.status, p2): recon, stats, Stagbot, network, bluetooth, volume, battery, clock
bar.addWidget("org.stagos.status");
// END_STAGOS_WIDGET status
// STAGOS_WIDGET control
// empty on purpose: the Control Center is org.stagos.status's popup (click the readouts)
// END_STAGOS_WIDGET control

// ---- dock: floating, fit to its icons, centered, hides only when a window overlaps it ----
var dock = new Panel("org.kde.panel");
dock.location = "bottom";
dock.height = 48;
dock.lengthMode = "fit";
dock.alignment = "center";
dock.floating = true;
dock.hiding = "dodgewindows";
dock.currentConfigGroup = ["General"];
dock.writeConfig("stagosRole", "dock");
stagosBuildDock(dock, typeof STAGOS_DOCK !== "undefined" ? STAGOS_DOCK : []);

// ---- desktops: StagOS wallpaper, no widgets, no icons ----
// Plasma always creates Folder View desktops and scripts cannot switch the containment type, so
// the folder view hides every file instead (filterMode 2 = hide matches, pattern "*").
desktops().forEach(function (d) {
    d.widgets().forEach(function (w) { w.remove(); });
    if (d.type === "org.kde.plasma.folder") {
        d.currentConfigGroup = ["General"];
        d.writeConfig("filterMode", 2);
        d.writeConfig("filterPattern", "*");
    }
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", typeof STAGOS_WALLPAPER !== "undefined" ? STAGOS_WALLPAPER : "file:///usr/share/stagos/stag-wall-stag.png");
    d.writeConfig("FillMode", 2);
});
