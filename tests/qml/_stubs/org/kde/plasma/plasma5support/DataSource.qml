// Stub for Plasma5Support.DataSource. Production code reads `data[key][prop]`
// for things like Battery info; we expose an empty data map by default so
// safe-fallback bindings (`data['Battery'] || {}`) collapse to defaults.
import QtQuick
QtObject {
    property string engine: ""
    property var connectedSources: []
    property var sources: []
    property var data: ({})
    function connectSource(source)    {}
    function disconnectSource(source) {}
}
