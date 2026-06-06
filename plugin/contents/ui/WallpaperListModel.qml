import QtQuick 2.5
import QtQuick.Controls 2.0
import QtQuick.Layouts 1.2

import "js/utils.mjs" as Utils

Item {
    id: root
    property var workshopDirs
    property var globalConfigPath
    property string filterStr: ""
    property int sortMode: Common.SortMode.Id
    property bool enabled: true

    // Steam Workshop manifest: workshopid -> timeupdated (qint64 unix
    // timestamp). Empty {} when Steam library isn't configured or the
    // appworkshop_431960.acf can't be parsed. Updated externally by the
    // wallpaper page on settings change / refresh.
    property var workshopManifest: ({})
    // Mirror of <id>.json's last_seen_version values; an item is "updated"
    // iff workshopManifest[id] > seenVersions[id]. seenVersions is also
    // refreshed externally — recordSeenVersion writes to disk only.
    property var seenVersions: ({})

    property var initItemOp: null
    property var _initItemOp: Boolean(initItemOp) ? initItemOp : function(){ }
    property var readfile: null 
    property var _readfile: Boolean(readfile) ? readfile : function(){ return Promise.reject("read file func not available"); }

    signal modelStartSync
    signal modelRefreshed

    readonly property ListModel model: ListModel {
        function assignModel(index, value) {
            Object.assign(this.get(index), value);
            const workshopid = this.get(index).workshopid;
            new Promise((resolve, reject) => {
                const model = folderWorker.model;
                for(let i=0;i<model.length;i++) {
                    if(model[i].workshopid === workshopid) {
                        Object.assign(model[i], value);
                        resolve();
                    }
                }
                reject();
            });
        }
    }

    property int countNoFilter: 0

    // True while refresh() is in flight. UI binds the Refresh button +
    // BusyIndicator to this so a cold-start scan of a large Steam library
    // gives feedback that something's happening — matches the parity
    // VideoListModel has with VideoPage Rescan.
    property bool scanning: false

    // Bumped after every refresh / filter pass so callers that look items up
    // through findItem/titleOf re-evaluate their bindings when the unfiltered
    // source repopulates. Without this, a delegate created before the model
    // finished loading keeps showing the workshopid forever.
    property int _sourceRev: 0

    property var playlists: {}
    property var folderModels: []

    // Look up an item by workshopid against the UNFILTERED source. The public
    // `model` ListModel only contains items that pass the active filter, so
    // callers that need to display or play wallpapers stored in a playlist
    // (which is independent of the wallpaper-tab filter chips) must go
    // through this helper — otherwise a filtered-out wallpaper looks like a
    // missing one.
    //
    // Uses folderWorker.byWorkshopId (a JS Map) for O(1) lookup; the previous
    // linear scan paid L (≈1000 wallpapers) × call-count per PlaylistsPage
    // delegate render. Map is kept in sync inside loadModel — that is the
    // ONLY mutation site; any future code that touches folderWorker.model
    // directly must update byWorkshopId too or findItem will go stale.
    function findItem(workshopid) {
        // Touch _sourceRev so bindings re-evaluate when the source reloads.
        void root._sourceRev;
        return folderWorker.byWorkshopId.get(workshopid) ?? null;
    }

    function titleOf(workshopid) {
        const item = findItem(workshopid);
        return (item && item.title) ? item.title : workshopid;
    }

    function loadItemFromJson(text, el) {
        const project = Utils.parseJson(text);
        if(project !== null) {
            if("title" in project)
                el.title = project.title;
            if("preview" in project && project.preview)
                el.preview = project.preview;
            if("file" in project)
                el.file = project.file;
            if("type" in project)
                el.type = project.type.toLowerCase();
            if("contentrating" in project)
                el.contentrating = project.contentrating;
            if("tags" in project) {
                el.tags = project.tags.map(el => Object({key: el}));
            }
        }
        // Compute the "updated since you last loaded it" badge state. Only
        // wallpapers the user has actually loaded before (a recorded
        // last_seen_version > 0) that the Steam manifest has since bumped get
        // the dot. A never-loaded wallpaper has no last_seen_version, so it
        // does NOT badge — otherwise every subscribed-but-never-opened
        // wallpaper (the bulk of a library) would light up. recordSeenVersion
        // on load is what later clears the dot.
        const ts = (workshopManifest && workshopManifest[el.workshopid]) || 0;
        const seen = (seenVersions && seenVersions[el.workshopid]) || 0;
        el.updated = Utils.badgeUpdated(ts, seen);
    }

    function loadPlaylists() {
        // reset playlists property
        root.playlists = {};
    
        return root._readfile(Common.urlNative(globalConfigPath)).then(value => {
            var jsonData = Utils.parseJson(value);
            if (jsonData === null) {
                console.warn("Failed to parse playlists config, skipping playlists");
                return Promise.resolve();
            }

            // refreshing entries in the filter model is not thread safe, so we need to lock it
            var filterModel = Common.filterModel;
            return filterModel.lock.lock().then(() => {
                // remove playlists from the filterModel
                var selectedPlaylists = new Set();
                for(var i =0; i < filterModel.count; i++) {
                    var el = filterModel.get(i);
                    if(el.type == "playlist") {
                        if(el.def) { selectedPlaylists.add(el.key); }
                        filterModel.remove(i);
                        i--;
                    }
                }

                const playlists = jsonData?.steamuser?.general?.playlists || [];
                playlists.forEach(function(el) {
                    // we're going to be using paths to match wallpapers to playlists, but the paths in the config will start with a Windows-style drive letter
                    // so we need to convert them to file:// URLs. In addition it appears that the paths are truncated to 110 chars elsewhere so we will do the same
                    // so that they can match later
                    root.playlists[el.name] = new Set(el.items.map(el => "file://" + el.substring(2).replace(/\/[^\/]*$/, "").substring(0,110))); 
                    // add the playlist to the filter model preserving it's previous selection status
                    filterModel.append({type: "playlist", key: el.name, text: el.name, def: selectedPlaylists.has(el.name) ? 1 : 0});                    
                });
            })
            .then(() => { filterModel.lock.release() })
            .catch(() => { filterModel.lock.release() });
        }).catch(reason => console.error("PlaylistLoadError " + reason.lineNumber + " -- " + reason.type + reason.message));
    }

    function genSortCmp(mode) {
        switch (mode) {
          case Common.SortMode.Modified:
            return function(a, b) {
                return -(a.modified - b.modified);
            }
          case Common.SortMode.Name:
            return function(a, b) {
                return a.title<b.title ? -1 : 1;
            }
          case Common.SortMode.Id:
          default:
            return function(a, b) {
                return a.workshopid<b.workshopid ? -1 : 1;
            };
        }
    }

    Item {
        id: folderWorker

        // array
        property var folderMapModel: new Map()
        property var model: []
        // workshopid -> item Map. Built/rebuilt inside loadModel alongside
        // `model`; lookups via findItem are O(1) instead of linear. Invariant:
        // byWorkshopId.size === model.length after every loadModel.
        property var byWorkshopId: new Map()

        function loadModel(path, data) {
            this.folderMapModel.set(path, data);
            this.model = [];
            this.byWorkshopId.clear();
            this.folderMapModel.forEach((value, key) => {
                value.forEach(el => {
                    this.model.push(el);
                    this.byWorkshopId.set(el.workshopid, el);
                });
            });
            return filterToList(root.model, root.filterStr, this.model);
        }
        function filterToList(listModel, filterStr, data) {
            const filterValues = Common.filterModel.getValueArray(filterStr);
            const filterstr = Common.filterModel.map((el, index) => {
                    return {
                        type: el.type,
                        key: el.key,
                        value: filterValues[index]
                    };
                });
            root.modelStartSync();
            return new Promise((resolve, reject) => {
                const filter = Common.filterModel.genFilter(filterstr);
                const model = listModel;

                // Build filtered+sorted JS array first, then issue ONE bulk
                // model.append(array).  ListModel.append accepts both a single
                // object and an array; the array form does one allocation and
                // emits a single rowsInserted(0, n-1) instead of N per-row
                // emissions — view invalidation cost drops from O(N) to O(1)
                // signal-dispatches per filter/sort.
                //
                // Filtering first (then sorting the smaller subset) is also
                // cheaper than the old sort-then-filter, and as a side-effect
                // leaves the source `data` array (folderWorker.model)
                // un-mutated — findItem/titleOf scan it in load order.
                const filtered = data.filter(filter);
                filtered.sort(genSortCmp(sortMode));

                model.clear();
                if (filtered.length > 0) {
                    model.append(filtered);
                }
                resolve();
            }).then(() => {
                root.countNoFilter = this.model.length;
                root.modelRefreshed();
            });
        }
    }

    function refresh() {
        if(!root.enabled) return Promise.resolve(null);
        const p_list = [];

        root.scanning = true;
        return loadPlaylists().then(() => {
            this.workshopDirs.forEach(el => {
                const dirs = (Array.isArray(el) ? el : [el]).map(Common.urlNative);
                p_list.push(pyext.get_folder_list(
                    dirs[0],
                    { only_dir: true, fallbacks: dirs.slice(1) }
                ).then(res => {
                    if(!res) console.error(`folder not found: ${dirs[0]}`);
                    return res;
                }).catch(reason => console.error(reason)));
            });
            return new Promise((resolve, reject) => {
                Promise.all(p_list).then(values => {
                    return this.loadFolderLists(values);
                }).then(() => {
                    root.scanning = false;
                    resolve();
                }).catch(reason => {
                    console.error(reason)
                    root.scanning = false;
                    resolve();
                });
            });
        });
    }

    function loadFolderLists(folders) {
        const proxyModel = []
        folders.forEach(folder => {
            if(!folder || !folder.items) return Promise.resolve();
            // seems qml's "for" is a function
            const folder_dir = folder.folder;
            folder.items.forEach(el => {
                const v = Object.assign({}, Common.wpitem_template);
                v.workshopid = el.name;
                // use qurl to convert to file://
                v.path = Qt.resolvedUrl(folder_dir + '/' + el.name).toString();
                v.modified = el.mtime;
                root._initItemOp(v);
                proxyModel.push(v);
            });
            //if(proxyModel) console.error(`show the first: ${proxyModel[0].path}`)
        });
        return new Promise((resolve, reject) => {
            const plist = []
            proxyModel.forEach((el) => {
                // as no allSettled, catch any error
                const p = root._readfile(Common.urlNative(Common.getWpModelProjectPath(el))).then(value => {                    
                        el.playlists = [];
                        root.loadItemFromJson(value, el);
                        Object.keys(root.playlists).forEach((key) => {
                            const value = root.playlists[key];
                            if(value.has(el.path)) {       
                                if(!el.playlists.includes(key))
                                    el.playlists.push(Object({key: key}));
                            }
                        });
                    }).catch(reason => console.error(reason));
                plist.push(p);
            });
            const path = this.folder;
            Promise.all(plist).then(value => {
                folderWorker.loadModel(path, proxyModel).then(() => resolve());
            }).catch(reason => {
                console.error(reason);
                resolve();
            });
        });

    }
    // Attach a QFileSystemWatcher to each top-level workshop directory so
    // that Steam-subscribe / unsubscribe events refresh the picker without
    // requiring a manual Refresh click. One watcher per library (not per
    // wallpaper subdir) keeps the inotify slot budget under any reasonable
    // /proc/sys/fs/inotify/max_user_watches ceiling.
    function _attachWatchers() {
        if (! Boolean(pyext) || typeof pyext.unwatch_all_wallpaper_dirs !== "function") return;
        pyext.unwatch_all_wallpaper_dirs();
        this.workshopDirs.forEach(el => {
            const dirs = (Array.isArray(el) ? el : [el]).map(Common.urlNative);
            // Only watch the primary resolved path; fallbacks are handled by
            // get_folder_list per the existing refresh() pattern.
            if (dirs.length > 0 && dirs[0] && dirs[0].length > 0) {
                pyext.watch_wallpaper_dir(dirs[0]);
            }
        });
    }

    onWorkshopDirsChanged: _attachWatchers()

    // Steam's atomic-download writes 2-3 directoryChanged events per subscribe
    // (creates dotfile, renames into place). 500 ms debounce coalesces.
    Connections {
        target: Boolean(pyext) ? pyext : null
        ignoreUnknownSignals: true
        function onWallpaperDirChanged(path) {
            _watchDebounceTimer.restart();
        }
    }
    Timer {
        id: _watchDebounceTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root.enabled) root.refresh();
        }
    }

    Component.onCompleted: {
        this.modelRefreshed.connect(function() { root._sourceRev = root._sourceRev + 1; });
        this.filterStrChanged.connect(function() {
            if(root.enabled) {
                return folderWorker.filterToList(root.model, root.filterStr, folderWorker.model)
            }
            return Promise.resolve();
        });
        this.sortModeChanged.connect(this.filterStrChanged);
        this.enabledChanged.connect(this.refresh.bind(this));

        const fc = this.readfile;
        this.readfileChanged.connect(function() {
            if(fc === root.readfile) return Promise.resolve();
            return root.refresh().then(() => { fc = root.readfile; });
        });
        // Attach watchers AFTER the initial refresh kicks off; a subdir added
        // mid-scan triggers the watcher which re-refreshes (debounced).
        const r = this.refresh();
        _attachWatchers();
        return r;
    }

    // scan once
    Timer {
        running: true
        interval: 10000
        repeat: false   //run once
        onTriggered: {
            if(wpListModel.model.count === 0)
                return wpListModel.refresh();  //refresh to scan
            return Promise.resolve();
        }
    }

}
