// Test stub for the C++ FileHelper QML type. Methods return canned values
// or empty objects so production code can run through happy paths in tests.
import QtQuick
QtObject {
    property var _readReturns: ""
    property var _patchedHtmlReturns: ""

    function readFile(path)              { return _readReturns; }
    function patchedHtml(path)           { return _patchedHtmlReturns; }
    function qwebChannelSource()         { return ""; }
    function getDirSize(path, depth)     { return 0; }
    function getFolderList(path, opt)    { return []; }
    function readWallpaperConfig(id)     { return ({}); }
    function writeWallpaperConfig(id, c) { return; }
    function resetWallpaperConfig(id)    { return; }
    function readActiveBindings(id)      { return ({}); }
}
