import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "palette.js" as Pal

// Flat HUD button: hairline border, text and/or icon, red fill only when `hot` (an active state).
Rectangle {
    id: btn

    property string text: ""
    property string iconName: ""
    property bool hot: false
    signal clicked()

    implicitWidth: Math.max(28, row.implicitWidth + 16)
    implicitHeight: 26
    radius: Pal.radius
    color: hot ? Pal.accent : (mouse.pressed ? Pal.hairline : Pal.surface)
    border.width: 1
    border.color: mouse.containsMouse && enabled ? Pal.dim : Pal.hairline
    opacity: enabled ? 1 : 0.4

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Kirigami.Icon {
            visible: btn.iconName !== ""
            Layout.preferredWidth: 14
            Layout.preferredHeight: 14
            source: btn.iconName
            color: Pal.text
            isMask: true
        }
        PC3.Label {
            visible: btn.text !== ""
            text: btn.text
            font.family: Pal.ui
            font.pixelSize: 12
            color: Pal.text
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
