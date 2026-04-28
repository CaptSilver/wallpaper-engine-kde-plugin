import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    name: "PowerSource"
    when: windowShown

    Plugin.PowerSource { id: ps }

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
}
