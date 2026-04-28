import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    name: "Backend_QtMultimedia"
    width: 200; height: 100
    when: windowShown

    BackgroundFake { id: background }

    Backend.QtMultimedia {
        id: qm
        source: "stub://video.mp4"
    }

    function test_backendNameSetByCompleted() {
        compare(background.nowBackend, "QtMultimedia");
    }

    function test_play_pause_doNotThrow() {
        qm.play();
        qm.pause();
        verify(true);
    }

    function test_displayModeBranches() {
        for (const m of [
            Plugin.Common.DisplayMode.Aspect,
            Plugin.Common.DisplayMode.Crop,
            Plugin.Common.DisplayMode.Scale,
        ]) {
            background.displayMode = m;
            qm.displayModeChanged();
        }
        verify(true);
    }

    function test_getMouseTargetReturnsUndefined() {
        compare(qm.getMouseTarget(), undefined);
    }
}
