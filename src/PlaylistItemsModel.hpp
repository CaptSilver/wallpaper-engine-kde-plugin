#pragma once

#include <QAbstractListModel>
#include <QString>

namespace wekde
{

class PlaylistManager;

class PlaylistItemsModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles {
        WorkshopIdRole = Qt::UserRole + 1,
        DurationOverrideMinRole,
    };
    PlaylistItemsModel(PlaylistManager* mgr, QString playlistId, QObject* parent = nullptr);

    int      rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void resetUnderlying();

private:
    PlaylistManager* m_mgr;
    QString          m_playlistId;
};

} // namespace wekde
