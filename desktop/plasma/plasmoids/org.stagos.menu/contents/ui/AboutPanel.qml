import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import "palette.js" as Pal

// About this computer: the `stag-ctl about` JSON as label / value rows (values in JetBrains Mono).
Rectangle {
    id: panel

    property var info: ({})
    readonly property var bat: info.battery || ({})

    implicitHeight: rows.implicitHeight + 16
    Layout.topMargin: 2
    Layout.bottomMargin: 4
    radius: Pal.radius
    color: Pal.bg
    border.width: 1
    border.color: Pal.hairline

    ColumnLayout {
        id: rows
        anchors.fill: parent
        anchors.margins: 8
        spacing: 3

        Repeater {
            model: [
                ["Host", panel.info.host || ""],
                ["System", "StagOS" + (panel.info.session ? "  " + panel.info.session : "")],
                ["Kernel", panel.info.kernel || ""],
                ["CPU", (panel.info.cpu || "").replace(/\(R\)|\(TM\)|CPU /g, "").replace(/\s+/g, " ")],
                ["Uptime", panel.info.uptime || ""],
                ["Memory", panel.info.ram_total_mb ? (panel.info.ram_used_mb / 1024).toFixed(1) + " / " + (panel.info.ram_total_mb / 1024).toFixed(1) + " GB" : ""],
                ["Disk", panel.info.disk_total_gb ? panel.info.disk_used_gb + " / " + panel.info.disk_total_gb + " GB" : ""],
                ["Battery", panel.bat.present ? panel.bat.capacity + "%  health " + panel.bat.health + "%" + (panel.bat.cycles ? "  " + panel.bat.cycles + " cycles" : "") : "none"]
            ]
            delegate: RowLayout {
                id: aboutRow
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                PC3.Label {
                    Layout.preferredWidth: 56
                    text: aboutRow.modelData[0]
                    font.family: Pal.ui
                    font.pixelSize: 11
                    color: Pal.dim
                }
                PC3.Label {
                    Layout.fillWidth: true
                    text: aboutRow.modelData[1]
                    font.family: Pal.mono
                    font.pixelSize: 11
                    color: Pal.text
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
            }
        }
    }
}
