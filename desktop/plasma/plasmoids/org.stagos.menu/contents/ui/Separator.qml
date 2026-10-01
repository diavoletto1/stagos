import QtQuick
import QtQuick.Layouts
import "palette.js" as Pal

// Hairline between STAG menu groups.
Item {
    Layout.fillWidth: true
    implicitHeight: 9

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        height: 1
        color: Pal.hairline
    }
}
