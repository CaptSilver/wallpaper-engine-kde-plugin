// Pyext's synchronous calls (get_folder_list, read_wallpaper_config, ...)
// return a thenable. Returned from a real Promise's callback, Qt resolves it
// later in a posted job by calling its then(). If the Pyext that made it has
// been destroyed by then -- Plasma 6.7's wallpaper KCM builds the settings
// page, throws it away and builds it again on every open -- a then() that
// needed Pyext's QML context threw, and Qt's handling of a throwing then()
// dereferences a null promise (QV4::RejectWrapper, Qt 6.12): the host
// process crashed. The thenable must keep working without its Pyext.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "PyextThenableLifetime"
    when: windowShown

    Component {
        id: pyextComp
        Plugin.Pyext {}
    }

    function test_a_thenable_resolves_after_its_pyext_is_gone() {
        const px = pyextComp.createObject(tc);
        verify(px);
        const thenable = px.get_folder_list("/nonexistent", {});
        px.destroy();
        wait(50);   // the deferred delete has run: Pyext and its context are gone
        let settled = "pending";
        Promise.resolve(thenable).then(v => { settled = "fulfilled"; },
                                       e => { settled = "rejected: " + e; });
        tryVerify(() => settled !== "pending", 1000);
        compare(settled, "fulfilled");
    }

    function test_then_still_runs_callbacks_synchronously() {
        const px = pyextComp.createObject(tc);
        let seen = null;
        px.read_wallpaper_config("123").then(res => { seen = res; });
        verify(seen !== null, "a Pyext thenable must still call back before returning");
        px.destroy();
    }
}
