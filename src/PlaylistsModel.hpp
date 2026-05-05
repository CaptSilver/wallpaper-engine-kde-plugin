#pragma once

#include <QAbstractListModel>

namespace wekde
{

class PlaylistManager;

class PlaylistsModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        ModeRole,
        IntervalMinRole,
        ItemCountRole,
    };
    explicit PlaylistsModel(PlaylistManager* mgr, QObject* parent = nullptr);

    int      rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void resetUnderlying();
    void notifyRowChanged(int row);

private:
    PlaylistManager* m_mgr;
};

} // namespace wekde
