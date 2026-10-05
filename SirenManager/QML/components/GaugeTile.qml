import QtQuick
import QtQuick.Layouts

// One reading of the system summary, as a task manager shows it: a title, the
// value in large type, a detail line and a fill bar. `fraction` < 0 means no
// reading yet (empty bar, "—").
Rectangle {
    id: tile

    property string title: ""
    property string value: "—"
    property string detail: ""
    property real fraction: -1
    property color accent: "#5ac878"

    // Past these fractions the bar turns amber, then red, whatever the accent.
    readonly property color barColor: fraction > 0.9 ? "#e05555" : fraction > 0.75 ? "#e0a030" : accent

    implicitHeight: 62
    color: "#111"; border.color: "#444"; radius: 4

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 1

        RowLayout {
            Layout.fillWidth: true
            Text { text: tile.title; color: "#888"; font.pixelSize: 11; font.bold: true }
            Item { Layout.fillWidth: true }
            Text { text: tile.value; color: "white"; font.pixelSize: 16; font.family: "Menlo"; font.bold: true }
        }
        Text {
            Layout.fillWidth: true
            text: tile.detail
            color: "#999"; font.pixelSize: 11; font.family: "Menlo"
            elide: Text.ElideRight
        }
        Item { Layout.fillHeight: true }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 6
            radius: 3
            color: "#2a2a2a"
            Rectangle {
                width: tile.fraction > 0 ? parent.width * Math.min(1, tile.fraction) : 0
                height: parent.height
                radius: 3
                color: tile.barColor
            }
        }
    }
}
