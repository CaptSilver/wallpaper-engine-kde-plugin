// Reusable right-click menu showing all user playlists (Filtered Library
// excluded — it's live-bound to filter chips, can't accept manual adds).
// Selecting an entry calls manager.addItem; "New playlist…" prompts for a
// name and creates+adds.
import QtQuick
import QtQuick.Controls 2.3
import org.kde.plasma.core 2.0 as PlasmaCore

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
            // The sentinel "__filtered_library__" is never in
            // PlaylistsModel today, but guarding the delegate keeps the
            // promise the file header makes: Filtered Library is not a
            // manual-add target. height: 0 collapses the menu row cleanly.
            visible: id !== "__filtered_library__"
            height: visible ? implicitHeight : 0
            // Show "(added)" when the wallpaper is already in this
            // playlist, and disable the row so clicking it doesn't
            // create a silent duplicate. The disabled item still
            // appears so users see what's already covered.
            readonly property bool _alreadyIn:
                root.manager && root.item
                && typeof root.manager.playlistContains === "function"
                && root.manager.playlistContains(id, root.item.workshopid)
            enabled: ! _alreadyIn
            text: _alreadyIn ? i18nc("@item:inmenu playlist already contains wallpaper, %1=name", "%1  (added)", name) : name
            onTriggered: {
                if (root.manager && root.item)
                    root.manager.addItem(id, root.item.workshopid);
            }
        }
    }
    MenuSeparator { }
    MenuItem {
        text: i18nc("@action:inmenu create new playlist", "New playlist…")
        onTriggered: namePrompt.open()
    }

    Dialog {
        id: namePrompt
        objectName: "addPlaylistNamePrompt"
        title: i18nc("@title:window new playlist name prompt", "New playlist")
        modal: true
        anchors.centerIn: Overlay.overlay
        contentItem: TextField {
            id: nameField
            placeholderText: i18nc("@info:placeholder playlist name input", "Playlist name")
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
