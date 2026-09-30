import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ScrollablePage {
    id: page
    property var conf
    property var ctx
    readonly property var kinds: [ { name: "Plasma", value: "plasma" }, { name: "labwc", value: "labwc" } ]

    Kirigami.FormLayout {
        QQC2.ComboBox {
            Kirigami.FormData.label: "Default session"
            model: page.kinds
            textRole: "name"
            currentIndex: page.conf.rev >= 0 && page.conf.get("session", "default") === "labwc" ? 1 : 0
            onActivated: page.conf.set("session", "default", page.kinds[currentIndex].value)
        }
        QQC2.Label {
            text: "Used at the next login on tty1. Plasma falls back to labwc by itself if it cannot start."
            opacity: 0.6; font: Kirigami.Theme.smallFont; wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }
        Item { Kirigami.FormData.isSection: true }
        QQC2.Button {
            Kirigami.FormData.label: "Layout"
            text: "Reset layout..."
            icon.name: "edit-reset"
            onClicked: confirm.open()
        }
        QQC2.Label {
            id: done
            visible: false
            text: "Reset requested."
        }
    }

    Kirigami.PromptDialog {
        id: confirm
        title: "Reset layout"
        subtitle: "Rebuild the top bar and dock from the StagOS defaults. Panels you changed by hand are replaced."
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: done.visible = page.conf.requestResetLayout()
    }
}
