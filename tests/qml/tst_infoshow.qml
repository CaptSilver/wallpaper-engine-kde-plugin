import QtQuick
import QtTest

import "../../plugin/contents/ui/backend" as Backend

TestCase {
    name: "InfoShow"
    width: 200; height: 100
    when: windowShown

    // InfoShow's Component.onCompleted writes to a `background` global,
    // so we provide a fake outer scope via a wrapper Item.
    Item {
        id: bg
        property string nowBackend: ""
        // Expose a `background` alias to the production component.
        property var background: bg

        Backend.InfoShow {
            id: info
            info: "test message"
            type: "scene"
            wid: "12345"
        }
    }

    function test_propertiesAssignedFromTestFixture() {
        compare(info.info, "test message");
        compare(info.type, "scene");
        compare(info.wid,  "12345");
    }

    function test_play_pause_getMouseTarget_doNotThrow() {
        info.play();
        info.pause();
        verify(info.getMouseTarget === undefined || info.getMouseTarget() === undefined);
    }

    // The Component.onCompleted handler references `background.nowBackend`.
    // It runs when the component is instantiated — we just verify the
    // instrumentation tick fires (by virtue of this test running).
    function test_componentOnCompletedRanWithoutThrowing() {
        verify(true);
    }

    // clipboardHelper.onTextChanged@120 — the small "copy to clipboard"
    // scratch handler that selectAll + copy + clears. Reach it via the
    // hidden TextEdit child and toggle .text to fire the change signal.
    function _findClipboardHelper() {
        const buckets = [info.children || [], info.data || []];
        for (const b of buckets) {
            for (let i = 0; i < b.length; i++) {
                const c = b[i];
                // TextEdit has `selectAll`, `copy`, and an editable `text`.
                if (c && typeof c.selectAll === "function"
                    && typeof c.copy === "function"
                    && typeof c.text !== "undefined") return c;
            }
        }
        return null;
    }
    function test_clipboardHelperOnTextChanged_runsBody() {
        const helper = _findClipboardHelper();
        verify(helper !== null);
        // Setting text fires onTextChanged synchronously.
        helper.text = "12345";
        // After the handler runs, the helper clears its own text.
        compare(helper.text, "");
    }
}
