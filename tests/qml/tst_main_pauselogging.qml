// Every source that can hold the render gate shut (window model, screen
// lock, TTY/suspend, power, user pause) is supposed to leave a trace in
// the journal when it flips — QML's own console.log/warn/error never
// reaches journald in this environment (see main.qml's diagnostics wiring
// and src/WekDiagnostics.cpp's logPauseTransition), so main.qml routes
// each source's transition through diagnostics.logPauseTransition()
// instead. These tests pin that each source logs exactly once per real
// transition, naming itself and its own play/pause request.
import QtQuick
import QtTest
import Helpers 1.0

TestCase {
    id: tc
    name: "Main_PauseLogging"
    when: windowShown
    width: 400; height: 300
    Component { id: rigComp; ScreenRig {} }

    function _findLockMonitor(rig) {
        return rig._find(rig.mainItem,
            o => typeof o.active !== "undefined"
              && typeof o.screenSaverActiveChanged !== "undefined");
    }

    function _rig() {
        const rig = rigComp.createObject(tc, { screenGeometry: Qt.rect(0,0,1920,1080) });
        tryVerify(() => rig.background() !== null, 2000);
        tryVerify(() => rig.diagnostics() !== null, 2000);
        return rig;
    }

    function _lastFor(diag, source) {
        const log = diag.pauseTransitionLog;
        for (let i = log.length - 1; i >= 0; i--)
            if (log[i].source === source) return log[i];
        return null;
    }

    function test_windowModelReqPauseChange_logsSourceAndDecision() {
        const rig = _rig();
        const diag = rig.diagnostics();
        const wm = rig.windowModel();
        verify(wm !== null);
        const before = diag.pauseTransitionLog.length;

        wm._reqPause = true;
        tryVerify(() => diag.pauseTransitionLog.length > before, 2000);
        let entry = _lastFor(diag, "windowModel");
        verify(entry !== null);
        compare(entry.playing, false, "windowModel requesting pause must log playing=false");

        wm._reqPause = false;
        tryVerify(() => _lastFor(diag, "windowModel").playing === true, 2000,
                  "windowModel clearing its pause request did not log playing=true");
        rig.destroy();
    }

    function test_lockMonitorActiveChange_logsSourceAndDecision() {
        const rig = _rig();
        const diag = rig.diagnostics();
        const lock = _findLockMonitor(rig);
        verify(lock !== null);

        lock.active = true;
        tryVerify(() => _lastFor(diag, "screensaver") !== null, 2000);
        compare(_lastFor(diag, "screensaver").playing, false);

        lock.active = false;
        tryVerify(() => _lastFor(diag, "screensaver").playing === true, 2000);
        rig.destroy();
    }

    function test_ttySwitch_logsSourceAndDecision() {
        const rig = _rig();
        const diag = rig.diagnostics();
        const tty = rig._find(rig.mainItem, o => typeof o.ttySwitch !== "undefined");
        verify(tty !== null);

        tty.ttySwitch(true); // leaving for another VT
        tryVerify(() => _lastFor(diag, "tty") !== null, 2000);
        compare(_lastFor(diag, "tty").playing, false);

        tty.ttySwitch(false); // back
        tryVerify(() => _lastFor(diag, "tty").playing === true, 2000);
        rig.destroy();
    }

    function test_userPauseChange_logsSourceAndDecision() {
        const rig = _rig();
        const diag = rig.diagnostics();
        const ctrl = rig.playlistController();
        verify(ctrl !== null);

        ctrl.pause();
        tryVerify(() => _lastFor(diag, "userPause") !== null, 2000);
        compare(_lastFor(diag, "userPause").playing, false);

        ctrl.resume();
        tryVerify(() => _lastFor(diag, "userPause").playing === true, 2000);
        rig.destroy();
    }

    // The one non-boolean-flip case: a value change that leaves reqPause's
    // *boolean outcome* unchanged must not log again — main.qml relies on
    // QML's own dependency tracking (onReqPauseChanged only fires on a real
    // value change) rather than any dedupe of its own, and this pins that
    // contract holds for the case most likely to regress it.
    function test_windowModelReqPauseUnchanged_doesNotLogAgain() {
        const rig = _rig();
        const diag = rig.diagnostics();
        const wm = rig.windowModel();
        wm._reqPause = true;
        tryVerify(() => _lastFor(diag, "windowModel") !== null, 2000);
        const countAfterFirst = diag.pauseTransitionLog.length;
        wm._reqPause = true; // same value again
        wait(50);
        compare(diag.pauseTransitionLog.length, countAfterFirst,
                "re-asserting the same reqPause value logged a spurious transition");
        rig.destroy();
    }
}
