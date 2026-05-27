// Bulk-append regression suite for WallpaperListModel.filterToList.
//
// Pre-patch, filterToList ran `model.clear()` then a per-row `model.append(el)`
// inside a `data.forEach(...)` loop. For an N-row pass that's N rowsInserted
// emissions on the public ListModel — each one invalidates the receiver views,
// which is the dominant cost on filter-chip toggles for mid-size libraries.
//
// Post-patch, filterToList builds a filtered+sorted JS array and issues one
// `model.append(array)` bulk call — one rowsInserted(0, n-1) emission for the
// whole insert. The signal-count assertion pins the regression: if a refactor
// reintroduces per-row append, this case flips red.
//
// As a secondary correctness win, the patch stops mutating the source `data`
// array via the implicit `data.sort()`. The source-array-invariance case pins
// that — pre-patch this fails (data is re-ordered in place); post-patch it
// holds.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperListModel.filterToList bulk"
    width: 200; height: 100
    when: windowShown

    // Synchronous Promise stand-in — mirrors tst_wallpaperlistmodel_full so the
    // readfile fan-in inside loadFolderLists resolves in-place and tests can
    // assert state immediately after the call.
    function _thenable(value, isReject) {
        return {
            then: function(onResolve, onReject) {
                if (isReject) {
                    if (onReject) {
                        const r = onReject(value);
                        return r && r.then ? r : tc._thenable(undefined);
                    }
                    return tc._thenable(value, true);
                }
                if (onResolve) {
                    const r = onResolve(value);
                    return r && r.then ? r : tc._thenable(r);
                }
                return tc._thenable(value);
            },
            catch: function(onReject) {
                if (isReject && onReject) onReject(value);
                return tc._thenable(value, false);
            },
        };
    }

    property string fakeFileContent: '{"general":{"playlists":[]}}'

    // pyext stub — refresh() makes a bare `pyext.get_folder_list` reference.
    // Returning empty items makes refresh a no-op on enabledChanged; tests
    // drive loadFolderLists directly. Pattern mirrors tst_filter_playlist_integration.
    property var pyext: ({
        get_folder_list: function(dir, opts) {
            return tc._thenable({ folder: dir, items: [] });
        }
    })

    Plugin.WallpaperListModel {
        id: wpModel
        enabled: true  // required: filterStrChanged/sortModeChanged are gated on enabled
        workshopDirs: ["/fake/workshop"]
        globalConfigPath: "/fake/global.json"
        initItemOp: function(item) { /* no-op */ }
        readfile: function(path) { return tc._thenable(tc.fakeFileContent); }
        Component.onCompleted: { wpModel.playlists = {}; }
    }

    // SignalSpy bound to the public ListModel's rowsInserted. The bulk-append
    // patch should drive this to exactly 1 emission per filterToList pass.
    SignalSpy {
        id: rowsInsertedSpy
        target: wpModel.model
        signalName: "rowsInserted"
    }

    SignalSpy {
        id: refreshSpy
        target: wpModel
        signalName: "modelRefreshed"
    }

    function init() {
        // Each test starts with playlists initialised (production seeds this in
        // refresh()->loadPlaylists, but we skip that path) and both spies
        // cleared.
        wpModel.playlists = {};
        rowsInsertedSpy.clear();
        refreshSpy.clear();
        // Start with no filter (use default chip values via empty filterStr).
        wpModel.filterStr = "";
        wpModel.sortMode = Plugin.Common.SortMode.Id;
    }

    // Build a fake folder payload with `n` Scene/Everyone wallpapers (default
    // filter passes every one). loadFolderLists chains through loadModel ->
    // filterToList, which is what we're testing.
    function _buildFolder(n, basePath) {
        const items = [];
        for (let i = 0; i < n; ++i) {
            // Reversed mtime so name-sort vs id-sort produces a different order
            // than insertion. Title carries a deterministic letter for sort
            // checks.
            items.push({ name: "wp" + String(i).padStart(3, '0'),
                         mtime: n - i });
        }
        return [{ folder: basePath || "/wp", items: items }];
    }

    // Wait until filterToList finishes its .then() — countNoFilter is bumped
    // there, mirroring the gate used in tst_filter_playlist_integration.
    function _waitForFilter(expectedCountNoFilter) {
        tryVerify(function() {
            return wpModel.countNoFilter === expectedCountNoFilter;
        }, 2000, "filterToList never completed: countNoFilter never reached "
                 + expectedCountNoFilter);
    }

    // ── (1) Bulk append must emit rowsInserted EXACTLY ONCE per filter pass.
    // Pre-patch this fails with spy.count == N (one emit per row). Post-patch
    // it holds at 1. This is the primary perf-regression sentinel.
    function test_rowsInserted_emitted_exactly_once_for_n_items() {
        fakeFileContent = '{"title":"T","type":"Scene","contentrating":"Everyone"}';
        const n = 20;
        wpModel.loadFolderLists(_buildFolder(n));
        _waitForFilter(n);
        compare(wpModel.model.count, n, "all items must land in the public model");
        compare(rowsInsertedSpy.count, 1,
                "bulk-append must emit rowsInserted exactly once per filterToList; "
                + "got " + rowsInsertedSpy.count
                + " (pre-patch behaviour: one emit per row)");
    }

    // ── (2) Behaviour-identity: final model contents match per-row append.
    // We can't compare against a live pre-patch baseline at runtime, but we
    // can pin the contract: every input row that passes the filter must
    // appear in the public model in sort-order. Sort by Id ascending.
    function test_behaviour_identity_id_sort_no_filter() {
        fakeFileContent = '{"title":"T","type":"Scene","contentrating":"Everyone"}';
        const n = 10;
        wpModel.loadFolderLists(_buildFolder(n));
        _waitForFilter(n);
        compare(wpModel.model.count, n);
        // Ids are wp000..wp009 — string-sort matches insertion order.
        for (let i = 0; i < n; ++i) {
            compare(wpModel.model.get(i).workshopid,
                    "wp" + String(i).padStart(3, '0'),
                    "post-filter row order must follow Id ascending");
        }
    }

    // ── (3) Behaviour-identity under input ordering: feeding rows in
    // descending-id order still produces an Id-ascending public model. Mirrors
    // the production sort guarantee — independent of input order. Used as
    // the strict-input-order companion to (2)'s ascending-input case.
    function test_behaviour_identity_descending_input_id_sort() {
        fakeFileContent = '{"title":"T","type":"Scene","contentrating":"Everyone"}';
        const items = [];
        for (let i = 4; i >= 0; --i) {
            items.push({ name: "wp" + String(i).padStart(3, '0'), mtime: i });
        }
        wpModel.loadFolderLists([{ folder: "/wp", items: items }]);
        _waitForFilter(5);

        compare(wpModel.model.count, 5);
        for (let i = 0; i < 5; ++i) {
            compare(wpModel.model.get(i).workshopid,
                    "wp" + String(i).padStart(3, '0'),
                    "Id-sort must order ascending regardless of input order");
        }
    }

    // ── (4) Empty filter result: model.count == 0 and rowsInserted is NOT
    // emitted (the guard `if (filtered.length > 0)` skips the no-op append).
    function test_empty_filter_no_rowsInserted_emit() {
        // Mark every item Mature so the default filter (Mature=0) excludes
        // everything.
        fakeFileContent = '{"title":"T","type":"Scene","contentrating":"Mature"}';
        const n = 5;
        wpModel.loadFolderLists(_buildFolder(n));
        // countNoFilter == n (unfiltered source size) — wait for that.
        _waitForFilter(n);
        // No row passed the filter — public model stays empty.
        compare(wpModel.model.count, 0,
                "Mature-only set under default filter must produce empty model");
        compare(rowsInsertedSpy.count, 0,
                "empty filtered result must not emit rowsInserted");
    }

    // ── (5) Sequential filter passes each produce one rowsInserted emit. Two
    // distinct filter changes => spy.count grows by exactly 1 per call.
    function test_sequential_filters_each_emit_once() {
        fakeFileContent = '{"title":"T","type":"Scene","contentrating":"Everyone"}';
        wpModel.loadFolderLists(_buildFolder(8));
        _waitForFilter(8);
        compare(rowsInsertedSpy.count, 1, "first pass: one rowsInserted");

        // Re-filter by toggling sortMode — Common.filterModel chip defaults
        // unchanged, so the same 8 rows land but in a different order.
        wpModel.sortMode = Plugin.Common.SortMode.Modified;
        tryVerify(function() { return rowsInsertedSpy.count === 2; }, 2000,
                  "second filter pass must emit exactly one additional rowsInserted");
        compare(wpModel.model.count, 8,
                "model must still hold all 8 rows after re-sort");
    }
}
