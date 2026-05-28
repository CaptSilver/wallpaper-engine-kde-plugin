import QtQuick 2.8
import QtQuick.Controls 2.1
import QtQuick.Dialogs
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami as Kirigami

// Color picker button that shows current color and opens ColorDialog on
// click. Now keyboard-accessible: Tab focuses, Space/Enter opens the
// dialog. A visible focus ring satisfies sighted-keyboard users.
Rectangle {
    id: colorBtn

    property color def_val: "#ffffff"
    property color colorValue: def_val

    // res_val as string for saving in format "r g b"
    property string res_val: {
        const c = colorValue;
        return `${c.r.toFixed(3)} ${c.g.toFixed(3)} ${c.b.toFixed(3)}`;
    }

    // Fires only when the user accepts the ColorDialog. Lets callers
    // distinguish user picks from binding-driven colorValue updates
    // (which otherwise look identical via onColorValueChanged).
    signal colorPicked(color value)

    implicitWidth: 60
    implicitHeight: 30
    width: 60
    height: 30
    radius: 4
    color: colorValue
    // Outer border thickens + accent-colors when keyboard-focused so the
    // user can tell where they are without a mouse.
    border.color: activeFocus ? Kirigami.Theme.highlightColor : Qt.darker(colorValue, 1.2)
    border.width: activeFocus ? 2 : 1

    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: "Color picker"
    Accessible.description: "Opens a color picker dialog"
    Accessible.onPressAction: colorDialog.open()
    Keys.onSpacePressed: colorDialog.open()
    Keys.onReturnPressed: colorDialog.open()
    Keys.onEnterPressed: colorDialog.open()

    function finish() {
        colorValue = def_val;
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            colorBtn.forceActiveFocus();
            colorDialog.open();
        }
    }

    ColorDialog {
        id: colorDialog
        title: i18nc("@title:window color picker", "Select Color")
        selectedColor: colorBtn.colorValue
        onAccepted: {
            colorBtn.colorValue = selectedColor;
            colorBtn.colorPicked(selectedColor);
        }
    }
}
