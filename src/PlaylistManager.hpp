#pragma once

#include <QObject>
#include <QString>
#include <QVector>
#include <QHash>
#include <QStringList>
#include <QByteArray>
#include <QJsonObject>
#include <QTimer>

class QRandomGenerator;
class QFileSystemWatcher;

#include "Playlist.hpp"
#include "PlaylistsModel.hpp"
#include "PlaylistItemsModel.hpp"

namespace wekde
{

class PlaylistManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(PlaylistsModel* playlistsModel READ playlistsModel CONSTANT)
    Q_PROPERTY(QString activePlaylistId READ activePlaylistId WRITE setActivePlaylistId NOTIFY
                   activePlaylistIdChanged)
    Q_PROPERTY(int currentItemIndex READ currentItemIndex NOTIFY currentItemIndexChanged)
    // Editor mode: when true, activate/deactivate/onTimerTick/acceptPick/
    // skipCurrent/stepBy skip the tick + arm-timer path. The mgr still tracks
    // m_activeId for UI display + still does CRUD + persist normally — but it
    // does NOT drive wallpaper switches. The runtime mgr (editorMode=false) is the sole
    // owner of the playback cycle. Without this gate, the dialog's mgr and
    // the runtime mgr both arm independent timers on the same playlist and
    // race to write CurrentItemIndex + pick different shuffle indices.
    Q_PROPERTY(bool editorMode READ editorMode WRITE setEditorMode NOTIFY editorModeChanged)

public:
    explicit PlaylistManager(QObject* parent = nullptr);
    ~PlaylistManager() override;

    // Read access
    const QVector<Playlist>& playlists() const { return m_playlists; }
    PlaylistsModel*          playlistsModel() const { return m_listModel; }
    QString                  activePlaylistId() const { return m_activeId; }
    int                      currentItemIndex() const { return m_currentIndex; }
    bool                     editorMode() const { return m_editorMode; }
    void                     setEditorMode(bool on);

    // CRUD
    Q_INVOKABLE QString createPlaylist(const QString& name);
    Q_INVOKABLE bool    deletePlaylist(const QString& id);
    Q_INVOKABLE bool    renamePlaylist(const QString& id, const QString& name);
    Q_INVOKABLE bool    setMode(const QString& id, int mode); // QML-friendly int
    Q_INVOKABLE bool    setIntervalMin(const QString& id, int minutes);

    // Item ops
    Q_INVOKABLE bool addItem(const QString& playlistId, const QString& workshopId);
    Q_INVOKABLE bool removeItem(const QString& playlistId, int index);
    Q_INVOKABLE bool moveItem(const QString& playlistId, int fromIdx, int toIdx);
    // True if `workshopId` is already in `playlistId`. False on missing
    // playlist or sentinel "__filtered_library__" (it's not a manual-add
    // target). UI callers use this to grey out "Add" entries.
    Q_INVOKABLE bool playlistContains(const QString& playlistId, const QString& workshopId) const;

    // C++ overload (used by tests; not Q_INVOKABLE to avoid moc overload ambiguity)
    bool setMode(const QString& id, PlaylistMode mode);

    // Active playlist + cycle
    Q_INVOKABLE bool activate(const QString& id);
    Q_INVOKABLE void deactivate();
    Q_INVOKABLE void skipCurrent();
    // Manual navigation (the Next / Previous shortcuts and their D-Bus
    // methods). delta > 0 moves forward, delta < 0 moves back; magnitude is
    // ignored, one press is one item. Deliberately NOT skipCurrent: that one
    // is the resolve-failure path and spends a budget that shuts the playlist
    // down after 8 misses, which a user hammering Next must never trigger.
    Q_INVOKABLE void stepBy(int delta);
    Q_INVOKABLE void acceptPick(const QString& workshopId); // for Filtered Library
    Q_INVOKABLE void pauseTicks();
    Q_INVOKABLE void resumeTicks();
    Q_INVOKABLE void setFilteredLibraryIntervalMin(int minutes);

