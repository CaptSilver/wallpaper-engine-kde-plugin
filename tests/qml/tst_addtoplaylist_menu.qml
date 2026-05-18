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

    // Every playlist row triggers addItem with its OWN id — not just the
    // first one. Pre-test the menu only had a "First" smoke test, so a
    // delegate binding bug (e.g. capturing the wrong index) would slip.
    function test_everyPlaylistRowAddsWithItsOwnId() {
        for (let i = 0; i < fakeManager.playlistsModel.count; ++i) {
            const expectedName = fakeManager.playlistsModel.get(i).name;
            const expectedId   = fakeManager.playlistsModel.get(i).id;
            let item = null;
            for (let j = 0; j < menu.count; ++j) {
                const it = menu.itemAt(j);
                if (it && it.text === expectedName) { item = it; break; }
            }
            verify(item !== null, "menu row not found for " + expectedName);
            fakeManager.lastAdd = {};
            item.triggered();
            compare(fakeManager.lastAdd.playlistId, expectedId,
                    "row \"" + expectedName + "\" must add with id " + expectedId);
            compare(fakeManager.lastAdd.workshopId, "test-workshop-id");
        }
    }

    // Filtered Library is intentionally absent: it's live-bound to the
    // Wallpapers-tab filter chips and can't accept manual adds. A future
    // delegate change that surfaces it as a row would be a real bug.
    function test_filteredLibraryAbsentFromMenu() {
        // Inject the sentinel row into the source model. The Repeater
        // currently mirrors playlistsModel verbatim, but the delegate
        // collapses the Filtered Library row to height=0 + visible=false
        // so it can't be invoked.
        fakeManager.playlistsModel.append({
            id: "__filtered_library__", name: "Filtered Library",
            mode: "shuffle", intervalMin: 15, itemCount: 0
        });
        let visibleHit = null;
        for (let i = 0; i < menu.count; ++i) {
            const it = menu.itemAt(i);
            if (it && it.text === "Filtered Library" && it.visible) {
                visibleHit = it; break;
            }
        }
        // Restore the model so subsequent tests aren't tainted.
        const lastIdx = fakeManager.playlistsModel.count - 1;
        fakeManager.playlistsModel.remove(lastIdx);
        verify(visibleHit === null,
               "Filtered Library must not be a visible menu row");
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
