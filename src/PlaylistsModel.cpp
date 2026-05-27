#include "PlaylistsModel.hpp"
#include "PlaylistManager.hpp"

namespace wekde
{

PlaylistsModel::PlaylistsModel(PlaylistManager* mgr, QObject* parent)
    : QAbstractListModel(parent), m_mgr(mgr) {}

int PlaylistsModel::rowCount(const QModelIndex& parent) const {
    if (parent.isValid()) return 0;
    return m_mgr ? m_mgr->playlists().size() : 0;
}

QVariant PlaylistsModel::data(const QModelIndex& index, int role) const {
    if (! m_mgr || ! index.isValid()) return {};
    const int row = index.row();
    if (row < 0 || row >= m_mgr->playlists().size()) return {};
    const auto& pl = m_mgr->playlists()[row];
    switch (role) {
    case IdRole: return pl.id;
    case NameRole: return pl.name;
    case ModeRole: return playlistModeToString(pl.mode);
    case IntervalMinRole: return pl.intervalMin;
    case ItemCountRole: return pl.items.size();
    }
    return {};
}

QHash<int, QByteArray> PlaylistsModel::roleNames() const {
    return {
        { IdRole, "id" },
        { NameRole, "name" },
        { ModeRole, "mode" },
        { IntervalMinRole, "intervalMin" },
        { ItemCountRole, "itemCount" },
    };
}

void PlaylistsModel::resetUnderlying() {
    beginResetModel();
    endResetModel();
}

void PlaylistsModel::beginInsertRow(int row) {
    beginInsertRows(QModelIndex(), row, row);
}

void PlaylistsModel::endInsertRow() { endInsertRows(); }

void PlaylistsModel::beginRemoveRow(int row) {
    beginRemoveRows(QModelIndex(), row, row);
}

void PlaylistsModel::endRemoveRow() { endRemoveRows(); }

void PlaylistsModel::beginMoveRow(int fromRow, int toRow) {
    // QAbstractItemModel::beginMoveRows requires the destinationRow to be the
    // row AFTER the move target for forward moves (fromRow < toRow). For
    // backward moves, dest = toRow. Wrapping this in beginMoveRow keeps the
    // off-by-one inside the model so callers pass the natural (from, to).
    const int dest = (fromRow < toRow) ? toRow + 1 : toRow;
    beginMoveRows(QModelIndex(), fromRow, fromRow, QModelIndex(), dest);
}

void PlaylistsModel::endMoveRow() { endMoveRows(); }

void PlaylistsModel::notifyRowChanged(int row) {
    // Bounds-check both ends. Past-end is a real failure mode: callers
    // (PlaylistManager after a delete that races with a rename) could
    // legitimately end up here, and emitting dataChanged with a
    // createIndex past rowCount poisons any view that asks for that
    // index's data.
    if (row < 0 || row >= rowCount()) return;
    const auto idx = createIndex(row, 0);
    emit       dataChanged(idx, idx);
}

} // namespace wekde
