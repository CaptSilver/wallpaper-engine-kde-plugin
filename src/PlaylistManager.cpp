#include "PlaylistManager.hpp"
#include "PlaylistsModel.hpp"
#include "PlaylistItemsModel.hpp"

#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUuid>
#include <QDateTime>
#include <QLoggingCategory>
#include <QRandomGenerator>
#include <QFileSystemWatcher>
#include <QSet>
#include <algorithm>

#include "FileHelper.hpp"

Q_LOGGING_CATEGORY(lcPlaylist, "wekde.playlist")

namespace wekde
{

PlaylistManager::PlaylistManager(QObject* parent)
    : QObject(parent), m_listModel(new PlaylistsModel(this)) {
    m_timer.setSingleShot(true);
    QObject::connect(&m_timer, &QTimer::timeout, this, &PlaylistManager::onTimerTick);
    // UI4.1: 250ms debounce around persist(). Interval picked as the spec
    // default — short enough that the post-drag write feels instantaneous to
    // the user, long enough that a 50-step drag-reorder (30-100ms between
    // moveItem calls) collapses to one write rather than 50. Profile-aware
    // tuning remains an open question (see specs/UI4 Phase 3.1).
    m_persistDebounceTimer.setSingleShot(true);
    m_persistDebounceTimer.setInterval(250);
    QObject::connect(
        &m_persistDebounceTimer, &QTimer::timeout, this, &PlaylistManager::flushPersist);

    // playlists.json is one file shared by every manager on the box: both
    // config dialogs (one per screen, per activity, plus the lock-screen
    // appearance page) and every runtime instance. Watching it is what makes
    // them converge — the PlaylistsReloadSeq counter the dialog bumps lives in
    // the *wallpaper* config, so it is per-containment and never reaches
    // another screen's runtime manager.
    m_watcher = new QFileSystemWatcher(this);
    QObject::connect(
        m_watcher, &QFileSystemWatcher::fileChanged, this, &PlaylistManager::onWatchedPathChanged);
    QObject::connect(m_watcher,
                     &QFileSystemWatcher::directoryChanged,
                     this,
                     &PlaylistManager::onWatchedPathChanged);
    load();
    rearmFileWatch();
}

// UI4.1: dtor flushes any pending debounced write so a mutation made within
// 250ms of destruction (e.g. a shutdown right after the user edits a playlist)
// is not lost.
PlaylistManager::~PlaylistManager() { flushPersist(); }

QString PlaylistManager::configFilePath() const {
    const QString cfg = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    return cfg + "/wekde/playlists.json";
}

PlaylistManager::DiskRead PlaylistManager::readFromDisk() const {
    DiskRead      out;
    const QString path = configFilePath();
    QFile         f(path);
    if (! f.exists()) {
        out.status = DiskStatus::Missing;
        return out;
    }
    if (! f.open(QIODevice::ReadOnly)) {
        out.status = DiskStatus::Unreadable;
        return out;
    }
    out.raw = f.readAll();
    f.close();

    QJsonParseError err {};
    const auto      doc = QJsonDocument::fromJson(out.raw, &err);
    if (err.error != QJsonParseError::NoError || ! doc.isObject()) {
        out.status = DiskStatus::Corrupt;
        out.error  = err.errorString();
        return out;
    }
    const auto obj = doc.object();
    out.version    = obj.value("version").toInt(1);
    if (out.version > 1) {
        out.status = DiskStatus::TooNew;
        return out;
    }
    const auto arr = obj.value("playlists").toArray();
    out.playlists.reserve(arr.size());
    for (const auto& v : arr) out.playlists.append(playlistFromJson(v.toObject()));
    out.status = DiskStatus::Ok;
    return out;
}

void PlaylistManager::captureDiskState(const QVector<Playlist>& pls, const QByteArray& raw) {
    m_diskBaseline.clear();
    m_diskBaseline.reserve(pls.size());
    m_diskBaselineOrder.clear();
    m_diskBaselineOrder.reserve(pls.size());
    for (const auto& pl : pls) {
        m_diskBaseline.insert(pl.id, playlistToJson(pl));
        m_diskBaselineOrder.append(pl.id);
    }
    m_diskRaw = raw;
}

bool PlaylistManager::inSyncWithDiskState() const {
    if (m_playlists.size() != m_diskBaselineOrder.size()) return false;
    for (int i = 0; i < m_playlists.size(); ++i) {
        if (m_playlists[i].id != m_diskBaselineOrder[i]) return false;
        if (playlistToJson(m_playlists[i]) != m_diskBaseline.value(m_playlists[i].id)) return false;
    }
    return true;
}

QVector<Playlist> PlaylistManager::mergeWithDisk(const QVector<Playlist>& theirs) const {
    // We have nothing of our own to protect, so take their file verbatim —
    // that also keeps a reorder they made, which the per-id walk below would
    // flatten back to our order.
    if (inSyncWithDiskState()) return theirs;

    QHash<QString, const Playlist*> theirById;
    theirById.reserve(theirs.size());
    for (const auto& pl : theirs) theirById.insert(pl.id, &pl);

    QVector<Playlist> merged;
    merged.reserve(std::max(m_playlists.size(), theirs.size()));
    QSet<QString> seen;

    for (const auto& ours : m_playlists) {
        seen.insert(ours.id);
        const auto baseIt    = m_diskBaseline.constFind(ours.id);
        const bool inBase    = baseIt != m_diskBaseline.constEnd();
        const bool weChanged = ! inBase || *baseIt != playlistToJson(ours);
        const auto theirIt   = theirById.constFind(ours.id);
        if (theirIt == theirById.constEnd()) {
            // Gone from the file. Honour their delete only if we have no edit
            // of our own that it would take down with it.
            if (inBase && ! weChanged) continue;
            merged.append(ours);
            continue;
        }
        merged.append(weChanged ? ours : **theirIt);
    }
    for (const auto& their : theirs) {
        if (seen.contains(their.id)) continue;
        const auto baseIt = m_diskBaseline.constFind(their.id);
        if (baseIt == m_diskBaseline.constEnd()) {
            merged.append(their); // they created it after our snapshot
            continue;
        }
        // We deleted it; keep the delete unless they edited it meanwhile, in
        // which case their edit outranks it (mirrors the branch above).
        if (*baseIt != playlistToJson(their)) merged.append(their);
    }
    return merged;
}

void PlaylistManager::load() { loadFrom(readFromDisk()); }

void PlaylistManager::loadFrom(const DiskRead& disk) {
    const QString path = configFilePath();
    switch (disk.status) {
    case DiskStatus::Missing:
        QDir().mkpath(QFileInfo(path).absolutePath());
        m_playlists.clear();
        captureDiskState({}, QByteArray());
        rebuildIndex();
        persist(); // write fresh empty file (also satisfies migration trigger)
        return;
    case DiskStatus::Unreadable: qCWarning(lcPlaylist) << "cannot read" << path; return;
    case DiskStatus::Corrupt: {
        qCWarning(lcPlaylist) << "corrupt playlists.json:" << disk.error;
        const QString aside =
            path + ".corrupt-" + QString::number(QDateTime::currentSecsSinceEpoch());
        QFile::rename(path, aside);
        m_playlists.clear();
        captureDiskState({}, QByteArray());
        rebuildIndex();
        persist(); // write fresh defaults
        return;
    }
    case DiskStatus::TooNew:
        qCWarning(lcPlaylist) << "playlists.json version" << disk.version
                              << "is newer than supported; falling back to defaults"
                              << "(file preserved on disk)";
        m_playlists.clear();
        // Remember the bytes so persist() recognises the file it must not
        // overwrite, but keep the merge ancestor empty: we cannot claim to
        // understand playlists we did not parse.
        m_diskBaseline.clear();
        m_diskBaselineOrder.clear();
        m_diskRaw = disk.raw;
        rebuildIndex();
        return; // no overwrite
    case DiskStatus::Ok: break;
    }
    m_playlists = disk.playlists;
    captureDiskState(m_playlists, disk.raw);
    rebuildIndex();
}

bool PlaylistManager::persist() {
    const QString path = configFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());

