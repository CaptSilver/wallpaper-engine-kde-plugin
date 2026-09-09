// The user-facing pause (D-Bus / global shortcut, routed through
// PlaylistController) has to stop the renderer, not just playlist rotation:
// it is a term in main.qml's background.ok gate, alongside the window,
// power and lock conditions.
import QtQuick
import QtTest
import Helpers 1.0

TestCase {
    id: tc
    name: "Main_UserPause"
    when: windowShown
    width: 400; height: 300
    Component { id: rigComp; ScreenRig {} }

    function _findLockMonitor(rig) {
        return rig._find(rig.mainItem,
            o => typeof o.active !== "undefined"
              && typeof o.screenSaverActiveChanged !== "undefined");
    }

    // Stands in for the loaded backend so play/pause dispatch is observable.
    Component {
        id: fakeBackendComp
        QtObject {
            property int playCount:  0
            property int pauseCount: 0
            function play()  { playCount  += 1; }
            function pause() { pauseCount += 1; }
        }
    }

    function _rig() {
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0,0,1920,1080) });
        tryVerify(() => rig.background() !== null, 2000);
        tryVerify(() => rig.playlistController() !== null, 2000);
        return rig;
    }

    function test_pauseClosesRenderGate() {
        const rig = _rig();
        const ctrl = rig.playlistController();
        compare(rig.background().ok, true, "gate should start open");
        ctrl.pause();
        tryVerify(() => rig.background().ok === false, 2000,
                  "user pause did not close the render gate");
        ctrl.resume();
        tryVerify(() => rig.background().ok === true, 2000,
                  "resume did not reopen the render gate");
        rig.destroy();
    }

    function test_togglePauseFlipsRenderGate() {
        const rig = _rig();
        const ctrl = rig.playlistController();
        ctrl.togglePause();
        tryVerify(() => rig.background().ok === false, 2000,
                  "toggle into pause did not close the render gate");
        ctrl.togglePause();
        tryVerify(() => rig.background().ok === true, 2000,
                  "toggle out of pause did not reopen the render gate");
        rig.destroy();
    }

    // Resuming from a user pause must not start drawing while another pause
    // source (here the screen locker) still holds the gate shut.
    function test_resumeKeepsGateShutWhileLockActive() {
        const rig = _rig();
        const ctrl = rig.playlistController();
        const lock = _findLockMonitor(rig);
        verify(lock !== null);
        ctrl.pause();
        lock.active = true;
        tryVerify(() => rig.background().ok === false, 2000);
        ctrl.resume();
        // Give any pending binding re-evaluation a chance to land before
        // asserting the gate stayed shut.
        wait(50);
        compare(rig.background().ok, false,
                "resume reopened the gate while the locker was still active");
        // Now the mirror case: user pause outlives the locker.
        ctrl.pause();
        lock.active = false;
        wait(50);
        compare(rig.background().ok, false,
                "gate reopened on unlock while the user pause still stood");
        ctrl.resume();
        tryVerify(() => rig.background().ok === true, 2000,
                  "gate did not reopen once both pause sources cleared");
        rig.destroy();
    }

    // The VT-switch / suspend monitor has to actually reach the renderer,
    // and coming back must re-consult the whole gate rather than blindly
    // resuming: a user pause outlives the switch.
    function test_vtSwitchPausesAndHonoursUserPause() {
        const rig = _rig();
        const ctrl = rig.playlistController();
        const loader = rig._find(rig.mainItem, o => typeof o.loadInfoShow === "function");
        verify(loader !== null);
        const tty = rig._find(rig.mainItem, o => typeof o.ttySwitch !== "undefined");
        verify(tty !== null);
        const fake = fakeBackendComp.createObject(tc);
        loader.item = fake;

        tty.ttySwitch(true);
        compare(fake.pauseCount, 1, "leaving for another VT did not pause the renderer");
        tty.ttySwitch(false);
        compare(fake.playCount, 1, "switching back did not resume the renderer");

        ctrl.pause();
        const playsBefore = fake.playCount;
        tty.ttySwitch(true);
        tty.ttySwitch(false);
        compare(fake.playCount, playsBefore,
                "switching back resumed the renderer through a user pause");

        loader.item = null;
        fake.destroy();
        rig.destroy();
    }

    // A user pause still stops playlist rotation, and a later desktop-state
    // change must not silently resume it while the user pause stands.
    function test_userPauseHoldsPlaylistRotation() {
        const rig = _rig();
        const ctrl = rig.playlistController();
        const mgr = ctrl.manager;
        const pausedAt = mgr.pauseTicksCount;
        ctrl.pause();
        verify(mgr.pauseTicksCount > pausedAt, "user pause did not stop rotation ticks");
        const resumedAt = mgr.resumeTicksCount;
        // Any desktop-side gate movement while user-paused must leave ticks stopped.
        ctrl.noRandomWhilePaused = true;
        ctrl.desktopOk = false;
        ctrl.desktopOk = true;
        compare(mgr.resumeTicksCount, resumedAt,
                "rotation restarted while the user pause was still in effect");
        rig.destroy();
    }
}
