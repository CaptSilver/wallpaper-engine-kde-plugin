import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: tc
    name: "VideoListModel"
    width: 400; height: 300
    when: windowShown

    Item { id: host }

    // Fake pyext that returns a fixed list synchronously.
    QtObject {
        id: fakePyext
        function scan_video_folder(path) {
            return Promise.resolve([
                { path: path + "/a.mp4",  name: "a.mp4",  mtime: 100, size: 1024 },
                { path: path + "/b.webm", name: "b.webm", mtime: 200, size: 2048 },
            ]);
        }
        function generate_thumbnail(videoPath, outPath, atSeconds) {
            return Promise.resolve(outPath);
        }
    }

    Component {
        id: modelComp
        Plugin.VideoListModel {
            pyext: fakePyext
            cachePath: "/tmp/cache"
        }
    }

    function test_emptyFolderPath_modelIsEmpty() {
        const m = modelComp.createObject(host, { folderPath: "" });
        compare(m.model.count, 0);
        m.destroy();
    }

    function test_setFolderPath_populatesModel() {
        const m = modelComp.createObject(host, { folderPath: "/tmp/v" });
        return m.refresh().then(() => {
            compare(m.model.count, 2);
            const item0 = m.model.get(0);
            verify(item0.workshopid.indexOf("video:") === 0);
            compare(item0.type, "video");
            compare(item0.path, "/tmp/v");
            verify(item0.file === "a.mp4" || item0.file === "b.webm");
            m.destroy();
        });
    }

    function test_workshopId_isStableAcrossRefresh() {
        const m = modelComp.createObject(host, { folderPath: "/tmp/v" });
        return m.refresh().then(() => {
            const id1 = m.model.get(0).workshopid;
            return m.refresh().then(() => {
                compare(m.model.get(0).workshopid, id1);
                m.destroy();
            });
        });
    }

    function test_titleStripsExtension() {
        const m = modelComp.createObject(host, { folderPath: "/tmp/v" });
        return m.refresh().then(() => {
            verify(m.model.get(0).title === "a" || m.model.get(0).title === "b");
            m.destroy();
        });
    }

    function test_previewPathPointsAtCacheDir() {
        const m = modelComp.createObject(host, { folderPath: "/tmp/v" });
        return m.refresh().then(() => {
            const p = m.model.get(0).preview;
            verify(p.indexOf("/tmp/cache/video-thumbs/") === 0);
            verify(p.endsWith(".jpg"));
            m.destroy();
        });
    }
}