    // Another manager may have rewritten the file since we last synced with
    // it. Writing our snapshot wholesale would drop everything it added, with
    // no error and nothing to recover from, so fold its version in first.
    const DiskRead disk = readFromDisk();
    if (disk.status == DiskStatus::TooNew) {
        qCWarning(lcPlaylist) << "refusing to overwrite playlists.json version" << disk.version
                              << "- it was written by a newer plugin";
        emit persistFailed("playlists.json was written by a newer version");
        return false;
    }
    if (disk.status == DiskStatus::Ok && disk.raw != m_diskRaw) {
        const QVector<Playlist> merged = mergeWithDisk(disk.playlists);
        m_playlists                    = merged;
        rebuildIndex();
        pruneStaleItemsModels();
    }

    QJsonObject root;
    root["version"] = 1;
    QJsonArray arr;
    for (const auto& pl : m_playlists) arr.append(playlistToJson(pl));
    root["playlists"] = arr;

    const QJsonDocument doc(root);
    // Call the static directly — constructing a FileHelper here would mkpath
    // the unrelated wallpaper config dir as a ctor side effect.
    if (! FileHelper::atomicWriteJson(path, doc)) {
        emit persistFailed("write failed");
        return false;
    }
    captureDiskState(m_playlists, doc.toJson(QJsonDocument::Indented));
    rearmFileWatch();
    emit persisted();
    return true;
}

