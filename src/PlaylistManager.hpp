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

public:
    explicit PlaylistManager(QObject* parent = nullptr);
    ~PlaylistManager() override;

    // Read access
    const QVector<Playlist>& playlists() const { return m_playlists; }
    PlaylistsModel*          playlistsModel() const { return m_listModel; }
    QString                  activePlaylistId() const { return m_activeId; }
    int                      currentItemIndex() const { return m_currentIndex; }

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
    Q_INVOKABLE bool playlistContains(const QString& playlistId,
                                      const QString& workshopId) const;

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

signals:
    void playlistsChanged();
    void activePlaylistIdChanged();
    void currentItemIndexChanged();
    void tick(const QString& workshopId);
    void requestFilteredPick();
    void activationFailed(const QString& id);
    void persistFailed(const QString& reason);

private:
    QString configFilePath() const;
    void    load();
    bool    persist();
    void    rebuildIndex();
    void    armTimerForCurrent();
    int     advanceSequential(int currentIdx, int size) const;
    int     pickShuffle(int currentIdx, int size) const;

    QVector<Playlist>   m_playlists;
    QHash<QString, int> m_indexById;
    QString             m_activeId;
    int                 m_currentIndex               = 0;
    int                 m_consecutiveSkips           = 0;
    int                 m_filteredLibraryIntervalMin = -1; // -1 = default 15
    QTimer              m_timer;
    qint64              m_remainingMs    = -1; // -1 = no pause-state
    qint64              m_lastArmEpochMs = 0;

    PlaylistsModel*                     m_listModel = nullptr;
    QHash<QString, PlaylistItemsModel*> m_itemsModels;
};

} // namespace wekde