    // Re-read playlists.json from disk, preserving the active playlist + cycle
    // position when possible (clamped to new item count; cleared if the active
    // playlist was deleted). Runs by itself whenever the file changes under us
    // (see the watcher below); still exposed to QML because the runtime ctrl
    // also calls it on a PlaylistsReloadSeq bump.
    Q_INVOKABLE void reload();

    // Items model accessor (cached per playlist id)
    Q_INVOKABLE PlaylistItemsModel* itemsModel(const QString& playlistId);

    // Q_PROPERTY setter
    void setActivePlaylistId(const QString& id);

    // Lookup helpers
    const Playlist* findPlaylist(const QString& id) const;
    Playlist*       findPlaylist(const QString& id);

    // Test seam — call directly to simulate timer fire without waiting on QTimer.
    void onTimerTick();
    int  nextIntervalMsForTest() const;

    // Test seam: synchronously flush any persist() write that the 250ms
    // debounce timer hasn't fired yet. Older disk-state-after-mutate
    // assertions call this instead of waiting on QTRY_VERIFY_WITH_TIMEOUT.
    void flushPersistForTest() { flushPersist(); }

    // Pure sequential step pickers, siblings of pickShuffle below: index in,
    // index out, no state touched. Every caller checks items.isEmpty() first,
    // so the `size <= 0` guards inside are defence in depth -- they are what
    // stops `% size` dividing by zero if a future caller forgets, which is
    // exactly the case reachable only by calling these directly.
    int advanceSequential(int currentIdx, int size) const;
    int retreatSequential(int currentIdx, int size) const;

    // Pure shuffle picker: returns an index in [0, size) that is NOT equal
    // to `currentIdx`, with one re-pick fallback and a deterministic
    // force-different last-resort. Q_INVOKABLE so the QML controller
    // (PlaylistController._serveFilteredPick) shares the same
    // no-immediate-repeat logic the C++ timer path uses for user-curated
    // shuffle playlists. Pass currentIdx == -1 on the first pick of a
    // freshly-activated playlist (no prior); the `pick == currentIdx`
    // re-pick branch is trivially unreachable for negative `currentIdx`
    // and any non-negative `pick`.
    //
    // The Q_INVOKABLE arity-2 wrapper is what QML calls; it delegates to
    // the explicit-RNG overload below using *QRandomGenerator::global() —
    // production behaviour is unchanged. The const qualifier was dropped
    // (vs the previous declaration) because the call DOES have a side
    // effect: the global thread-local RNG's state advances on every
    // bounded() invocation. const was honest about this->state but
    // misleading about pure-function reasoning.
    Q_INVOKABLE int pickShuffle(int currentIdx, int size);
    // C++-only overload: tests pass a seeded QRandomGenerator for
    // deterministic sequences. Not Q_INVOKABLE — moc resolves overloads
    // by arity only and QML has no clean way to construct/pass a
    // QRandomGenerator&. Same dual-pattern as setMode(QString,
    // PlaylistMode) which uses a non-Q_INVOKABLE typed variant + a
    // Q_INVOKABLE int wrapper to avoid moc ambiguity.
    int pickShuffle(int currentIdx, int size, QRandomGenerator& rng);

signals:
    void playlistsChanged();
    void activePlaylistIdChanged();
    void currentItemIndexChanged();
    void editorModeChanged();
    void tick(const QString& workshopId);
    void requestFilteredPick();
    // Filtered Library only: serve the previously served pick instead of a
    // fresh one. The item list lives in QML (the live filtered model), so the
    // play history that makes "back" meaningful has to live there too.
    void requestFilteredPreviousPick();
    void activationFailed(const QString& id);
    void persistFailed(const QString& reason);
    // Fired after every successful persist() to disk. Editor-mode mgrs use
    // this to bump cfg_PlaylistsReloadSeq so the runtime mgr knows to reload.
    void persisted();

private:
    // Outcome of reading playlists.json. Every caller (load, the pre-write
    // merge, the watcher) needs to tell "nothing there yet" apart from
    // "unparseable" and "written by a newer version" before deciding what to
    // do, so the read reports which one it hit instead of collapsing them all
    // into an empty list.
    enum class DiskStatus
    {
        Ok,
        Missing,
        Unreadable,
        Corrupt,
        TooNew
    };
    struct DiskRead {
        DiskStatus        status  = DiskStatus::Missing;
        int               version = 1;
        QVector<Playlist> playlists;
        QByteArray        raw; // exact bytes, for the self-write check
        QString           error;
    };