void PlaylistManager::rearmFileWatch() {
    if (! m_watcher) return;
    const QString path = configFilePath();
    const QString dir  = QFileInfo(path).absolutePath();
    if (! m_watcher->directories().contains(dir) && QFileInfo::exists(dir)) m_watcher->addPath(dir);
    if (! m_watcher->files().contains(path) && QFileInfo::exists(path)) m_watcher->addPath(path);
}

void PlaylistManager::onWatchedPathChanged() {
    rearmFileWatch();
    const DiskRead disk = readFromDisk();
    // Mid-replace (the target is briefly gone while the .tmp is renamed over
    // it) or a file we must not interpret: leave our state alone. Notably we
    // do NOT run load()'s corrupt-recovery here, which would rename a file
    // another process is still writing out of the way.
    if (disk.status != DiskStatus::Ok) return;
    if (disk.raw == m_diskRaw) return; // our own write echoing back
    if (m_persistPending) {
        // We are sitting on an unwritten mutation. Flushing merges their
        // change into ours instead of throwing one of the two away.
        flushPersist();
        return;
    }
    reloadFrom(disk);
}

// UI4.1: mark a write pending and (re)start the 250ms debounce. Calls in
// quick succession just slide the window — only the final flushPersist runs.
void PlaylistManager::schedulePersist() {
    m_persistPending = true;
    m_persistDebounceTimer.start();
}

// UI4.1: synchronous flush. Drains the pending flag and writes once via
// persist(). Safe to call when nothing is pending (no-op).
void PlaylistManager::flushPersist() {
    if (! m_persistPending) return;
    m_persistPending = false;
    m_persistDebounceTimer.stop();
    persist();
}

void PlaylistManager::rebuildIndex() {
    m_indexById.clear();
    for (int i = 0; i < m_playlists.size(); ++i) m_indexById.insert(m_playlists[i].id, i);
    if (m_listModel) m_listModel->resetUnderlying();
    for (auto* m : m_itemsModels)
        if (m) m->resetUnderlying();
    emit playlistsChanged();
}

