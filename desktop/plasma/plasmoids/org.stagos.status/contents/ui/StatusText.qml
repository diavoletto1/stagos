import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import "palette.js" as Pal

// "LABEL value" in JetBrains Mono: value bright when good, red when hot, dim otherwise.
RowLayout {
    id: st

    property string label: ""
    property string value: ""
    property bool good: false
    property bool hot: false

    spacing: 5

    PC3.Label {
        text: st.label
        font.family: Pal.mono
        font.pixelSize: 11
        color: Pal.dim
    }
    PC3.Label {
        Layout.fillWidth: true
        text: st.value
        font.family: Pal.mono
        font.pixelSize: 11
        color: st.hot ? Pal.accent : (st.good ? Pal.text : Pal.dim)
        elide: Text.ElideRight
        textFormat: Text.PlainText
    }
}
