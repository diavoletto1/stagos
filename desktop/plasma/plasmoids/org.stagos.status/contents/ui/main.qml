import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "palette.js" as Pal

// Top bar readouts from `stag-status --json` (polled; it re-reads [bar] of desktop.conf on every call, so
// the StagOS Settings toggles show up without a plasmashell restart). The full representation is the
// Control Center: one plasmoid, one click target, one poller for the bar and one for the popup.
PlasmoidItem {
    id: root

    property var fields: []
    property string clockFormat: "ddd d MMM  HH:mm"
    property date now: new Date()
    property bool statusBusy: false

    // Control Center state: `stag-ctl control` (all toggles, sliders, media, recon) + `stag-ctl stagbot status`
    property var cc: ({})
    property var bot: ({})
    property bool ccBusy: false

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: compactRepresentation
    toolTipMainText: ""
    toolTipSubText: ""

    Exec {
        id: exec
    }

    function pollStatus() {
        if (statusBusy)
            return;
        statusBusy = true;
        exec.run("stag-status --json", (code, out) => {
            statusBusy = false;
            const j = exec.json(out);
            if (j && j.fields) {
                fields = j.fields;
                if (j.clock_format)
                    clockFormat = j.clock_format;
            }
        });
    }

    function pollControl() {
        if (ccBusy)
            return;
        ccBusy = true;
        exec.run("stag-ctl control", (code, out) => {
            ccBusy = false;
            const j = exec.json(out);
            if (j)
                cc = j;
        });
    }

    function pollBot() {
        exec.run("stag-ctl stagbot status", (code, out) => {
            const j = exec.json(out);
            bot = j && j.services ? j : ({});
        });
    }

    function run(cmd, cb) {
        exec.run(cmd, cb);
    }
    function quote(text) {
        return exec.shq(text);
    }
    function parse(text) {
        return exec.json(text);
    }

    // run a stag-ctl action; its JSON answer replaces the matching part of the Control Center state
    function act(args, key) {
        exec.run("stag-ctl " + args, (code, out) => {
            const j = exec.json(out);
            if (key && j && !j.error) {
                const c = Object.assign({}, cc);
                c[key] = j;
                cc = c;
            }
            pollStatus();
        });
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pollStatus()
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }
    Timer {
        interval: 2500
        running: root.expanded
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pollControl()
    }
    Timer {
        interval: 30000
        running: root.expanded
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pollBot()
    }

    compactRepresentation: MouseArea {
        id: compact
        Layout.minimumWidth: row.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: Layout.minimumWidth
        Layout.fillHeight: true
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing * 3

            Repeater {
                model: root.fields
                delegate: Readout {
                    required property var modelData
                    required property int index
                    field: modelData
                    clockText: Qt.formatDateTime(root.now, root.clockFormat)
                    // a hairline between groups (recon | stats | stagbot | core)
                    divider: index > 0 && root.fields[index - 1].group !== modelData.group
                    active: root.expanded
                }
            }
        }
    }

    fullRepresentation: ControlCenter {
        plasmoidRoot: root
    }
}