// UI4.2: like rebuildIndex but DOES NOT touch the view models. Callers that
// have already emitted granular row signals (begin/end) around the mutation
// only need the internal id->row map refreshed. Mirrors rebuildIndex except
// it omits the model reset + playlistsChanged emit (callers emit their own
// after the granular end* signal completes).
void PlaylistManager::rebuildIdIndexOnly() {
    m_indexById.clear();
    for (int i = 0; i < m_playlists.size(); ++i) m_indexById.insert(m_playlists[i].id, i);
}

void PlaylistManager::pruneStaleItemsModels() {
    // Walk a snapshot of cache keys — we mutate the map below. Any id no
    // longer in m_indexById means the underlying playlist was removed by
    // load() (external edit, corruption-recovery rewrite). The cached
    // model survives in the deferred-delete queue so still-bound QML
    // views see rowCount==0 and drop their delegates cleanly.
    QList<QString> staleKeys;
    for (auto it = m_itemsModels.constBegin(); it != m_itemsModels.constEnd(); ++it) {
        if (! m_indexById.contains(it.key())) staleKeys.append(it.key());
    }
    for (const auto& id : staleKeys) {
        if (auto* model = m_itemsModels.take(id)) {
            model->resetUnderlying();
            model->deleteLater();
        }
    }
}

const Playlist* PlaylistManager::findPlaylist(const QString& id) const {
    auto it = m_indexById.constFind(id);
    if (it == m_indexById.constEnd()) return nullptr;
    return &m_playlists[*it];
}

Playlist* PlaylistManager::findPlaylist(const QString& id) {
    auto it = m_indexById.constFind(id);
    if (it == m_indexById.constEnd()) return nullptr;
    return &m_playlists[*it];
}

QString PlaylistManager::createPlaylist(const QString& name) {
    Playlist pl;
    pl.id          = QUuid::createUuid().toString(QUuid::WithoutBraces);
    pl.name        = name;
    pl.mode        = PlaylistMode::Sequential;
    pl.intervalMin = 15;
    pl.created     = QDateTime::currentSecsSinceEpoch();
    pl.modified    = pl.created;
    // UI4.2: begin-mutate-end sequence so the QML view inserts the new row
    // delegate in place instead of rebuilding every delegate (resetUnderlying
    // path lost scroll position + selection state).
    const int newRow = m_playlists.size();
    if (m_listModel) m_listModel->beginInsertRow(newRow);
    m_playlists.append(pl);
    m_indexById.insert(pl.id, newRow);
    if (m_listModel) m_listModel->endInsertRow();
    schedulePersist();
    emit playlistsChanged();
    return pl.id;
}

bool PlaylistManager::deletePlaylist(const QString& id) {
    auto it = m_indexById.constFind(id);
    if (it == m_indexById.constEnd()) return false;
    if (m_activeId == id) deactivate();
    // UI4.2: begin-mutate-end so the view animates the single row out instead
    // of discarding every delegate. The internal id->row map is rebuilt by
    // rebuildIdIndexOnly (no view reset). emit playlistsChanged after end so
    // the listeners see the deletion via the granular signal first.
    const int row = *it;
    if (m_listModel) m_listModel->beginRemoveRow(row);
    m_playlists.removeAt(row);
    rebuildIdIndexOnly();
    if (m_listModel) m_listModel->endRemoveRow();
    // Evict the cached items-model for the deleted playlist. The model
    // object itself, if any QML view still holds it, survives until the
    // deferred delete drains, but it is removed from our cache so future
    // addItem/removeItem/moveItem dispatches do not deliver row signals
    // to a playlist that no longer exists. resetUnderlying() runs before
    // deleteLater() so any current view sees rowCount==0 immediately
    // rather than the prior rows.
    if (auto* model = m_itemsModels.take(id)) {
        model->resetUnderlying();
        model->deleteLater();
    }
    emit playlistsChanged();
    schedulePersist();
    return true;
}

bool PlaylistManager::renamePlaylist(const QString& id, const QString& name) {
    auto* pl = findPlaylist(id);
    if (! pl) return false;
    pl->name     = name;
    pl->modified = QDateTime::currentSecsSinceEpoch();
    if (m_listModel) m_listModel->notifyRowChanged(m_indexById.value(id));
    schedulePersist();
    emit playlistsChanged();
    return true;
}

