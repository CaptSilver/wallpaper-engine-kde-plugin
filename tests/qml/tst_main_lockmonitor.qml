import QtQuick
import QtTest
import Helpers 1.0
import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "Main_LockMonitor"
    when: windowShown
    width: 400; height: 300
    Component { id: rigComp; ScreenRig {} }

    function _findLockMonitor(rig) {
        return rig._find(rig.mainItem,
            o => typeof o.active !== "undefined"
              && typeof o.screenSaverActiveChanged !== "undefined");
    }

    function test_lockMonitorActive_pausesViaBackgroundOk() {
        failOnWarning(/wallpaper is not defined/);
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0,0,1920,1080) });
        tryVerify(() => rig.background() !== null, 2000);
        const lock = _findLockMonitor(rig);
        verify(lock !== null);
        // Initially: lock inactive -> background.ok = true (no other pause sources).
        compare(rig.background().ok, true);
        // Activate the lock -> background.ok flips false (gated by `!lockMonitor.active`).
        lock.active = true;
        tryVerify(() => rig.background().ok === false, 2000,
                  "background.ok did not drop on lock");
        // Deactivate -> background.ok recovers.
        lock.active = false;
        tryVerify(() => rig.background().ok === true, 2000,
                  "background.ok did not recover on unlock");
        rig.destroy();
    }
}
