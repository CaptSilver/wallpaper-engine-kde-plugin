import QtQuick 2.5
import QtQuick.Controls 2.0
import QtQuick.Layouts 1.2
import QtQuick.Window 2.1
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support

import org.kde.taskmanager 0.1 as TaskManager

import "js/windowplay.mjs" as WindowPlay

/*
https://github.com/KDE/plasma-workspace/blob/master/libtaskmanager/abstracttasksmodel.h
    enum AdditionalRoles {
        AppId = Qt::UserRole + 1, //< KService storage id (.desktop name sans extension). 
        AppName, //< Application name. 
        GenericName, //< Generic application name. 
        LauncherUrl, //< URL that can be used to launch this application (.desktop or executable). 
        LauncherUrlWithoutIcon, //< Special path to get a launcher URL while skipping fallback icon encoding. Used as speed optimization. 
        WinIdList, //< NOTE: On Wayland, these ids are only useful within the same process. On X11, they are global window ids. 
        MimeType, //< MIME type for this task (window, window group), needed for DND. 
        MimeData, //< Data for MimeType. 
        IsWindow, //< This is a window task. 
        IsStartup, //< This is a startup task. 
        IsLauncher, //< This is a launcher task. 
        HasLauncher, //< A launcher exists for this task. Only implemented by TasksModel, not by either the single-type or munging tasks models. 
        IsGroupParent, //< This is a parent item for a group of child tasks. 
        ChildCount, //< The number of tasks in this group. 
        IsGroupable, //< Whether this task is being ignored by grouping or not. 
        IsActive, //< This is the currently active task. 
        IsClosable, //< requestClose (see below) available. 
        IsMovable, //< requestMove (see below) available. 
        IsResizable, //< requestResize (see below) available. 
        IsMaximizable, //< requestToggleMaximize (see below) available. 
        IsMaximized, //< Task (i.e. window) is maximized. 
        IsMinimizable, //< requestToggleMinimize (see below) available. 
        IsMinimized, //< Task (i.e. window) is minimized. 
        IsKeepAbove, //< Task (i.e. window) is keep-above. 
        IsKeepBelow, //< Task (i.e. window) is keep-below. 
        IsFullScreenable, //< requestToggleFullScreen (see below) available. 
        IsFullScreen, //< Task (i.e. window) is fullscreen. 
        IsShadeable, //< requestToggleShade (see below) available. 
        IsShaded, //< Task (i.e. window) is shaded. 
        IsVirtualDesktopsChangeable, //< requestVirtualDesktop (see below) available. 
        VirtualDesktops, //< Virtual desktops for the task (i.e. window). 
        IsOnAllVirtualDesktops, //< Task is on all virtual desktops. 
        Geometry, //< The task's geometry (i.e. the window's). 
        ScreenGeometry, //< Screen geometry for the task (i.e. the window's screen). 
        Activities, //< Activities for the task (i.e. window). 
        IsDemandingAttention, //< Task is demanding attention. 
        SkipTaskbar, //< Task should not be shown in a 'task bar' user interface. 
        SkipPager, //< Task should not to be shown in a 'pager' user interface. 
        AppPid, //< Application Process ID
        StackingOrder, //< A window task's index in the window stacking order. 
        LastActivated, //< The timestamp of the last time a task was the active task. 
        ApplicationMenuServiceName, //< The DBus service name for the application's menu. May be empty. @since 5.19 
        ApplicationMenuObjectPath, //< The DBus object path for the application's menu. May be empty. @since 5.19 
        IsHidden, //< Task (i.e window) is hidden on screen. A minimzed window is not necessarily hidden. 
    };
*/

