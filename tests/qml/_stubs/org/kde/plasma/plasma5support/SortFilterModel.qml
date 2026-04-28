import QtQuick
QtObject {
    property var sourceModel: null
    property string filterRole: ""
    property string filterRegExp: ""
    property string sortRole: ""
    property int sortOrder: Qt.AscendingOrder
    property int count: 0
    signal dataChanged()  // production code uses `onDataChanged`
}
