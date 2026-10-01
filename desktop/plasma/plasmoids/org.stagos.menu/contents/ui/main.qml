import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "palette.js" as Pal

// The STAG menu (the Apple menu of StagOS): compact = "STAG" in the bar, popup = about this computer,
// settings, the stag apps, session actions. Commands go through stag-ctl; destructive ones ask first.
PlasmoidItem {
    id: root

    property var about: ({})
    property var apps: []
    property bool shown: true          // [bar] stag_menu, re-read every few seconds (live toggle)
    property bool aboutOpen: false
    property var confirm: null         // {title, text, button, args} while a confirmation is showing

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: compactRepresentation
    toolTipMainText: ""
    toolTipSubText: ""

    // Plasma sizes the popup when it opens and does not grow it later: load the entries before that
    Component.onCompleted: refresh()
    onExpandedChanged: {
        if (root.expanded) {
            refresh();
        } else {
            root.aboutOpen = false;
            root.confirm = null;
        }
    }

    Exec {
        id: exec
    }

    function refresh() {
        exec.run("stag-ctl about", (code, out) => {
            const j = exec.json(out);
            if (j)
                about = j;
        });
        exec.run("stag-ctl apps", (code, out) => {
            const j = exec.json(out);
            apps = j && j.apps ? j.apps : [];
        });
    }

    function launch(cmd) {
        exec.run("setsid -f " + cmd + " >/dev/null 2>&1");
        root.expanded = false;
    }

    function ctl(args) {
        exec.run("stag-ctl " + args);
        root.expanded = false;
    }

    function ask(title, text, button, args) {
        confirm = {
            "title": title,
            "text": text,
            "button": button,
            "args": args
        };
    }

    Timer {
        interval: 60000
        running: !root.expanded
        repeat: true
        onTriggered: root.refresh()
    }
    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: exec.run("stag-status --layout", (code, out) => {
            const j = exec.json(out);
            if (j && j.stag_menu !== undefined)
                root.shown = j.stag_menu;
        })
    }

    compactRepresentation: MouseArea {
        Layout.minimumWidth: root.shown ? label.implicitWidth + Kirigami.Units.largeSpacing * 2 : 0
        Layout.preferredWidth: Layout.minimumWidth
        Layout.maximumWidth: Layout.minimumWidth
        Layout.fillHeight: true
        visible: root.shown
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        PC3.Label {
            id: label
            anchors.centerIn: parent
            text: "STAG"
            font.family: Pal.mono
            font.pixelSize: 12
            font.weight: Font.Bold
            font.letterSpacing: 1
            color: root.expanded ? Pal.accent : Pal.text
        }
    }

    fullRepresentation: Item {
        Layout.preferredWidth: 280
        Layout.minimumWidth: 280
        Layout.maximumWidth: 280
        // one fixed height for every view (Plasma does not resize an open popup): the tallest one
        Layout.preferredHeight: Math.max(menu.implicitHeight, aboutView.implicitHeight, confirmView.implicitHeight) + 16
        Layout.minimumHeight: Layout.preferredHeight
        Layout.maximumHeight: Layout.preferredHeight

        // ---- the menu ----
        ColumnLayout {
            id: menu
            visible: !root.confirm && !root.aboutOpen
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            spacing: 0

            MenuEntry {
                text: "About This Computer"
                trailing: ">"
                onTriggered: root.aboutOpen = true
            }
            Separator {}
            MenuEntry {
                text: "StagOS Settings..."
                visible: !!root.about.settings
                onTriggered: root.launch("stag-settings")
            }
            MenuEntry {
                text: "System Settings..."
                onTriggered: root.launch("systemsettings")
            }
            Separator {
                visible: root.apps.length > 0
            }
            Repeater {
                model: root.apps
                delegate: MenuEntry {
                    required property var modelData
                    text: modelData.title
                    onTriggered: root.ctl("app open " + exec.shq(modelData.name))
                }
            }
            Separator {}
            MenuEntry {
                text: "Lock Screen"
                onTriggered: root.ctl("session lock")
            }
            MenuEntry {
                text: "Sleep"
                onTriggered: root.ctl("session sleep")
            }
            MenuEntry {
                text: "Restart..."
                onTriggered: root.ask("Restart now?", "Open windows close.", "Restart", "session reboot")
            }
            MenuEntry {
                text: "Shut Down..."
                onTriggered: root.ask("Shut down now?", "Open windows close.", "Shut Down", "session poweroff")
            }
            Separator {}
            MenuEntry {
                text: "Log Out..."
                onTriggered: root.ask("Log out now?", "Open windows close.", "Log Out", "session logout")
            }
        }

        // ---- about this computer ----
        ColumnLayout {
            id: aboutView
            visible: root.aboutOpen && !root.confirm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            spacing: 4

            MenuEntry {
                text: "About This Computer"
                trailing: "<"
                onTriggered: root.aboutOpen = false
            }
            AboutPanel {
                Layout.fillWidth: true
                info: root.about
            }
        }

        // ---- confirmation for the destructive entries ----
        ColumnLayout {
            id: confirmView
            visible: !!root.confirm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 12
            spacing: 8

            PC3.Label {
                Layout.fillWidth: true
                text: root.confirm ? root.confirm.title : ""
                font.family: Pal.ui
                font.pixelSize: 14
                font.weight: Font.DemiBold
                color: Pal.text
            }
            PC3.Label {
                Layout.fillWidth: true
                text: root.confirm ? root.confirm.text : ""
                wrapMode: Text.WordWrap
                font.family: Pal.ui
                font.pixelSize: 12
                color: Pal.dim
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 8
                Item {
                    Layout.fillWidth: true
                }
                ConfirmButton {
                    text: "Cancel"
                    onClicked: root.confirm = null
                }
                ConfirmButton {
                    text: root.confirm ? root.confirm.button : ""
                    hot: true
                    onClicked: {
                        const args = root.confirm.args;
                        root.confirm = null;
                        root.ctl(args);
                    }
                }
            }
        }
    }
}
