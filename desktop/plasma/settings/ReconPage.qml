import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

PageFrame {
    id: page
    heading: "Recon"
    readonly property var choices: ["auto"].concat(ctx.ifaces || [])

    Kirigami.FormLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        QQC2.ComboBox {
            Kirigami.FormData.label: "Capture interface"
            model: page.choices
            currentIndex: {
                page.conf.rev
                var v = page.conf.get("recon", "capture_iface")
                var i = page.choices.indexOf(v)
                return v === "" ? 0 : (i < 0 ? 0 : i)
            }
            onActivated: page.conf.set("recon", "capture_iface", currentIndex === 0 ? "" : page.choices[currentIndex])
        }
        QQC2.Label {
            text: "Wireless interface for Kismet and monitor mode. Auto picks the dedicated capture card and never the built-in one."
            opacity: 0.6; font: Kirigami.Theme.smallFont; wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }
        QQC2.Label {
            visible: (page.ctx.ifaces || []).length === 0
            text: "No wireless interfaces found."
        }
    }
}
