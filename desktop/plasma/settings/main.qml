import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

// StagOS Settings. Run by stag-settings (qml runtime). Arguments after "--":
//   --context=FILE      JSON prepared by the launcher (paths, installed apps, interfaces, version)
//   --page=NAME         start page: bar dock look session recon about
//   --shot=FILE         test hook: save a screenshot of the window and quit
//   --selftest=ACTIONS  test hook: run UI code paths (comma separated) and quit, see runSelftest()
Kirigami.ApplicationWindow {
    id: win
    width: 720
    height: 520
    minimumWidth: 640
    minimumHeight: 440
    title: "StagOS Settings"
    visible: true

    property var ctx: ({ conf: "", defaults: "", request: "", apps: [], ifaces: [], version: "unknown", host: "", readme: "", sessions: ["plasma", "labwc"] })
    property string shotPath: ""
    property string startPage: "bar"

    readonly property var pages: [
        { id: "bar", title: "Top Bar", icon: "view-list-details", file: "TopBarPage.qml" },
        { id: "dock", title: "Dock", icon: "dock-bottom", file: "DockPage.qml" },
        { id: "look", title: "Look", icon: "preferences-desktop-theme", file: "LookPage.qml" },
        { id: "session", title: "Session", icon: "system-log-out", file: "SessionPage.qml" },
        { id: "recon", title: "Recon", icon: "network-wireless", file: "ReconPage.qml" },
        { id: "about", title: "About", icon: "help-about", file: "AboutPage.qml" }
    ]

    Conf { id: conf }

    function arg(name) {
        var a = Qt.application.arguments
        for (var i = 0; i < a.length; i++)
            if (a[i].indexOf("--" + name + "=") === 0) return a[i].substring(name.length + 3)
        return ""
    }

    function show(id) {
        for (var i = 0; i < pages.length; i++)
            if (pages[i].id === id) {
                sidebar.current = i
                loader.setSource(Qt.resolvedUrl(pages[i].file), { conf: conf, ctx: ctx })
                return
            }
    }

    // test hook: same code path as the UI handlers (conf.set / conf.dock* / conf.requestResetLayout)
    function runSelftest(spec) {
        var acts = spec.split(","), ok = true
        for (var i = 0; i < acts.length; i++) {
            var a = acts[i], m
            if ((m = /^set:([^.=]+)\.([^=]+)=(.*)$/.exec(a))) conf.set(m[1], m[2], m[3])
            else if ((m = /^dock-add:(.+)$/.exec(a))) conf.dockAdd(m[1])
            else if (a === "dock-sep") conf.dockAdd("|")
            else if ((m = /^dock-remove:(\d+)$/.exec(a))) conf.dockRemove(parseInt(m[1]))
            else if ((m = /^dock-move:(\d+):(-?\d+)$/.exec(a))) conf.dockMove(parseInt(m[1]), parseInt(m[2]))
            else if (a === "reset-layout") { if (!conf.requestResetLayout()) ok = false }
            else { console.warn("SELFTEST unknown action " + a); ok = false }
        }
        selftestOk = ok
        drain.start()
    }

    property bool selftestOk: true
    // quit only after the async file writes have landed
    Timer {
        id: drain
        interval: 50
        repeat: true
        onTriggered: {
            if (conf.busy) return
            stop()
            var ok = selftestOk && conf.lastError === ""
            console.log(ok ? "SELFTEST OK" : "SELFTEST FAIL " + conf.lastError)
            Qt.exit(ok ? 0 : 1)
        }
    }

    Component.onCompleted: {
        var c = arg("context")
        if (c) {
            var t = conf.readFile(c)
            try { ctx = JSON.parse(t) } catch (e) { console.warn("bad context file " + c) }
        }
        conf.path = ctx.conf; conf.defaultPath = ctx.defaults; conf.requestPath = ctx.request
        conf.load()
        shotPath = arg("shot")
        startPage = arg("page") || "bar"
        var st = arg("selftest")
        if (st) { runSelftest(st); return }
        show(startPage)
        if (shotPath) shotTimer.start()
    }

    Timer {
        id: shotTimer
        interval: 1500
        onTriggered: body.grabToImage(function (r) {
            console.log(r.saveToFile(win.shotPath) ? "SHOT OK" : "SHOT FAIL")
            Qt.quit()
        })
    }

    pageStack.initialPage: Kirigami.Page {
        padding: 0
        globalToolBarStyle: Kirigami.ApplicationHeaderStyle.None
        Item {
            id: body
            anchors.fill: parent
            RowLayout {
                anchors.fill: parent
                spacing: 0
                Rectangle {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 180
                    color: Kirigami.Theme.alternateBackgroundColor
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        Kirigami.Heading {
                            text: "STAGOS"
                            level: 3
                            font.letterSpacing: 3
                            font.family: "JetBrains Mono"
                            Layout.margins: Kirigami.Units.largeSpacing * 2
                        }
                        Repeater {
                            model: win.pages
                            delegate: QQC2.ItemDelegate {
                                required property int index
                                required property var modelData
                                Layout.fillWidth: true
                                text: modelData.title
                                icon.name: modelData.icon
                                highlighted: sidebar.current === index
                                onClicked: win.show(modelData.id)
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }
                    QtObject { id: sidebar; property int current: 0 }
                }
                Kirigami.Separator { Layout.fillHeight: true }
                Loader { id: loader; Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }
}
