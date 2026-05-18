#include "Playlist.hpp"

#include <algorithm>

namespace wekde
{

QString playlistModeToString(PlaylistMode m) {
    return m == PlaylistMode::Shuffle ? "shuffle" : "sequential";
}

PlaylistMode playlistModeFromString(const QString& s, PlaylistMode fallback) {
    if (s == "shuffle") return PlaylistMode::Shuffle;
    if (s == "sequential") return PlaylistMode::Sequential;
    return fallback;
}

int clampIntervalMin(int value) { return std::clamp(value, 1, 1440); }

QJsonObject playlistItemToJson(const PlaylistItem& it) {
    QJsonObject o;
    o["workshop_id"] = it.workshopId;
    return o;
}

PlaylistItem playlistItemFromJson(const QJsonObject& obj) {
    PlaylistItem it;
    it.workshopId = obj.value("workshop_id").toString();
    return it;
}

QJsonObject playlistToJson(const Playlist& pl) {
    QJsonObject o;
    o["id"]           = pl.id;
    o["name"]         = pl.name;
    o["mode"]         = playlistModeToString(pl.mode);
    o["interval_min"] = clampIntervalMin(pl.intervalMin);
    o["created"]      = pl.created;
    o["modified"]     = pl.modified;
    QJsonArray items;
    for (const auto& it : pl.items) items.append(playlistItemToJson(it));
    o["items"] = items;
    return o;
}

Playlist playlistFromJson(const QJsonObject& obj) {
    Playlist pl;
    pl.id                  = obj.value("id").toString();
    pl.name                = obj.value("name").toString();
    pl.mode                = playlistModeFromString(obj.value("mode").toString());
    pl.intervalMin         = clampIntervalMin(obj.value("interval_min").toInt(15));
    pl.created             = static_cast<qint64>(obj.value("created").toDouble());
    pl.modified            = static_cast<qint64>(obj.value("modified").toDouble());
    const QJsonArray items = obj.value("items").toArray();
    pl.items.reserve(items.size());
    for (const auto& v : items) pl.items.append(playlistItemFromJson(v.toObject()));
    return pl;
}

} // namespace wekde
