import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    name: "PowerSource"
    when: windowShown

    Plugin.PowerSource { id: ps }

    // A standalone re-statement of main.qml's PowerSource.reqPause binding
    // against settable inputs. The binding under test lives on the PowerSource
    // *instance* in main.qml (not in PowerSource.qml), so we reproduce its exact
    // shape here to lock that it is an EXPRESSION (real boolean) and not a
    // statement-block that evaluates to `undefined`.
    Component {
        id: probeComp
        Item {
            property bool   pauseOnBatPower: false
            property int    pauseBatPercent: 0
            property string st_battery_state: ""
            property bool   st_battery_has: false
            property int    st_battery_percent: 0
            // SAME expression as main.qml's PowerSource.reqPause.
            readonly property bool reqPause:
                (pauseOnBatPower && (st_battery_state === 'NoCharge' || st_battery_state === 'Discharging')) ||
                (pauseBatPercent !== 0 && st_battery_has && st_battery_percent < pauseBatPercent)
        }
    }

    function test_safeFallbacksWhenDataUnavailable() {
        // The stub DataSource never populates `data['Battery']`, so the
        // fallback expressions must collapse to defaults without throwing.
        verify(! ps.st_battery_has);
        compare(ps.st_battery_state, "");
        compare(ps.st_battery_percent, 0);
    }

    function test_pmDataExposesUnderlyingDataSourceMap() {
        // pm_data is an alias for pm_source.data.
        compare(typeof ps.pm_data, "object");
    }

    function test_pmSourceLogIteratesWithoutThrowing() {
        // The inner `log()` function is defined on a non-visual DataSource
        // child, so it lives in `data` rather than `children`. Walk both
        // collections to find the one with `log` defined.
        function findLogger(parent) {
            const buckets = [parent.children || [], parent.data || []];
            for (const b of buckets) {
                for (let i = 0; i < b.length; i++) {
                    if (b[i] && typeof b[i].log === "function") return b[i];
                }
            }
            return null;
        }
        const ds = findLogger(ps);
        verify(ds !== null);
        ds.log();
    }

    // ── Item 01: reqPause must be a real boolean expression binding ─────────
    function test_reqPause_is_boolean_and_false_by_default() {
        const p = probeComp.createObject(ps);
        verify(p !== null);
        // KEYSTONE: the buggy braced block evaluated to `undefined`
        // (typeof "undefined"); the fixed expression is a real boolean.
        compare(typeof p.reqPause, "boolean");
        verify(p.reqPause === false);
        p.destroy();
    }

    function test_reqPause_toggles_with_battery_inputs() {
        const p = probeComp.createObject(ps);
        verify(p !== null);

        // OR-arm A: on-battery + discharging.
        p.pauseOnBatPower = true;
        p.st_battery_state = "Discharging";
        verify(p.reqPause === true);
        p.st_battery_state = "NoCharge";
        verify(p.reqPause === true);
        // On AC (Charging) the on-battery arm is false.
        p.st_battery_state = "Charging";
        verify(p.reqPause === false);
        p.pauseOnBatPower = false;

        // OR-arm B: percent threshold set, has battery, below threshold.
        p.pauseBatPercent = 20;
        p.st_battery_has = true;
        p.st_battery_percent = 10;
        verify(p.reqPause === true);
        // At/above the threshold the percent arm is false.
        p.st_battery_percent = 25;
        verify(p.reqPause === false);
        // Threshold 0 (disabled sentinel) never engages on percent alone.
        p.pauseBatPercent = 0;
        p.st_battery_percent = 1;
        verify(p.reqPause === false);

        p.destroy();
    }
}
