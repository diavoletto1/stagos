import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "palette.js" as Pal

// Control Center toggle tile: icon disc (red when on), title, one line of state. Click = toggle.
Rectangle {
    id: tile

    property string title: ""
    property string subtitle: ""
    property string iconName: ""
    property bool on: false
    property bool available: true
    signal toggled()

    implicitHeight: 52
    radius: Pal.radius
    color: Pal.bg
    border.width: 1
    border.color: mouse.containsMouse && tile.available ? Pal.dim : Pal.hairline
    opacity: available ? 1 : 0.5

    RowLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 10

        Rectangle {
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            radius: 14
            color: tile.on ? Pal.accent : Pal.hairline

            Kirigami.Icon {
                anchors.centerIn: parent
                width: 16
                height: 16
                source: tile.iconName
                color: Pal.text
                isMask: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            PC3.Label {
                Layout.fillWidth: true
                text: tile.title
                font.family: Pal.ui
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: Pal.text
                elide: Text.ElideRight
            }
            PC3.Label {
                Layout.fillWidth: true
                text: tile.subtitle
                font.family: Pal.ui
                font.pixelSize: 11
                color: Pal.dim
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: tile.available
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.toggled()
    }
}
