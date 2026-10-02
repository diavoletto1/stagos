import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

PageFrame {
    id: page
    heading: "Top Bar"

    readonly property var items: [
        { key: "stag_menu", label: "STAG menu", desc: "Stag services and settings, at the left end" },
        { key: "appmenu", label: "App menu", desc: "The menus (File, Edit, ...) of the focused app" },
        { key: "recon", label: "Recon", desc: "Tailscale, GPS and monitor-mode readout" },
        { key: "stagbot", label: "Stagbot", desc: "Stagbot and stag services status" },
        { key: "cpu", label: "CPU", desc: "Processor load" },
        { key: "ram", label: "Memory", desc: "Memory in use" },
        { key: "temp", label: "Temperature", desc: "CPU temperature" },
        { key: "net", label: "Network", desc: "Wi-Fi / network status" },
        { key: "bt", label: "Bluetooth", desc: "Bluetooth status" },
        { key: "vol", label: "Volume", desc: "Output volume" },
        { key: "bak", label: "Backup", desc: "Age of the last restic backup" },
        { key: "bat", label: "Battery", desc: "Charge level" },
        { key: "clock", label: "Clock", desc: "Date and time" }
    ]
    property date now: new Date()
    Timer { interval: 1000; running: true; repeat: true; onTriggered: page.now = new Date() }

    Repeater {
        model: page.items
        delegate: QQC2.SwitchDelegate {
            required property var modelData
            Layout.fillWidth: true
            checked: page.conf.rev >= 0 && page.conf.getBool("bar", modelData.key)
            onToggled: page.conf.set("bar", modelData.key, checked)
            contentItem: ColumnLayout {
                spacing: 0
                QQC2.Label { text: modelData.label; Layout.fillWidth: true }
                QQC2.Label { text: modelData.desc; Layout.fillWidth: true; opacity: 0.6; font: Kirigami.Theme.smallFont }
            }
        }
    }
    Kirigami.Separator { Layout.fillWidth: true }
    Kirigami.FormLayout {
        Layout.fillWidth: true
        QQC2.TextField {
            id: fmt
            Kirigami.FormData.label: "Clock format"
            text: page.conf.rev >= 0 ? page.conf.get("bar", "clock_format") : ""
            font.family: "JetBrains Mono"
            onTextEdited: page.conf.set("bar", "clock_format", text)
        }
        QQC2.Label {
            Kirigami.FormData.label: "Preview"
            text: Qt.formatDateTime(page.now, fmt.text)
            font.family: "JetBrains Mono"
        }
        QQC2.Label {
            text: "ddd weekday, d day, MMM month, HH:mm time"
            opacity: 0.6
            font: Kirigami.Theme.smallFont
        }
    }
}
