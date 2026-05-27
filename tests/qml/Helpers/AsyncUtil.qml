// AsyncUtil.qml — shared microtask + binding-settle helpers for QML tests.
//
// Why this exists: open-coded `wait(0)` pumps accumulated across two test
// files (7 sites) before this helper landed.  Each call site was empirically
// tuned ("I added more pumps until the test went green") which makes the
// suite brittle to Qt's microtask-scheduling internals.  This helper
// centralises the pump count, so a future Qt-uplift requires editing ONE
// place, not seven.
//
// pumpMicrotasks(testCase, n=3): N back-to-back testCase.wait(0) calls.
//   3 covers most binding-settle chains (signal -> property write ->
//   derived binding -> C++ side-effect).  Use n=1 only when you specifically
//   want to assert "settled in one microtask".
//
// awaitBinding(testCase, item, prop, value, timeout=2000): wrapper over
//   testCase.tryCompare.  Same poll behaviour as Qt's tryCompare (actual
//   interval is Qt-internal); the wrapper name communicates "I expect this
//   binding to settle quickly."
import QtQuick
import QtTest

QtObject {
    function pumpMicrotasks(testCase, n) {
        if (n === undefined) n = 3;
        for (var i = 0; i < n; ++i) testCase.wait(0);
    }

    function awaitBinding(testCase, item, prop, value, timeout) {
        if (timeout === undefined) timeout = 2000;
        testCase.tryCompare(item, prop, value, timeout);
    }
}
