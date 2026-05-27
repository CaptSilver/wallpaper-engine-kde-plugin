#pragma once

#include <QAbstractListModel>
#include <QString>

namespace wekde
{

class PlaylistManager;

class PlaylistItemsModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles
    {
        WorkshopIdRole = Qt::UserRole + 1,
    };
    PlaylistItemsModel(PlaylistManager* mgr, QString playlistId, QObject* parent = nullptr);

    int                    rowCount(const QModelIndex& parent = {}) const override;
    QVariant               data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void resetUnderlying();

    // UI4.2: granular wrappers around QAbstractItemModel's protected begin/end
    // signal API. PlaylistManager calls these around in-memory item mutations
    // so QML views preserve scroll + currentIndex + animations across
    // single-row CRUD instead of forcing a full delegate rebuild.
    void beginInsertRow(int row);
    void endInsertRow();
    void beginRemoveRow(int row);
    void endRemoveRow();
    // beginMoveRow handles the Qt off-by-one: destinationRow = toRow + 1 for
    // forward moves (fromRow < toRow), otherwise destinationRow = toRow.
    void beginMoveRow(int fromRow, int toRow);
    void endMoveRow();

private:
    PlaylistManager* m_mgr;
    QString          m_playlistId;
};

} // namespace wekde
