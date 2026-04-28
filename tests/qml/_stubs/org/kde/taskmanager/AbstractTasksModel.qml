// AbstractTasksModel exposes role enum constants used as `data()` keys.
// In real Qt code these come from a C++ enum; we mirror the same integer
// IDs in our TasksModel stub. Wrapped as enum so QML's "no uppercase
// properties" rule doesn't reject these names.
pragma Singleton
import QtQuick
QtObject {
    enum Role {
        AppName                = 257,
        IsActive               = 258,
        IsMaximized            = 259,
        IsFullScreen           = 260,
        IsOnAllVirtualDesktops = 261,
        VirtualDesktops        = 262,
        Activities             = 263,
        ScreenGeometry         = 264,
        IsMinimized            = 265,
        SkipTaskbar            = 266,
        SkipPager              = 267,
        IsWindow               = 268
    }

    // Production code reads `TaskManager.AbstractTasksModel.AppName`.
    // Expose enum values as readonly properties — but with an explicit
    // alias so the lookup still works. (QML won't let property names
    // start uppercase, but enum values defined inside the type are
    // legitimately accessed via the type identifier.)
    readonly property int appName:                AbstractTasksModel.AppName
    readonly property int isActive:               AbstractTasksModel.IsActive
    readonly property int isMaximized:            AbstractTasksModel.IsMaximized
    readonly property int isFullScreen:           AbstractTasksModel.IsFullScreen
    readonly property int isOnAllVirtualDesktops: AbstractTasksModel.IsOnAllVirtualDesktops
    readonly property int virtualDesktops:        AbstractTasksModel.VirtualDesktops
    readonly property int activities:             AbstractTasksModel.Activities
    readonly property int screenGeometry:         AbstractTasksModel.ScreenGeometry
    readonly property int isMinimized:            AbstractTasksModel.IsMinimized
    readonly property int isWindow:               AbstractTasksModel.IsWindow
}
