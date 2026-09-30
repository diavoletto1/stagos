import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import "palette.js" as Pal

// One top bar readout: JetBrains Mono text, dim when off, red when hot (alert/active), tooltip from stag-status.
RowLayout {
    id: readout

    property var field: ({})
    property string clockText: ""
    property bool divider: false
    property bool active: false

    spacing: 5

    Rectangle {
        visible: readout.divider
        Layout.preferredWidth: 1
        Layout.preferredHeight: 12
        Layout.rightMargin: 4
        color: Pal.hairline
    }

    // the Stagbot readout is a status dot plus its label
    Rectangle {
        visible: readout.field.id === "stagbot"
        Layout.preferredWidth: 6
        Layout.preferredHeight: 6
        radius: 3
        color: readout.field.state === "hot" ? Pal.accent : (readout.field.state === "ok" ? Pal.text : Pal.dim)
    }

    PC3.Label {
        id: label
        text: readout.field.id === "clock" && readout.clockText !== "" ? readout.clockText : (readout.field.text || "")
        font.family: Pal.mono
        font.pixelSize: 12
        color: readout.field.state === "hot" ? Pal.accent : (readout.field.state === "off" ? Pal.dim : Pal.text)
        textFormat: Text.PlainText

        PlasmaCore.ToolTipArea {
            anchors.fill: parent
            mainText: readout.field.tooltip || ""
            active: !readout.active && (readout.field.tooltip || "") !== ""
        }
    }
}
