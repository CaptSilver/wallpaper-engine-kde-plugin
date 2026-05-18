#include "PlaylistItemsModel.hpp"
#include "PlaylistManager.hpp"

namespace wekde
{

PlaylistItemsModel::PlaylistItemsModel(PlaylistManager* mgr, QString playlistId, QObject* parent)
    : QAbstractListModel(parent), m_mgr(mgr), m_playlistId(std::move(playlistId)) {}

int PlaylistItemsModel::rowCount(const QModelIndex& parent) const {
    if (parent.isValid()) return 0;
    if (! m_mgr) return 0;
    const auto* pl = m_mgr->findPlaylist(m_playlistId);
    return pl ? pl->items.size() : 0;
}

QVariant PlaylistItemsModel::data(const QModelIndex& index, int role) const {
    if (! m_mgr || ! index.isValid()) return {};
    const auto* pl = m_mgr->findPlaylist(m_playlistId);
    if (! pl) return {};
    const int row = index.row();
    if (row < 0 || row >= pl->items.size()) return {};
    const auto& it = pl->items[row];
    switch (role) {
    case WorkshopIdRole: return it.workshopId;
    }
    return {};
}

QHash<int, QByteArray> PlaylistItemsModel::roleNames() const {
    return {
        { WorkshopIdRole, "workshopId" },
    };
}

void PlaylistItemsModel::resetUnderlying() {
    beginResetModel();
    endResetModel();
}

} // namespace wekde