bool PlaylistManager::setMode(const QString& id, PlaylistMode mode) {
    auto* pl = findPlaylist(id);
    if (! pl) return false;
    pl->mode     = mode;
    pl->modified = QDateTime::currentSecsSinceEpoch();
    if (m_listModel) m_listModel->notifyRowChanged(m_indexById.value(id));
    schedulePersist();
    return true;
}

bool PlaylistManager::setMode(const QString& id, int mode) {
    return setMode(id, static_cast<PlaylistMode>(mode));
}

bool PlaylistManager::setIntervalMin(const QString& id, int minutes) {
    auto* pl = findPlaylist(id);
    if (! pl) return false;
    pl->intervalMin = clampIntervalMin(minutes);
    pl->modified    = QDateTime::currentSecsSinceEpoch();
    if (m_listModel) m_listModel->notifyRowChanged(m_indexById.value(id));
    schedulePersist();
    return true;
}

bool PlaylistManager::addItem(const QString& playlistId, const QString& workshopId) {
    auto* pl = findPlaylist(playlistId);
    if (! pl) return false;
    PlaylistItem it;
    it.workshopId = workshopId;
    // UI4.2: begin-mutate-end on the items model so the new row is appended
    // in place. The playlist row in m_listModel is dataChanged (itemCount
    // role bumped) — no row reset there either.
    const int newRow = static_cast<int>(pl->items.size());
    auto*     items  = m_itemsModels.value(playlistId);
    if (items) items->beginInsertRow(newRow);
    pl->items.append(it);
    pl->modified = QDateTime::currentSecsSinceEpoch();
    if (items) items->endInsertRow();
    if (m_listModel) m_listModel->notifyRowChanged(m_indexById.value(playlistId));
    schedulePersist();
    return true;
}

bool PlaylistManager::removeItem(const QString& playlistId, int index) {
    auto* pl = findPlaylist(playlistId);
    if (! pl || index < 0 || index >= pl->items.size()) return false;
    // UI4.2: begin-mutate-end so the view animates the row out.
    auto* items = m_itemsModels.value(playlistId);
    if (items) items->beginRemoveRow(index);
    pl->items.removeAt(index);
    pl->modified = QDateTime::currentSecsSinceEpoch();
    if (items) items->endRemoveRow();
    if (m_listModel) m_listModel->notifyRowChanged(m_indexById.value(playlistId));
    schedulePersist();
    return true;
}

bool PlaylistManager::moveItem(const QString& playlistId, int fromIdx, int toIdx) {
    auto* pl = findPlaylist(playlistId);
    if (! pl) return false;
    if (fromIdx < 0 || fromIdx >= pl->items.size()) return false;
    if (toIdx < 0 || toIdx >= pl->items.size()) return false;
    if (fromIdx == toIdx) return true;
    // UI4.2: begin-mutate-end so the view animates the row move (preserving
    // selection + scroll) instead of discarding every delegate. The wrapper
    // handles the Qt destinationRow off-by-one (toRow+1 for forward moves).
    auto* items = m_itemsModels.value(playlistId);
    if (items) items->beginMoveRow(fromIdx, toIdx);
    pl->items.move(fromIdx, toIdx);
    pl->modified = QDateTime::currentSecsSinceEpoch();
    if (items) items->endMoveRow();
    schedulePersist();
    return true;
}

bool PlaylistManager::playlistContains(const QString& playlistId, const QString& workshopId) const {
    if (playlistId.isEmpty() || playlistId == kFilteredLibraryId) return false;
    if (workshopId.isEmpty()) return false;
    const auto* pl = findPlaylist(playlistId);
    if (! pl) return false;
    for (const auto& it : pl->items)
        if (it.workshopId == workshopId) return true;
    return false;
}

