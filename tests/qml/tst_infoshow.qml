import QtQuick
import QtTest

import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    name: "InfoShow"
    width: 200; height: 100
    when: windowShown

    // Sibling `background` provides the wek context surface. InfoShow's
    // Component.onCompleted writes background.nowBackend = "InfoShow"
    // (InfoShow.qml:129-130) — the sibling-id pattern lets QML scope
    // resolution reach it the same way the production main.qml does.
    BackgroundFake { id: background }

    Backend.InfoShow {
        id: info
        info: "test message"
        type: "scene"
        wid: "12345"
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

    function test_componentOnCompleted_setsBackgroundNowBackend() {
        compare(background.nowBackend, "InfoShow");
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

    // The recovery row's fourth button (added alongside Copy ID / Open
    // Workshop / Open Folder) emits the pickAnotherRequested signal that
    // main.qml's loadInfoShow connects to.
    function _findButtonByText(root, label) {
        const queue = [root]; const seen = new Set([root]);
        while (queue.length) {
            const n = queue.shift();
            if (n && typeof n.text === "string" && n.text === label
                && typeof n.clicked === "function") return n;
            const buckets = [n.children || [], n.data || []];
            for (const b of buckets) {
                if (!b || typeof b.length === "undefined") continue;
                for (let i = 0; i < b.length; i++) {
                    const c = b[i]; if (c && !seen.has(c)) { seen.add(c); queue.push(c); }
                }
            }
        }
        return null;
    }
    function test_pickAnotherButton_emitsSignal() {
        const btn = _findButtonByText(info, "Pick another wallpaper");
        verify(btn !== null);
        const spy = Qt.createQmlObject('import QtTest 1.0; SignalSpy {}', info);
        spy.target = info;
        spy.signalName = "pickAnotherRequested";
        btn.clicked();
        compare(spy.count, 1);
        spy.destroy();
    }
}
