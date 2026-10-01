import QtQuick
import org.kde.plasma.components as PC3
import "palette.js" as Pal

// Confirm dialog button; `hot` = the destructive action, red.
Rectangle {
    id: btn

    property string text: ""
    property bool hot: false
    signal clicked()

    implicitWidth: Math.max(72, label.implicitWidth + 20)
    implicitHeight: 26
    radius: Pal.radius
    color: hot ? Pal.accent : Pal.surface
    border.width: 1
    border.color: mouse.containsMouse ? Pal.dim : Pal.hairline

    PC3.Label {
        id: label
        anchors.centerIn: parent
        text: btn.text
        font.family: Pal.ui
        font.pixelSize: 12
        color: Pal.text
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
