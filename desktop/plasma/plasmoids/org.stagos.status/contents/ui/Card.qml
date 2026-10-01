import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import "palette.js" as Pal

// A Control Center section: #0a0a0a card, hairline border, small caps heading, content below.
Rectangle {
    id: card

    property string heading: ""
    default property alias content: body.data

    implicitHeight: col.implicitHeight + 20
    radius: Pal.radius
    color: Pal.bg
    border.width: 1
    border.color: Pal.hairline

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: 10
        spacing: 6

        PC3.Label {
            visible: card.heading !== ""
            text: card.heading.toUpperCase()
            font.family: Pal.mono
            font.pixelSize: 10
            font.letterSpacing: 1
            color: Pal.dim
        }
        ColumnLayout {
            id: body
            Layout.fillWidth: true
            spacing: 6
        }
    }
}