Item {
    id: wModel
    property bool logging: false
    property var desktop: 0

    property string activity
    property var screenGeometry

    property alias filterByScreen: tasksModel.filterByScreen
    property alias resumeTime: playTimer.interval
    property int modePlay

    // ---
    readonly property bool reqPause: _reqPause
    property bool _reqPause: false

    Timer{
        id: playTimer
        running: false
        repeat: false
        onTriggered: {
            _reqPause = false;
        }
    }
    function play() {
        playTimer.stop();
        playTimer.start();
    }
    function pause() {
        playTimer.stop();
        _reqPause = true;
    }
    function playBy(value) {
        if(value) play();
        else pause();
    }

    TaskManager.ActivityInfo { 
        id: activityInfo 
        // An activity switch moves no TasksModel row and emits no model
        // signal (filterByActivity is off — see tasksModel below), so nothing
        // else notices it. Re-read both inputs of the pause decision and
        // re-run it here, or the wallpaper keeps deciding against the
        // activity that happened to be current when it loaded.
        onCurrentActivityChanged: {
            wModel.activity = this.currentActivity;
            wModel.desktop = virtualDesktopInfo.currentDesktop;
            updateWindowsinfo();
        }
        Component.onCompleted: {
            wModel.activity = this.currentActivity;
        }
    }

    TaskManager.VirtualDesktopInfo { 
        id: virtualDesktopInfo 
        onCurrentDesktopChanged: {
            wModel.desktop = this.currentDesktop;
        }
        Component.onCompleted: {
            wModel.desktop = this.currentDesktop;
        }
    }
    TaskManager.TasksModel {
        id: tasksModel
        sortMode: TaskManager.TasksModel.SortVirtualDesktop
        groupMode: TaskManager.TasksModel.GroupDisabled

        virtualDesktop: wModel.desktop
        filterByVirtualDesktop: true

        screenGeometry: wModel.screenGeometry

        // in alias
        // filterByScreen: true

        // demandingAttentionSkipsFilters not available here, which may cause, 
        // skip activity filter, so filter activties manually
        //demandingAttentionSkipsFilters: false
        //activity: wModel.activity
        //filterByActivity: true

        onActiveTaskChanged: updateWindowsinfo();
        onVirtualDesktopChanged: {
            if(wModel.logging)
                console.error(this.virtualDesktop, ':', this.screenGeometry)
            updateWindowsinfo();
        }
    }

    Plasma5Support.SortFilterModel {
        filterRole: 'IsWindow'
        filterRegExp: 'true'
        sourceModel: tasksModel
        onDataChanged: updateWindowsinfo()
        onCountChanged: updateWindowsinfo()
    }

    Timer{
        id: triggerTimer
        running: false
        repeat: false
        interval: 100
        onTriggered: {
            _updateWindowsinfo();
        }
    }

    function updateWindowsinfo() {
        triggerTimer.start();
    }
    function _updateWindowsinfo() {
        if(modePlay === Common.PauseMode.Never) {
            playBy(true);
            return;
        }

        // Single pass over the task model: read each row once, keep windows that
        // are real windows in the current activity, and build a plain descriptor
        // for the pure decision function. Replaces the previous six chained
        // filter() passes (each of which allocated an index array + a result
        // array) — the decision only ever needs a handful of counts.
        const windows = [];
        const n = tasksModel.count;
        for(let i = 0; i < n; i++) {
            const idx = tasksModel.makeModelIndex(i);
            if(tasksModel.data(idx, TaskManager.AbstractTasksModel.IsWindow) === false)
                continue;
            // Activity filter (done manually here because TasksModel.filterByActivity
            // is unavailable — see the comment on tasksModel above): keep a window
            // when it has no activity info, or one of its activities is the current.
            const activities = tasksModel.data(idx, TaskManager.AbstractTasksModel.Activities);
            if(activities && activities.length && activities.indexOf(wModel.activity) === -1)
                continue;
            windows.push({
                isMinimized:  tasksModel.data(idx, TaskManager.AbstractTasksModel.IsMinimized)  === true,
                isMaximized:  tasksModel.data(idx, TaskManager.AbstractTasksModel.IsMaximized)  === true,
                isFullScreen: tasksModel.data(idx, TaskManager.AbstractTasksModel.IsFullScreen) === true,
                isActive:     tasksModel.data(idx, TaskManager.AbstractTasksModel.IsActive)     === true,
            });
        }

        playBy(WindowPlay.shouldPlay(windows, modePlay));

        if(logging) {
            // Keep the diagnostic dump (gated on `logging`, off the hot path).
            const printW = (label, pred) => {
                console.error("--------" + label + "--------");
                windows.filter(pred).forEach((win) => console.error("--", win));
            };
            printW("Not Minimized", (win) => !win.isMinimized);
            printW("Maximized",     (win) => !win.isMinimized && (win.isMaximized || win.isFullScreen));
            printW("Active",        (win) => !win.isMinimized && win.isActive);
            console.error("\n\n\n");
        }
    }
}

