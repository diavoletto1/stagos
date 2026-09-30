import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

PageFrame {
    id: page
    heading: "About"

    Kirigami.FormLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        QQC2.Label { Kirigami.FormData.label: "StagOS"; text: page.ctx.version; font.family: "JetBrains Mono" }
        QQC2.Label { Kirigami.FormData.label: "Host"; text: page.ctx.host; font.family: "JetBrains Mono" }
        QQC2.Label { Kirigami.FormData.label: "Config"; text: page.ctx.conf; font.family: "JetBrains Mono"; wrapMode: Text.WrapAnywhere; Layout.maximumWidth: Kirigami.Units.gridUnit * 25 }
        QQC2.Label { Kirigami.FormData.label: "README"; text: page.ctx.readme; font.family: "JetBrains Mono"; wrapMode: Text.WrapAnywhere; Layout.maximumWidth: Kirigami.Units.gridUnit * 25 }
    }
}
