// The "Verbose logging" setting reaches the renderer's log switch through
// WekDiagnostics.setVerboseLogging(): once when main.qml loads, and again
// every time the setting changes.
import QtQuick
import QtTest
import Helpers 1.0

TestCase {
    id: tc
    name: "Main_VerboseLogging"
    when: windowShown
    width: 400; height: 300
    Component { id: rigComp; ScreenRig {} }

    function _rig(initial) {
        const rig = rigComp.createObject(tc, {
            screenGeometry: Qt.rect(0,0,1920,1080),
            initialConfig: initial || null });
        tryVerify(() => rig.background() !== null, 2000);
        tryVerify(() => rig.diagnostics() !== null, 2000);
        return rig;
    }

    function _last(diag) {
        const log = diag.verboseLoggingLog;
        return log.length ? log[log.length - 1] : undefined;
    }

    function test_settingOffAtLoad_appliesFalse() {
        const rig = _rig();
        const diag = rig.diagnostics();
        tryVerify(() => diag.verboseLoggingLog.length > 0, 2000);
        compare(_last(diag), false);
        rig.destroy();
    }

    function test_settingOnAtLoad_appliesTrue() {
        const rig = _rig({ VerboseLogging: true });
        const diag = rig.diagnostics();
        tryVerify(() => _last(diag) === true, 2000,
                  "VerboseLogging=true in the config never reached setVerboseLogging");
        rig.destroy();
    }

    function test_settingChanged_followsTheSwitchBothWays() {
        const rig = _rig();
        const diag = rig.diagnostics();
        rig.setConfig({ VerboseLogging: true });
        tryVerify(() => _last(diag) === true, 2000);
        rig.setConfig({ VerboseLogging: false });
        tryVerify(() => _last(diag) === false, 2000);
        rig.destroy();
    }
}