PlaylistItemsModel* PlaylistManager::itemsModel(const QString& playlistId) {
    auto it = m_itemsModels.find(playlistId);
    if (it != m_itemsModels.end()) return it.value();
    auto* model = new PlaylistItemsModel(this, playlistId, this);
    m_itemsModels.insert(playlistId, model);
    return model;
}

namespace
{
constexpr int kMaxConsecutiveSkips = 8;
}

int PlaylistManager::advanceSequential(int cur, int size) const {
    if (size <= 0) return 0;
    return (cur + 1) % size;
}

int PlaylistManager::retreatSequential(int cur, int size) const {
    if (size <= 0) return 0;
    // Double modulo keeps the result non-negative when cur is 0 (wrap to tail).
    return ((cur - 1) % size + size) % size;
}

int PlaylistManager::pickShuffle(int cur, int size) {
    // Production default: route through the global thread-local RNG.
    // Behaviour is identical to the pre-refactor body.
    return pickShuffle(cur, size, *QRandomGenerator::global());
}

int PlaylistManager::pickShuffle(int cur, int size, QRandomGenerator& rng) {
    if (size <= 1) return 0;
    int pick = rng.bounded(size);
    if (pick == cur) {
        // Re-pick once to avoid trivial back-to-back repeat.
        const int second = rng.bounded(size);
        if (second != cur)
            pick = second;
        else {
            // Both picks landed on cur — force a different one.
            pick = (cur + 1) % size;
        }
    }
    return pick;
}

void PlaylistManager::armTimerForCurrent() {
    int minutes = 15;
    if (m_activeId == kFilteredLibraryId) {
        minutes = m_filteredLibraryIntervalMin > 0 ? m_filteredLibraryIntervalMin : 15;
    } else {
        const auto* pl = findPlaylist(m_activeId);
        if (! pl || pl->items.isEmpty()) return;
        minutes = pl->intervalMin;
    }
    minutes          = clampIntervalMin(minutes);
    m_lastArmEpochMs = QDateTime::currentMSecsSinceEpoch();
    m_remainingMs    = -1;
    m_timer.start(minutes * 60 * 1000);
}

int PlaylistManager::nextIntervalMsForTest() const {
    if (m_activeId.isEmpty()) return 0;
    if (m_activeId == kFilteredLibraryId) {
        return clampIntervalMin(m_filteredLibraryIntervalMin > 0 ? m_filteredLibraryIntervalMin
                                                                 : 15) *
               60 * 1000;
    }
    const auto* pl = findPlaylist(m_activeId);
    if (! pl || pl->items.isEmpty()) return 0;
    return clampIntervalMin(pl->intervalMin) * 60 * 1000;
}

bool PlaylistManager::activate(const QString& id) {
    if (m_editorMode) {
        // Editor: track id for UI display; don't tick or arm timer. The
        // runtime mgr (in main.qml) is the sole owner of the playback
        // cycle — it sees wcfg.ActivePlaylistId change and runs the
        // real activation path on its end.
        if (m_activeId == id) return true;
        m_activeId         = id;
        m_currentIndex     = 0;
        m_consecutiveSkips = 0;
        emit activePlaylistIdChanged();
        emit currentItemIndexChanged();
        return true;
    }
    if (id == kFilteredLibraryId) {
        m_activeId         = id;
        m_currentIndex     = 0;
        m_consecutiveSkips = 0;
        emit activePlaylistIdChanged();
        emit currentItemIndexChanged();
        emit requestFilteredPick();
        // Don't arm the timer yet — wait for acceptPick.
        return true;
    }
    auto* pl = findPlaylist(id);
    if (! pl || pl->items.isEmpty()) {
        emit activationFailed(id);
        return false;
    }
    m_activeId         = id;
    m_consecutiveSkips = 0;
    m_currentIndex     = (pl->mode == PlaylistMode::Shuffle)
                             ? QRandomGenerator::global()->bounded(pl->items.size())
                             : 0;
    emit activePlaylistIdChanged();
    emit currentItemIndexChanged();
    emit tick(pl->items[m_currentIndex].workshopId);
    armTimerForCurrent();
    return true;
}

