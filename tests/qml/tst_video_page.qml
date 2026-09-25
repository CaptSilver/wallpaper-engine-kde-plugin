import QtQuick
import QtTest

import "../../plugin/contents/ui/page" as Page

TestCase {
    id: tc
    name: "VideoPage"
    width: 1024; height: 768
    when: windowShown

    Item { id: host; anchors.fill: parent }

    QtObject {
        id: fakePyext
        function scan_video_folder(path) {
            return Promise.resolve([
                { path: path + "/a.mp4", name: "a.mp4", mtime: 100, size: 1024 },
            ]);
        }
        function generate_thumbnail(_, outPath) {
            return Promise.resolve(outPath);
        }
        // _kickThumbnails calls this for every scanned item once refresh()
        // resolves; missing it throws inside the .then chain and the scan
        // reports itself failed even though the list came back fine.
        function video_thumb_dir(cacheRoot) {
            return cacheRoot.replace(/\/+$/, "") + "/video-thumbs";
        }
    }

    Component {
        id: pageComp
        Page.VideoPage {
            anchors.fill: parent
            pyext: fakePyext
            cachePath: "/tmp/cache"
        }
    }

    function test_emptyFolderPath_showsEmptyState() {
        const p = pageComp.createObject(host, { cfg_VideoFolderPath: "" });
        verify(p);
        verify(p.emptyStateVisible);
        verify(! p.gridVisible);
        p.destroy();
    }

    function test_folderSet_showsGrid() {
        const p = pageComp.createObject(host, { cfg_VideoFolderPath: "/tmp/v" });
        return p.videoListModel.refresh().then(() => {
            verify(! p.emptyStateVisible);
            verify(p.gridVisible);
            compare(p.videoListModel.model.count, 1);
            p.destroy();
        });
    }

    // A folder already configured (the normal case: reopening the dialog
    // on a wallpaper someone already set up) must populate the grid on its
    // own -- the user shouldn't have to press Rescan just to see what's
    // already there.
    function test_folderAlreadyConfigured_populatesWithoutManualRescan() {
        const p = pageComp.createObject(host, { cfg_VideoFolderPath: "/tmp/v" });
        verify(p);
        tryCompare(p.videoListModel.model, "count", 1);
        p.destroy();
    }

    function test_clickEmitsCommitWallpaper() {
        const p = pageComp.createObject(host, { cfg_VideoFolderPath: "/tmp/v" });
        let captured = null;
        p.commitWallpaper.connect((item) => { captured = item; });
        return p.videoListModel.refresh().then(() => {
            const item = p.videoListModel.model.get(0);
            p._commitItem(item);
            verify(captured);
            verify(captured.workshopid.indexOf("video:") === 0);
            compare(captured.type, "video");
            p.destroy();
        });
    }
}
