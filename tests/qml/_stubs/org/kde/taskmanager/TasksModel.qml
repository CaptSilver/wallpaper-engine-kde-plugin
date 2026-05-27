// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: libtaskmanager (Plasma framework)
// Last contract review: 2026-05-27

// Stub for TaskManager.TasksModel — backs WindowModel.qml's window-aware
// pause logic. Production code calls makeModelIndex(i) + data(idx, role)
// in a loop; the stub returns a configurable canned dataset.
import QtQuick
QtObject {
    // Test fixtures: array of window dicts {appName, isActive, isMaximized,
    //   isFullScreen, isOnAllVirtualDesktops, virtualDesktops, activities, screenGeometry}
    property var _windows: []

    property int    count: _windows.length
    property bool   filterByScreen: false
    property bool   filterByActivity: false
    property string activity: ""
    property var    screenGeometry: ({ x: 0, y: 0, width: 1920, height: 1080 })
    property var    virtualDesktop: 0

    // Production code listens for these — we don't fire them automatically;
    // tests emit them via tasksModel.activeTaskChanged() when needed.
    signal activeTaskChanged()

    // Production code: `tasksModel.makeModelIndex(i)` returns an opaque
    // index that is then passed to `data()`. We return the integer index
    // since data() reads it directly below.
    function makeModelIndex(i) { return i; }

    // role enum mirrors AbstractTasksModel role IDs but content lookup is
    // by string key into the fixture dict.
    function data(idx, role) {
        const w = _windows[idx];
        if (!w) return undefined;
        switch (role) {
            case 257: return w.appName || "";              // AppName
            case 258: return !!w.isActive;                  // IsActive
            case 259: return !!w.isMaximized;               // IsMaximized
            case 260: return !!w.isFullScreen;              // IsFullScreen
            case 261: return !!w.isOnAllVirtualDesktops;    // IsOnAllVirtualDesktops
            case 262: return w.virtualDesktops || [];       // VirtualDesktops
            case 263: return w.activities || [];            // Activities
            case 264: return w.screenGeometry || screenGeometry;
            case 265: return !!w.isMinimized;               // IsMinimized
            case 266: return !!w.skipTaskbar;
            case 267: return !!w.skipPager;
            case 268: return !!w.isWindow;
        }
        return undefined;
    }

    // Sort/group enums referenced by production code (filter mode).
    enum SortOrder      { SortDisabled, SortVirtualDesktop, SortAlphabetical, SortLastActivated, SortActivity }
    enum GroupMode      { GroupDisabled, GroupApplications }

    property int sortMode:    TasksModel.SortDisabled
    property int groupMode:   TasksModel.GroupDisabled
    property bool filterByVirtualDesktop: false
}