void PlaylistManager::deactivate() {
    if (m_editorMode) {
        if (m_activeId.isEmpty()) return;
        m_activeId.clear();
        m_currentIndex = 0;
        emit activePlaylistIdChanged();
        emit currentItemIndexChanged();
        return;
    }
    m_timer.stop();
    m_activeId.clear();
    m_currentIndex = 0;
    m_remainingMs  = -1;
    emit activePlaylistIdChanged();
    emit currentItemIndexChanged();
}

void PlaylistManager::onTimerTick() {
    if (m_editorMode) return; // editor never ticks; defensive
    if (m_activeId.isEmpty()) return;
    if (m_activeId == kFilteredLibraryId) {
        emit requestFilteredPick();
        return;
    }
    auto* pl = findPlaylist(m_activeId);
    if (! pl || pl->items.isEmpty()) return;
    m_currentIndex     = (pl->mode == PlaylistMode::Shuffle)
                             ? pickShuffle(m_currentIndex, pl->items.size())
                             : advanceSequential(m_currentIndex, pl->items.size());
    m_consecutiveSkips = 0;
    emit currentItemIndexChanged();
    emit tick(pl->items[m_currentIndex].workshopId);
    armTimerForCurrent();
}

void PlaylistManager::skipCurrent() {
    if (m_editorMode) return; // editor never ticks; same invariant as onTimerTick
    if (m_activeId.isEmpty() || m_activeId == kFilteredLibraryId) return;
    if (++m_consecutiveSkips > kMaxConsecutiveSkips) {
        // Deactivate rather than silently wedging — the user sees the
        // playlist toggle off in the UI and the controller's
        // onActivePlaylistIdChanged path runs, instead of a stuck cycle
        // that emits no tick but reports activePlaylistId() != "".
        const auto failedId = m_activeId;
        qCCritical(lcPlaylist) << "playlist" << failedId << "exceeded" << kMaxConsecutiveSkips
                               << "consecutive skips; deactivating";
        deactivate();
        emit activationFailed(failedId);
        return;
    }
    auto* pl = findPlaylist(m_activeId);
    if (! pl || pl->items.isEmpty()) return;
    m_currentIndex = advanceSequential(m_currentIndex, pl->items.size());
    emit currentItemIndexChanged();
    emit tick(pl->items[m_currentIndex].workshopId);
    armTimerForCurrent();
}

void PlaylistManager::stepBy(int delta) {
    if (m_editorMode) return; // the dialog's mgr never drives the wallpaper
    if (m_activeId.isEmpty() || delta == 0) return;
    const bool forward = delta > 0;
    if (m_activeId == kFilteredLibraryId) {
        // No item list on this side: QML owns the live filtered model, so it
        // serves the pick (and the history that makes "back" mean anything).
        if (forward)
            emit requestFilteredPick();
        else
            emit requestFilteredPreviousPick();
        return;
    }
    auto* pl = findPlaylist(m_activeId);
    if (! pl || pl->items.isEmpty()) return;
    if (forward) {
        // Forward matches what the timer would have done, so a press and a
        // tick land on the same item.
        m_currentIndex = (pl->mode == PlaylistMode::Shuffle)
                             ? pickShuffle(m_currentIndex, pl->items.size())
                             : advanceSequential(m_currentIndex, pl->items.size());
    } else {
        // Shuffle keeps no play history, so back-stepping walks the stored
        // list order in reverse for both modes: a repeatable move the user can
        // undo, rather than another random wallpaper.
        m_currentIndex = retreatSequential(m_currentIndex, pl->items.size());
    }
    // Deliberately not touching m_consecutiveSkips: the budget belongs to the
    // resolve-failure path, and a user gesture is neither a failure nor proof
    // that a previously-broken item became loadable.
    emit currentItemIndexChanged();
    emit tick(pl->items[m_currentIndex].workshopId);
    armTimerForCurrent(); // restart the countdown from the manual move
}

