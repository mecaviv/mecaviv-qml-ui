import QtQuick

// A pill with two or more segments and a highlight that slides to the chosen
// one: a nicer choice between exclusive options than a row of buttons. Click a
// segment to choose it; `activated(index)` fires on a user choice only.
Rectangle {
    id: toggle

    property var model: []                    // segment labels
    property int currentIndex: 0
    property int segmentWidth: 62
    property color accent: "#4a6a8a"          // the steel blue of the split handles
    signal activated(int index)

    implicitWidth: segmentWidth * model.length + 4
    implicitHeight: 24
    radius: height / 2
    color: "#1b1b1b"
    border.color: "#555"

    // The sliding highlight.
    Rectangle {
        y: 2; height: parent.height - 4
        width: toggle.segmentWidth
        x: 2 + toggle.currentIndex * toggle.segmentWidth
        radius: height / 2
        color: toggle.accent
        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }

    Row {
        x: 2; y: 0
        Repeater {
            model: toggle.model
            Item {
                width: toggle.segmentWidth; height: toggle.height
                Text {
                    anchors.centerIn: parent
                    text: modelData
                    font.pixelSize: 11
                    font.bold: index === toggle.currentIndex
                    color: index === toggle.currentIndex ? "#ffffff" : "#999"
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (index !== toggle.currentIndex) toggle.activated(index)
                }
            }
        }
    }
}
