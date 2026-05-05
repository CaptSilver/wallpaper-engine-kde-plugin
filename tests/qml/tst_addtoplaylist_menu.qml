// Smoke tests for AddToPlaylistMenu. Exercises the menu's bound signals
// directly (Menu.popup() needs a visible Window which qmltestrunner doesn't
// provide reliably).
import QtQuick
import QtTest
import QtQuick.Controls 2.3

import "../../plugin/contents/ui/components" as Components

TestCase {
    id: tc
    name: "AddToPlaylistMenu"
    width: 200; height: 200
    when: windowShown

    QtObject {
        id: fakeManager
        property var playlistsModel: ListModel {
            id: lm
            Component.onCompleted: {
                lm.append({ id: "1", name: "First",  mode: "sequential",
                            intervalMin: 15, itemCount: 0 });
                lm.append({ id: "2", name: "Second", mode: "shuffle",
                            intervalMin: 30, itemCount: 3 });
            }
        }
        property var lastAdd: ({})
        property var lastCreated: ""
        function createPlaylist(name) {
            lastCreated = name;
            return "fake-id-" + name;
        }
        function addItem(playlistId, workshopId) {
            lastAdd = { playlistId: playlistId, workshopId: workshopId };
            return true;
        }
    }

    Components.AddToPlaylistMenu {
        id: menu
        manager: fakeManager
        item: QtObject {
            property string workshopid: "test-workshop-id"
        }
    }

    function test_managerWired() {
        compare(menu.manager, fakeManager);
        compare(menu.item.workshopid, "test-workshop-id");
    }

    function test_modelPopulates() {
        compare(fakeManager.playlistsModel.count, 2);
    }

    function test_existingPlaylistMenuItemsTriggerAddItem() {
        let found = 0;
        for (let i = 0; i < menu.count; ++i) {
            const it = menu.itemAt(i);
            if (it && it.text && it.text === "First") {
                it.triggered();
                found += 1;
                break;
            }
        }
        verify(found > 0);
        compare(fakeManager.lastAdd.playlistId, "1");
        compare(fakeManager.lastAdd.workshopId, "test-workshop-id");
    }

    function test_namePromptAcceptedCreatesAndAdds() {
        const dialog = menu.namePromptDialog;
        verify(dialog !== null);
        const tf = _findTextField(dialog);
        if (tf) tf.text = "FreshList";
        dialog.accept();
        compare(fakeManager.lastCreated, "FreshList");
        compare(fakeManager.lastAdd.playlistId, "fake-id-FreshList");
        compare(fakeManager.lastAdd.workshopId, "test-workshop-id");
    }

    function test_namePromptAcceptedEmptyNoOp() {
        const dialog = menu.namePromptDialog;
        const tf = _findTextField(dialog);
        if (tf) tf.text = "  ";
        fakeManager.lastCreated = "";
        dialog.accept();
        compare(fakeManager.lastCreated, "");
    }

    function _findById(root, id_) {
        if (! root) return null;
        if (root.objectName === id_) return root;
        const children = root.data || root.children || [];
        for (let i = 0; i < children.length; ++i) {
            const found = _findById(children[i], id_);
            if (found) return found;
        }
        return null;
    }

    function _findTextField(root) {
        if (! root) return null;
        if (root.placeholderText !== undefined) return root;
        const children = root.data || root.children || [];
        for (let i = 0; i < children.length; ++i) {
            const found = _findTextField(children[i]);
            if (found) return found;
        }
        if (root.contentItem) return _findTextField(root.contentItem);
        return null;
    }
}