void PlaylistManager::acceptPick(const QString& workshopId) {
    if (m_editorMode) return; // editor doesn't drive the filtered cycle
    if (m_activeId != kFilteredLibraryId) return;
    if (workshopId.isEmpty()) {
        // QML had nothing to offer; just re-arm the timer.
        armTimerForCurrent();
        return;
    }
    emit tick(workshopId);
    armTimerForCurrent();
}

void PlaylistManager::pauseTicks() {
    if (! m_timer.isActive()) return;
    const qint64 now     = QDateTime::currentMSecsSinceEpoch();
    const qint64 elapsed = now - m_lastArmEpochMs;
    const int    total   = m_timer.interval();
    m_remainingMs        = std::max<qint64>(0, total - elapsed);
    m_timer.stop();
}

void PlaylistManager::resumeTicks() {
    if (m_remainingMs < 0 || m_activeId.isEmpty()) return;
    m_lastArmEpochMs = QDateTime::currentMSecsSinceEpoch();
    m_timer.start(static_cast<int>(m_remainingMs));
    m_remainingMs = -1;
}

void PlaylistManager::setActivePlaylistId(const QString& id) {
    if (m_activeId == id) return;
    if (id.isEmpty()) {
        deactivate();
        return;
    }
    activate(id);
}

void PlaylistManager::setFilteredLibraryIntervalMin(int minutes) {
    m_filteredLibraryIntervalMin = clampIntervalMin(minutes);
    if (m_activeId == kFilteredLibraryId && m_timer.isActive()) {
        // Re-arm so the new interval takes effect on next tick.
        armTimerForCurrent();
    }
}

void PlaylistManager::setEditorMode(bool on) {
    if (m_editorMode == on) return;
    m_editorMode = on;
    if (on && m_timer.isActive()) {
        // Switching INTO editor mode while a timer is armed: stop it so the
        // mgr can't accidentally tick the wallpaper. (Set-then-toggle isn't
        // a common path but is cheap to guard.)
        m_timer.stop();
        m_remainingMs = -1;
    }
    emit editorModeChanged();
}

void PlaylistManager::reload() { reloadFrom(readFromDisk()); }

void PlaylistManager::reloadFrom(const DiskRead& disk) {
    if (m_editorMode) {
        // Editor just needs the fresh data; no activation state to preserve.
        m_timer.stop();
        loadFrom(disk);
        pruneStaleItemsModels();
        return;
    }
    // Runtime: preserve active state across the reload so the user's
    // playlist edits (interval change, items added/removed) take effect
    // without restarting the cycle from scratch.
    const QString savedActiveId   = m_activeId;
    const int     savedCurrentIdx = m_currentIndex;
    const bool    wasTimerActive  = m_timer.isActive();

    m_timer.stop();
    loadFrom(disk);
    pruneStaleItemsModels();

    if (savedActiveId.isEmpty()) return;
    if (savedActiveId == kFilteredLibraryId) {
        // Filtered library is always valid; just re-arm with whatever
        // interval the dialog may have written.
        if (wasTimerActive) armTimerForCurrent();
        return;
    }
    const auto* pl = findPlaylist(savedActiveId);
    if (! pl || pl->items.isEmpty()) {
        // Playlist deleted (or emptied) while the runtime wasn't looking;
        // deactivate so the cycle doesn't tick a stale id.
        m_activeId.clear();
        m_currentIndex = 0;
        emit activePlaylistIdChanged();
        emit currentItemIndexChanged();
        return;
    }
    // Playlist still exists. Clamp index to new size + re-arm so the new
    // interval (if the user changed it in the dialog) takes effect.
    const int newIdx = std::min(savedCurrentIdx, static_cast<int>(pl->items.size()) - 1);
    if (newIdx != savedCurrentIdx) {
        m_currentIndex = newIdx;
        emit currentItemIndexChanged();
    }
    if (wasTimerActive) armTimerForCurrent();
}

} // namespace wekde
