import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A command (or any text) a developer is meant to paste somewhere: selectable with the mouse, and a
// button that puts all of it on the clipboard. Wraps anywhere, so a long path never makes the dialog
// scroll sideways. The font follows the platform (Consolas on Windows, Menlo elsewhere).
ColumnLayout {
    id: block

    property string title: ""
    property string hint: ""
    property string text: ""
    property bool copied: false

    spacing: 3

    Label {
        visible: block.title !== ""
        text: block.title
        color: "#9ab"; font.pixelSize: 12; font.bold: true
    }
    Label {
        visible: block.hint !== ""
        Layout.fillWidth: true
        text: block.hint
        wrapMode: Text.Wrap
        color: "#888"; font.pixelSize: 11
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: edit.implicitHeight + 12
            color: "#111"; border.color: "#444"; radius: 4
            TextEdit {
                id: edit
                anchors.fill: parent; anchors.margins: 6
                readOnly: true
                selectByMouse: true
                persistentSelection: true
                wrapMode: TextEdit.WrapAnywhere
                text: block.text
                color: "#cfd8e0"
                selectionColor: "#4a6a8a"
                font.family: Qt.platform.os === "windows" ? "Consolas" : "Menlo"
                font.pixelSize: 12
            }
        }
        Button {
            text: block.copied ? "Copié ✓" : "Copier"
            Layout.alignment: Qt.AlignTop
            onClicked: {
                edit.forceActiveFocus()
                edit.selectAll()
                edit.copy()
                block.copied = true
                resetCopied.restart()
            }
        }
    }
    Timer { id: resetCopied; interval: 1800; onTriggered: block.copied = false }
}