    QString  configFilePath() const;
    DiskRead readFromDisk() const;
    void     load();
    void     loadFrom(const DiskRead& disk);
    bool     persist();
    // Remember what we believe is on disk: the per-id serialized form (the
    // common ancestor a merge needs) and the byte image (so the watcher can
    // recognise our own write).
    void captureDiskState(const QVector<Playlist>& pls, const QByteArray& raw);
    // True when our in-memory list is byte-for-byte the file we last synced
    // with, order included — i.e. we have nothing of our own to protect.
    bool inSyncWithDiskState() const;
    // Three-way merge of `theirs` (the file as it is now) against our list,
    // using the remembered baseline as the common ancestor. Per playlist id:
    // whoever changed it since the baseline wins, an edit outranks the other
    // side's delete, and a delete only sticks if the other side left the
    // playlist alone.
    QVector<Playlist> mergeWithDisk(const QVector<Playlist>& theirs) const;
    // Re-add the watch paths. atomicWriteJson replaces the file by rename(2),
    // which drops the inotify watch on the old inode, so the directory is
    // watched too and the file path re-added after every event.
    void rearmFileWatch();
    void onWatchedPathChanged();
    void reloadFrom(const DiskRead& disk);
    // UI4.1: schedule a debounced persist() (250ms single-shot). Each CRUD
    // mutator calls this instead of persist() so drag-burst reorders collapse
    // to a single atomicWriteJson at the end of the burst.
    void schedulePersist();
    // Synchronously flush any pending schedulePersist() — runs from the
    // debounce timer, the dtor, and flushPersistForTest. Safe to call when
    // nothing is pending (early-returns).
    void flushPersist();
    void rebuildIndex();
    // UI4.2: like rebuildIndex but skips the view-model reset + playlistsChanged
    // emit. Used by deletePlaylist after the granular beginRemoveRow signal so
    // the internal id->row map stays consistent without forcing a view rebuild.
    void rebuildIdIndexOnly();
    // Walk m_itemsModels and evict every entry whose id is no longer in
    // m_indexById (a playlist removed by an external reload-side edit).
    // Each evicted model is reset (rowCount→0 for any still-bound view)
    // then queued for deferred delete. Called by reload() after load().
    void pruneStaleItemsModels();
    void armTimerForCurrent();

    QVector<Playlist>   m_playlists;
    QHash<QString, int> m_indexById;
    QString             m_activeId;
    int                 m_currentIndex               = 0;
    int                 m_consecutiveSkips           = 0;
    int                 m_filteredLibraryIntervalMin = -1; // -1 = default 15
    QTimer              m_timer;
    qint64              m_remainingMs    = -1; // -1 = no pause-state
    qint64              m_lastArmEpochMs = 0;
    bool                m_editorMode     = false;

    // UI4.1: 250ms single-shot debounce around persist(). m_persistPending
    // tracks whether a flush is scheduled; restart() on each schedulePersist
    // call slides the window forward, so a drag-reorder burst (N moveItem
    // calls in tight succession) collapses to exactly one disk write.
    QTimer m_persistDebounceTimer;
    bool   m_persistPending = false;

    // Snapshot of the file as we last read or wrote it. Used both as the
    // merge ancestor and to ignore the watcher event our own write raises.
    QHash<QString, QJsonObject> m_diskBaseline;
    QStringList                 m_diskBaselineOrder;
    QByteArray                  m_diskRaw;
    QFileSystemWatcher*         m_watcher = nullptr;

    PlaylistsModel*                     m_listModel = nullptr;
    QHash<QString, PlaylistItemsModel*> m_itemsModels;
};

} // namespace wekde
