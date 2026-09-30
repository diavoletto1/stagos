// StagOS dock helpers (Plasma desktop scripting). stag-plasma-apply prepends
//   var STAGOS_DOCK = [[{id: "foot.desktop", path: "/usr/share/applications/foot.desktop"}, ...], ...];
// built from [dock] launchers in ~/.config/stagos/desktop.conf: one inner array per group, groups
// split at "|", launchers whose .desktop file is missing already dropped. The first group is an
// icontasks (pinned launchers + running windows), every later group is a separator + quicklaunch.

function stagosDockSignature(groups) {
    return JSON.stringify(groups.map(function (g) { return g.map(function (l) { return l.id; }); }));
}

function stagosFindPanel(role) {
    var all = panels();
    for (var i = 0; i < all.length; i++) {
        all[i].currentConfigGroup = ["General"];
        if (all[i].readConfig("stagosRole", "") === role) {
            return all[i];
        }
    }
    return null;
}

function stagosBuildDock(dock, groups) {
    dock.widgets().forEach(function (w) { w.remove(); });
    var first = groups.length > 0 ? groups[0] : [];
    var tasks = dock.addWidget("org.kde.plasma.icontasks");
    tasks.currentConfigGroup = ["General"];
    tasks.writeConfig("launchers", first.map(function (l) { return "applications:" + l.id; }));
    tasks.writeConfig("showOnlyCurrentDesktop", false);
    tasks.writeConfig("indicateAudioStreams", true);
    for (var i = 1; i < groups.length; i++) {
        if (groups[i].length === 0) {
            continue;
        }
        dock.addWidget("org.kde.plasma.marginsseparator");
        var quick = dock.addWidget("org.kde.plasma.quicklaunch");
        quick.currentConfigGroup = ["General"];
        quick.writeConfig("launcherUrls", groups[i].map(function (l) { return "file://" + l.path; }));
        quick.writeConfig("maxSectionCount", 1);
        quick.writeConfig("showLauncherNames", false);
        quick.writeConfig("enablePopup", false);
    }
    dock.currentConfigGroup = ["General"];
    dock.writeConfig("stagosDock", stagosDockSignature(groups));
}

// Normal stag-plasma-apply runs: rebuild the dock only when the launcher list changed.
function stagosSyncDock(groups) {
    var dock = stagosFindPanel("dock");
    if (dock === null) {
        print("dock: no StagOS dock panel (run stag-plasma-apply --reset-layout to recreate it)");
        return;
    }
    dock.currentConfigGroup = ["General"];
    if (dock.readConfig("stagosDock", "") === stagosDockSignature(groups)) {
        print("dock: unchanged");
        return;
    }
    stagosBuildDock(dock, groups);
    print("dock: updated");
}

// --session / first run: is the StagOS layout already in place?
function stagosHasLayout() {
    print(stagosFindPanel("bar") !== null && stagosFindPanel("dock") !== null ? "stagos-layout: yes" : "stagos-layout: no");
}
