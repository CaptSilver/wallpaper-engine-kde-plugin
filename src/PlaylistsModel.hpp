#pragma once

#include <QAbstractListModel>

namespace wekde
{

class PlaylistManager;

class PlaylistsModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles
    {
        IdRole = Qt::UserRole + 1,
        NameRole,
        ModeRole,
        IntervalMinRole,
        ItemCountRole,
    };
    explicit PlaylistsModel(PlaylistManager* mgr, QObject* parent = nullptr);

    int                    rowCount(const QModelIndex& parent = {}) const override;
    QVariant               data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void resetUnderlying();
    void notifyRowChanged(int row);

    // UI4.2: granular wrappers around QAbstractItemModel's protected begin/end
    // signal API. PlaylistManager calls these around its in-memory mutations
    // (begin -> mutate underlying QVector -> end) so QML views preserve scroll
    // position, currentIndex, and animation state across single-row CRUD.
    // Used INSTEAD of resetUnderlying() on single-row mutator paths; reset is
    // still used for genuine model-wide reloads (load() / corrupt recovery).
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
};

} // namespace wekde
