import QtQuick
import QtQuick.Controls
import QtCore

// A SplitView whose handles can be seen and found: a strip in a color of its own
// (steel blue), with a grip, that turns orange under the mouse and brighter
// while dragged, and the resize cursor over it. Use it wherever panes resize,
// so every split in the app looks and behaves the same.
SplitView {
    id: split

    readonly property color handleColor: "#4a6a8a"
    readonly property color handleHoverColor: "#ff9f1a"
    readonly property color handlePressedColor: "#ffc766"
    readonly property int handleThickness: 8

    // Set a unique key to keep the pane sizes across restarts (stored in the
    // app's QSettings, restored once the panes exist, saved when a drag ends).
    property string stateKey: ""

    Settings {
        id: store
        category: "SplitView_" + split.stateKey
        property var state
    }

    Component.onCompleted: if (stateKey !== "") Qt.callLater(function() {
        if (store.state) split.restoreState(store.state)
    })
    onResizingChanged: if (!resizing && stateKey !== "") store.state = split.saveState()

    handle: Rectangle {
        id: strip
        implicitWidth: split.orientation === Qt.Horizontal ? split.handleThickness : split.width
        implicitHeight: split.orientation === Qt.Vertical ? split.handleThickness : split.height
        color: SplitHandle.pressed ? split.handlePressedColor
             : SplitHandle.hovered ? split.handleHoverColor
             : split.handleColor

        // Grip: three dots across the strip, lighter than it.
        Row {
            anchors.centerIn: parent
            spacing: 4
            rotation: split.orientation === Qt.Horizontal ? 90 : 0
            Repeater {
                model: 3
                Rectangle {
                    width: 3; height: 3; radius: 1.5
                    color: SplitHandle.pressed || SplitHandle.hovered ? "#1e1e1e" : "#9fb8d0"
                }
            }
        }

        HoverHandler {
            cursorShape: split.orientation === Qt.Horizontal ? Qt.SplitHCursor : Qt.SplitVCursor
        }
    }
}
