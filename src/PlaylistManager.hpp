#pragma once

#include <QObject>
#include <QString>
#include <QVector>
#include <QHash>
#include <QTimer>

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
    // Editor mode: when true, activate/deactivate/onTimerTick/acceptPick skip
    // the tick + arm-timer path. The mgr still tracks m_activeId for UI
    // display + still does CRUD + persist normally — but it does NOT drive
    // wallpaper switches. The runtime mgr (editorMode=false) is the sole
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
    Q_INVOKABLE void acceptPick(const QString& workshopId); // for Filtered Library
    Q_INVOKABLE void pauseTicks();
    Q_INVOKABLE void resumeTicks();
    Q_INVOKABLE void setFilteredLibraryIntervalMin(int minutes);

    // Re-read playlists.json from disk, preserving the active playlist + cycle
    // position when possible (clamped to new item count; cleared if the active
    // playlist was deleted). Runtime ctrl calls this when the dialog bumps
    // PlaylistsReloadSeq so user-edited intervals/items take effect without a
    // plasmashell restart.
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

    // Pure shuffle picker: returns an index in [0, size) that is NOT equal
    // to `currentIdx`, with one re-pick fallback and a deterministic
    // force-different last-resort. Q_INVOKABLE so the QML controller
    // (PlaylistController._serveFilteredPick) shares the same
    // no-immediate-repeat logic the C++ timer path uses for user-curated
    // shuffle playlists. Pass currentIdx == -1 on the first pick of a
    // freshly-activated playlist (no prior); the `pick == currentIdx`
    // re-pick branch is trivially unreachable for negative `currentIdx`
    // and any non-negative `pick`.
    Q_INVOKABLE int pickShuffle(int currentIdx, int size) const;

signals:
    void playlistsChanged();
    void activePlaylistIdChanged();
    void currentItemIndexChanged();
    void editorModeChanged();
    void tick(const QString& workshopId);
    void requestFilteredPick();
    void activationFailed(const QString& id);
    void persistFailed(const QString& reason);
    // Fired after every successful persist() to disk. Editor-mode mgrs use
    // this to bump cfg_PlaylistsReloadSeq so the runtime mgr knows to reload.
    void persisted();

private:
    QString configFilePath() const;
    void    load();
    bool    persist();
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
    void armTimerForCurrent();
    int  advanceSequential(int currentIdx, int size) const;

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

    PlaylistsModel*                     m_listModel = nullptr;
    QHash<QString, PlaylistItemsModel*> m_itemsModels;
};

} // namespace wekde
