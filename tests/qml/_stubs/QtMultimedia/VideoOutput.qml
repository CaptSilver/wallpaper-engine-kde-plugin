import QtQuick
Item {
    enum FillMode { Stretch, PreserveAspectFit, PreserveAspectCrop }
    property int fillMode: VideoOutput.PreserveAspectFit
}
