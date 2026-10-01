import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

// Scrolling page with a heading; children go below the heading.
QQC2.ScrollView {
    id: frame
    property string heading: ""
    property var conf
    property var ctx
    default property alias content: col.data
    contentWidth: availableWidth
    clip: true

    ColumnLayout {
        id: col
        width: frame.availableWidth
        spacing: Kirigami.Units.largeSpacing
        Kirigami.Heading {
            text: frame.heading
            level: 2
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing * 2
        }
    }
}
