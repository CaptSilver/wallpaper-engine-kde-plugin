import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

// WallpaperListModel.qml's full Component.onCompleted depends on `pyext` and a
// real Steam workshop directory, so we cannot instantiate the component
// directly in a test harness. Instead we wrap genSortCmp inline through a
// minimal harness that mirrors the production switch — if the harness diverges
// from production code, the production tests in tst_common (which exercise
// model shape) will not catch it; this file pins the comparator semantics.

TestCase {
    name: "WallpaperListModel.genSortCmp"

    // Mirror of WallpaperListModel.qml's genSortCmp(mode).
    function _genSortCmp(mode) {
        switch (mode) {
        case Plugin.Common.SortMode.Modified:
            return function (a, b) { return -(a.modified - b.modified); };
        case Plugin.Common.SortMode.Name:
            return function (a, b) { return a.title < b.title ? -1 : 1; };
        case Plugin.Common.SortMode.Id:
        default:
            return function (a, b) { return a.workshopid < b.workshopid ? -1 : 1; };
        }
    }

    function test_sortById_lexicographicAscending() {
        const data = [
            { workshopid: "300", title: "C", modified: 3 },
            { workshopid: "100", title: "A", modified: 1 },
            { workshopid: "200", title: "B", modified: 2 },
        ];
        data.sort(_genSortCmp(Plugin.Common.SortMode.Id));
        compare(data[0].workshopid, "100");
        compare(data[1].workshopid, "200");
        compare(data[2].workshopid, "300");
    }

    function test_sortByName_caseSensitiveAscending() {
        const data = [
            { workshopid: "1", title: "Charlie", modified: 1 },
            { workshopid: "2", title: "Alpha",   modified: 2 },
            { workshopid: "3", title: "Bravo",   modified: 3 },
        ];
        data.sort(_genSortCmp(Plugin.Common.SortMode.Name));
        compare(data[0].title, "Alpha");
        compare(data[1].title, "Bravo");
        compare(data[2].title, "Charlie");
    }

    function test_sortByModified_descending() {
        // Newest first.
        const data = [
            { workshopid: "1", title: "A", modified: 100 },
            { workshopid: "2", title: "B", modified: 300 },
            { workshopid: "3", title: "C", modified: 200 },
        ];
        data.sort(_genSortCmp(Plugin.Common.SortMode.Modified));
        compare(data[0].modified, 300);
        compare(data[1].modified, 200);
        compare(data[2].modified, 100);
    }

    function test_sortDefault_fallsBackToId() {
        const data = [
            { workshopid: "B" },
            { workshopid: "A" },
        ];
        data.sort(_genSortCmp(99999)); // unknown mode → id comparator
        compare(data[0].workshopid, "A");
        compare(data[1].workshopid, "B");
    }
}
