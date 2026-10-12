// The wallpaper info pane — preview, per-wallpaper options and User
// Properties — has to be reachable at the width Plasma actually opens the
// wallpaper config dialog at. Plasma sizes that dialog from
// Kirigami.Units.gridUnit and never remembers a user resize, so a pane that
// only appears on a wide dialog is a pane most users never see.
import QtQuick
import QtTest
import org.kde.kirigami 2.6 as Kirigami
import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "WallpaperPageRightPane"
    width: 1024; height: 768
    when: windowShown

    Item { id: host; anchors.fill: parent }

    property var cfg: null
    property var page: null
    property var rc: null

    // Plasma's AppletConfiguration opens at gridUnit * 45 and spends a
    // fixed slice on the category sidebar; the wallpaper plugin is handed
    // what's left. Derived from gridUnit so the numbers track whatever font
    // metrics the run has, the same way Plasma's own sizing does.
    readonly property int plasmaDialogWidth: Kirigami.Units.gridUnit * 45
    readonly property int categorySidebarWidth: Kirigami.Units.gridUnit * 7
    readonly property int defaultPageWidth: plasmaDialogWidth - categorySidebarWidth

    function _findFirstByPredicate(root, predicate) {
        const seen = new Set();
        const queue = [root];
        seen.add(root);
        while (queue.length > 0) {
            const node = queue.shift();
            if (predicate(node)) return node;
            const buckets = [node.children || [], node.data || []];
            for (const b of buckets) {
                if (!b || typeof b.length === "undefined") continue;
                for (let i = 0; i < b.length; i++) {
                    const c = b[i];
                    if (c && !seen.has(c)) { seen.add(c); queue.push(c); }
                }
            }
        }
        return null;
    }

    function initTestCase() {
        // QtTest's TestCase ships `visible: false`, which drags every
        // descendant's effective visibility down with it and would make the
        // assertions below pass no matter what the page does.
        tc.visible = true;
        const comp = Qt.createComponent("../../plugin/contents/ui/config.qml");
        verify(comp.status !== Component.Error, comp.errorString());
        cfg = comp.createObject(host, {});
        verify(cfg);
        cfg.libcheck = { wallpaper: true, qtwebchannel: true };
        if (cfg.plugin_info) cfg.plugin_info.cache_path = "file:///tmp/cache";

        page = _findFirstByPredicate(cfg, n =>
            n && n.toString && n.toString().indexOf("WallpaperPage_QMLTYPE") === 0);
        verify(page, "WallpaperPage not found in config tree");

        rc = _findFirstByPredicate(page, n =>
            n && typeof n.wpmodel !== "undefined" && typeof n.image_size === "number");
        verify(rc, "right_content Control not found inside WallpaperPage");
    }

    // Drive the dialog width and let the layout settle before reading
    // geometry — QQuickLayouts resize on polish, not on assignment.
    function _sizeDialog(w) {
        cfg.width = w;
        cfg.height = 600;
        waitForRendering(host);
        tryVerify(() => Math.abs(page.width - w) <= 1, 2000,
                  "WallpaperPage never took the dialog width");
    }

    // The pane's preview is a PreviewAnimatedImage (decode-probed wrapper).
    function _findAnimatedPreview() {
        return _findFirstByPredicate(rc, n =>
            n && typeof n.sourceWidth === "number" && typeof n.firstFrameDecoded === "boolean");
    }

    function _findUserPropsGroup() {
        return _findFirstByPredicate(page, n =>
            n && typeof n.savePropChange === "function"
            && typeof n.getPropValue === "function");
    }

    function test_infoPaneIsPresentAtPlasmaDefaultDialogWidth() {
        _sizeDialog(defaultPageWidth);
        verify(rc.visible,
               "info pane hidden at the dialog width Plasma opens with (" +
               defaultPageWidth + "px page, pane " + rc.width + "px)");
        verify(rc.width > 0, "info pane collapsed to zero width");
    }

    function test_userPropertiesReachableAtPlasmaDefaultDialogWidth() {
        _sizeDialog(defaultPageWidth);
        const upg = _findUserPropsGroup();
        verify(upg !== null, "User Properties group not built");
        verify(upg.visible, "User Properties group not visible in the info pane");
    }

    // The preview is what made the pane too wide to fit. It has to scale
    // down with the pane instead of pushing past its right edge.
    function test_previewShrinksWithThePaneInsteadOfOverflowing() {
        _sizeDialog(defaultPageWidth);
        const img = _findAnimatedPreview();
        verify(img !== null, "detail-pane preview not found");
        // A hidden pane keeps whatever width it last laid out at, so the
        // overflow check below only means anything once the pane is up.
        verify(rc.visible, "info pane hidden, preview width says nothing");
        verify(img.width > 0, "preview collapsed to zero width");
        verify(img.width <= rc.width - rc.content_margin,
               "preview (" + img.width + "px) overflows the info pane (" +
               rc.width + "px)");
    }

    function _findEmptyPlaceholder() {
        return _findFirstByPredicate(page, n =>
            n && n.objectName === "userPropsEmptyPlaceholder");
    }

    // "This wallpaper has no adjustable properties" and "this plugin has no
    // such feature" have to look different. Dropping the header and the
    // Reset button along with the empty list makes them identical.
    function test_userPropertiesGroupStaysUpWithNothingToShow() {
        _sizeDialog(defaultPageWidth);
        const upg = _findUserPropsGroup();
        verify(upg !== null, "User Properties group not built");
        upg.userProperties = [];
        verify(upg.visible, "User Properties group disappears on an empty list");
        const ph = _findEmptyPlaceholder();
        verify(ph !== null, "nothing explains the empty list");
        verify(ph.visible, "the empty-list explanation is not shown");
    }

    function test_userPropertiesPlaceholderStepsAsideForRealProperties() {
        _sizeDialog(defaultPageWidth);
        const upg = _findUserPropsGroup();
        verify(upg !== null, "User Properties group not built");
        upg.userProperties = [{ key: "k", text: "K", type: "bool", value: true }];
        const ph = _findEmptyPlaceholder();
        verify(ph !== null, "nothing explains the empty list");
        verify(!ph.visible, "the empty-list explanation shows next to a property");
    }

    // A wide dialog must still give the preview its full natural size —
    // the clamp is a ceiling, not a resize.
    function test_previewKeepsItsNaturalSizeOnAWideDialog() {
        _sizeDialog(Kirigami.Units.gridUnit * 90);
        const img = _findAnimatedPreview();
        verify(img !== null, "detail-pane preview not found");
        compare(img.width, rc.image_size);
    }

    // Wallpaper Engine gates some properties on another property's live
    // value ("condition": "mediavisualizer.value == true"). Real-world
    // wallpapers rely on this to keep dozens of sub-options collapsed behind
    // one parent switch — without it every row shows flat, all the time.
    function test_conditionGatedRowHiddenUntilControllingPropertyIsTrue() {
        _sizeDialog(defaultPageWidth);
        const upg = _findUserPropsGroup();
        verify(upg !== null, "User Properties group not built");
        upg.propChanges = {};
        upg.propDefaults = { mediavisualizer: false };
        upg.userProperties = [
            { key: "mediavisualizer", text: "Media Visualizer", type: "bool", value: false },
            { key: "albumname", text: "Album Name", type: "bool", value: false,
              condition: "mediavisualizer.value == true" }
        ];

        const repeater = _findFirstByPredicate(page, n => n && n.objectName === "userPropsRepeater");
        verify(repeater !== null, "userPropsRepeater not found");
        tryVerify(() => repeater.count === 2, 2000, "repeater did not build both rows");

        const parentRow = repeater.itemAt(0);
        const gatedRow = repeater.itemAt(1);
        verify(parentRow !== null && gatedRow !== null, "row delegates not created");
        verify(parentRow.visible, "an unconditioned row must stay visible");
        tryVerify(() => !gatedRow.visible, 2000,
                  "gated row must be hidden while its condition is false");

        // Flip the controlling property the same way the switch's
        // onRes_valChanged -> savePropChange path does, without going
        // through the pyext disk write (workshopid is unset in this test).
        upg.propChanges = { mediavisualizer: true };
        tryVerify(() => gatedRow.visible, 2000,
                  "gated row must appear once its condition's controlling property flips true");

        upg.propChanges = {};
        upg.propDefaults = {};
    }

    // A condition our safe evaluator doesn't understand (no eval, so no
    // method calls, assignments, etc.) must fail open — the row stays
    // visible rather than silently disappearing on an unrelated wallpaper.
    function test_unparseableConditionFailsOpenRowStaysVisible() {
        _sizeDialog(defaultPageWidth);
        const upg = _findUserPropsGroup();
        verify(upg !== null, "User Properties group not built");
        upg.propChanges = {};
        upg.propDefaults = {};
        upg.userProperties = [
            { key: "weird", text: "Weird", type: "bool", value: false,
              condition: "ruleset.value.split('/')[0].includes('0')" }
        ];

        const repeater = _findFirstByPredicate(page, n => n && n.objectName === "userPropsRepeater");
        verify(repeater !== null, "userPropsRepeater not found");
        tryVerify(() => repeater.count === 1, 2000, "repeater did not build the row");
        const row = repeater.itemAt(0);
        verify(row !== null, "row delegate not created");
        verify(row.visible, "a condition outside our grammar must fail open, not hide the row");

        upg.userProperties = [];
    }

    function test_activePlaylistBannerShowsFilteredLibraryLabel() {
        page.cfg_ActivePlaylistId = Plugin.Common.filteredLibraryId;
        const banner = _findFirstByPredicate(page, n =>
            n && n.objectName === "activePlaylistBannerLabel");
        verify(banner !== null, "active-playlist banner label not found");
        verify(banner.text.indexOf("Filtered Library") >= 0,
               "banner must read 'Filtered Library is active', got: " + banner.text);
        page.cfg_ActivePlaylistId = "";
    }
}
