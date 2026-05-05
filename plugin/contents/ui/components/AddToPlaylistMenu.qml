// Reusable right-click menu showing all user playlists (Filtered Library
// excluded — it's live-bound to filter chips, can't accept manual adds).
// Selecting an entry calls manager.addItem; "New playlist…" prompts for a
// name and creates+adds.
import QtQuick
import QtQuick.Controls 2.3

Menu {
    id: root

    property var manager: null
    property var item: null  // wallpaper item (must have .workshopid)
    // Test surface — exposes the inner name-prompt dialog so tests can fire
    // its accepted signal without needing window-positioning machinery.
    readonly property alias namePromptDialog: namePrompt

    Repeater {
        model: root.manager ? root.manager.playlistsModel : null
        delegate: MenuItem {
            text: name
            onTriggered: {
                if (root.manager && root.item)
                    root.manager.addItem(id, root.item.workshopid);
            }
        }
    }
    MenuSeparator { }
    MenuItem {
        text: "New playlist…"
        onTriggered: namePrompt.open()
    }

    Dialog {
        id: namePrompt
        objectName: "addPlaylistNamePrompt"
        title: "New playlist"
        modal: true
        anchors.centerIn: Overlay.overlay
        contentItem: TextField {
            id: nameField
            placeholderText: "Playlist name"
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: {
            if (root.manager && root.item && nameField.text.trim() !== "") {
                const newId = root.manager.createPlaylist(nameField.text.trim());
                root.manager.addItem(newId, root.item.workshopid);
            }
            nameField.text = "";
        }
    }
}
