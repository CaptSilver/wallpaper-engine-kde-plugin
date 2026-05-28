// Error / unsupported-wallpaper info pane. Loaded by backendLoader
// whenever a wallpaper fails to instantiate or its source is empty/broken.
// This is the user's first impression of "something is wrong", so it has
// to read cleanly AND give them recovery actions instead of leaving them
// staring at a yellow text dump with nowhere to go.
import QtQuick 2.5
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.2

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami 2.6 as Kirigami

import ".."

Item {
    id: infoItem
    anchors.fill: parent
    property string info: "error"
    property string type: "unknown"
    property string wid: "unknown"
    property string source

    // Emitted by the recovery row's "Pick another wallpaper" button. The
    // host (main.qml's loadInfoShow) connects this to a clear-recovery
    // hint — opening Plasma's wallpaper-config dialog directly from QML
    // requires Plasmoid.internalAction which this Item doesn't reach, so
    // the parent decides how to handle the request.
    signal pickAnotherRequested

    // Theme-backed surface — works in light/dark/HDR instead of hardcoded
    // "yellow" which clashes with the user's color scheme.
    Rectangle {
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(infoItem.width * 0.7, 560)
        spacing: Kirigami.Units ? Kirigami.Units.largeSpacing : 16

        Kirigami.Icon {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 64
            Layout.preferredHeight: 64
            source: "dialog-error-symbolic"
            color: Kirigami.Theme.negativeTextColor
            fallback: "emblem-error"
        }

        Label {
            Layout.fillWidth: true
            text: i18nc("@info wallpaper load failure heading", "Wallpaper failed to load")
            font.bold: true
            font.pointSize: 18
            color: Kirigami.Theme.textColor
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }

        Label {
            Layout.fillWidth: true
            text: infoItem.info
            color: Kirigami.Theme.disabledTextColor
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 8
            rowSpacing: 4

            Label { text: i18nc("@label workshop id row", "Workshop ID:"); color: Kirigami.Theme.disabledTextColor }
            Label {
                Layout.fillWidth: true
                text: infoItem.wid
                color: Kirigami.Theme.textColor
                elide: Text.ElideRight
            }
            Label { text: i18nc("@label wallpaper type row", "Type:"); color: Kirigami.Theme.disabledTextColor }
            Label {
                Layout.fillWidth: true
                text: infoItem.type
                color: Kirigami.Theme.textColor
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 8

            Button {
                text: i18nc("@action:button copy workshop id to clipboard", "Copy ID")
                enabled: infoItem.wid && infoItem.wid !== "unknown"
                onClicked: clipboardHelper.text = infoItem.wid
            }
            Button {
                text: i18nc("@action:button open wallpaper workshop page", "Open Workshop")
                enabled: infoItem.wid && infoItem.wid !== "unknown"
                            && /^[0-9]+$/.test(infoItem.wid)
                onClicked: Qt.openUrlExternally(Common.getWorkshopUrl(infoItem.wid))
            }
            Button {
                text: i18nc("@action:button open wallpaper folder in file manager", "Open Folder")
                enabled: !!infoItem._folderUrl
                onClicked: Qt.openUrlExternally(infoItem._folderUrl)
            }
            // Always enabled — the parent's recovery hint (opening the
            // wallpaper config dialog) is meaningful regardless of wid /
            // folder availability.
            Button {
                text: i18nc("@action:button pick a different wallpaper", "Pick another wallpaper")
                onClicked: infoItem.pickAnotherRequested()
            }
        }
    }

    // Derive the wallpaper folder URL from the bare source string. Source
    // looks like "file:///path/to/scene.pkg+scene"; the folder is the
    // dirname. We don't try to be clever about non-file:// sources.
    readonly property string _folderUrl: {
        if (!source) return "";
        const m = source.match(/^(file:\/\/.*)\/[^/]+$/);
        return m ? m[1] : "";
    }

    // Hidden text edit used purely as a clipboard scratch — Qt 6's TextEdit
    // is the canonical way to copy text without pulling in additional
    // modules.
    TextEdit {
        id: clipboardHelper
        visible: false
        onTextChanged: {
            if (text) {
                selectAll();
                copy();
                text = "";
            }
        }
    }

    Component.onCompleted: {
        background.nowBackend = "InfoShow";
    }

    function play(){}
    function pause(){}
    function getMouseTarget() {}
}
