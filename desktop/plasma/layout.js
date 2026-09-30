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
var menu = bar.addWidget("org.kde.plasma.kickoff");
menu.currentConfigGroup = ["General"];
menu.writeConfig("icon", "start-here-symbolic");
// END_STAGOS_WIDGET menu
bar.addWidget("org.kde.plasma.appmenu");
bar.addWidget("org.kde.plasma.panelspacer");
// STAGOS_WIDGET status
bar.addWidget("org.kde.plasma.systemtray");
var clock = bar.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
clock.writeConfig("dateFormat", "custom");
clock.writeConfig("customDateFormat", "ddd d MMM");
clock.writeConfig("dateDisplayFormat", 1);
clock.writeConfig("use24hFormat", 2);
// END_STAGOS_WIDGET status
// STAGOS_WIDGET control
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
