import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

PageFrame {
    id: page
    heading: "Look"

    // animation_factor values: slow 1.0, normal 0.7, fast 0.4
    readonly property var speeds: [
        { name: "Slow", value: "1.0" }, { name: "Normal", value: "0.7" }, { name: "Fast", value: "0.4" }
    ]
    function speedIndex() {
        var f = parseFloat(conf.get("effects", "animation_factor")), best = 1, d = 9
        for (var i = 0; i < speeds.length; i++) {
            var dd = Math.abs(parseFloat(speeds[i].value) - f)
            if (dd < d) { d = dd; best = i }
        }
        return best
    }

    Kirigami.FormLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        QQC2.Switch {
            Kirigami.FormData.label: "Blur"
            text: "Blur behind panels and popups"
            checked: page.conf.rev >= 0 && page.conf.getBool("effects", "blur")
            onToggled: page.conf.set("effects", "blur", checked)
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: "Animation speed"
            model: page.speeds
            textRole: "name"
            currentIndex: page.conf.rev >= 0 ? page.speedIndex() : 1
            onActivated: page.conf.set("effects", "animation_factor", page.speeds[currentIndex].value)
        }
        QQC2.Label {
            text: "Window animations and effects are applied to KWin as soon as you change them."
            opacity: 0.6; font: Kirigami.Theme.smallFont; wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }
    }
}
