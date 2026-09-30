import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ScrollablePage {
    id: page
    property var conf
    property var ctx
    readonly property var list: { conf.rev; return conf.dockList() }

    function appFor(id) {
        var a = ctx.apps || []
        for (var i = 0; i < a.length; i++) if (a[i].id === id) return a[i]
        return null
    }
    function iconSource(icon) { return icon && icon.charAt(0) === "/" ? "file://" + icon : (icon || "application-x-executable") }

    actions: [
        Kirigami.Action { text: "Add app"; icon.name: "list-add"; onTriggered: picker.open() },
        Kirigami.Action { text: "Add separator"; icon.name: "view-split-left-right"; onTriggered: page.conf.dockAdd("|") }
    ]

    ListView {
        id: view
        model: page.list
        delegate: QQC2.ItemDelegate {
            id: row
            required property int index
            required property string modelData
            readonly property bool sep: modelData === "|"
            readonly property var app: page.appFor(modelData)
            width: ListView.view.width
            contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    visible: !row.sep
                    source: page.iconSource(row.app ? row.app.icon : "")
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                }
                Kirigami.Separator { visible: row.sep; Layout.fillWidth: true }
                ColumnLayout {
                    visible: !row.sep
                    spacing: 0
                    Layout.fillWidth: true
                    QQC2.Label { text: row.app ? row.app.name : row.modelData; Layout.fillWidth: true; elide: Text.ElideRight }
                    QQC2.Label {
                        text: row.app ? row.modelData : "not installed, skipped"
                        opacity: 0.6; font: Kirigami.Theme.smallFont
                    }
                }
                QQC2.ToolButton { icon.name: "go-up"; enabled: row.index > 0; onClicked: page.conf.dockMove(row.index, -1) }
                QQC2.ToolButton { icon.name: "go-down"; enabled: row.index < page.list.length - 1; onClicked: page.conf.dockMove(row.index, 1) }
                QQC2.ToolButton { icon.name: "edit-delete"; onClicked: page.conf.dockRemove(row.index) }
            }
        }
    }

    Kirigami.OverlaySheet {
        id: picker
        title: "Add to the dock"
        ListView {
            id: appList
            implicitWidth: Kirigami.Units.gridUnit * 22
            header: QQC2.TextField { id: q; width: appList.width; placeholderText: "Search apps" }
            model: (page.ctx.apps || []).filter(function (a) {
                return a.name.toLowerCase().indexOf(q.text.toLowerCase()) >= 0 && page.list.indexOf(a.id) < 0
            })
            delegate: QQC2.ItemDelegate {
                required property var modelData
                width: ListView.view.width
                text: modelData.name
                icon.name: modelData.icon.charAt(0) === "/" ? "" : modelData.icon
                onClicked: { page.conf.dockAdd(modelData.id); picker.close() }
            }
        }
    }
}
