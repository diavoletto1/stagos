import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import "palette.js" as Pal

// One STAG menu row: Inter text, hairline highlight on hover.
Rectangle {
    id: entry

    property string text: ""
    property string trailing: ""
    signal triggered()

    Layout.fillWidth: true
    implicitHeight: 26
    radius: Pal.radius - 1
    color: mouse.containsMouse ? Pal.hairline : "transparent"

    PC3.Label {
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: entry.text
        font.family: Pal.ui
        font.pixelSize: 13
        color: Pal.text
        textFormat: Text.PlainText
    }
    PC3.Label {
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: entry.trailing !== ""
        text: entry.trailing
        font.family: Pal.mono
        font.pixelSize: 12
        color: Pal.dim
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: entry.triggered()
    }
}
