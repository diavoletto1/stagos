import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

PageFrame {
    id: page
    heading: "Session"
    // stag-session --status, captured by the launcher (ctx.session_next, ctx.session_fails)
    readonly property bool fallback: (ctx.session_next || "").indexOf("shell") === 0
    property bool retried: false

    Kirigami.FormLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        QQC2.Label {
            Kirigami.FormData.label: "Next login"
            text: page.retried ? "plasma (fallback cleared)" : (page.ctx.session_next || "plasma")
            font.family: "JetBrains Mono"; wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }
        QQC2.Label {
            text: "Plasma starts on tty1 after the disk is unlocked. If it fails to start twice in a row, tty1 stays a plain shell until you run stag-session retry or reboot. Log: ~/.cache/stagos/session.log"
            opacity: 0.6; font: Kirigami.Theme.smallFont; wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        }
        QQC2.Button {
            visible: page.fallback && !page.retried
            text: "Retry Plasma at next login"
            icon.name: "view-refresh"
            // the same as `stag-session retry` without starting anything: the fail counter goes back to 0
            onClicked: page.retried = page.conf.writeFile(page.ctx.session_fails_file, "0\n")
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
