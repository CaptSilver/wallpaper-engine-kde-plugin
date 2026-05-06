#pragma once

#include <QString>
#include <QVector>
#include <QJsonObject>
#include <QJsonArray>
#include <optional>

namespace wekde
{

enum class PlaylistMode
{
    Sequential,
    Shuffle
};

struct PlaylistItem {
    QString            workshopId;
    std::optional<int> durationOverrideMin; // minutes, none = use playlist default
};

struct Playlist {
    QString               id; // UUID v4 string, lowercased, no braces
    QString               name;
    PlaylistMode          mode        = PlaylistMode::Sequential;
    int                   intervalMin = 15; // 1..1440 (validated on load + every setter)
    QVector<PlaylistItem> items;
    qint64                created  = 0; // unix epoch seconds
    qint64                modified = 0;
};

// Sentinel id reserved for the built-in Filtered Library.
inline constexpr const char* kFilteredLibraryId = "__filtered_library__";

// JSON helpers. mode/interval clamping is done by these readers.
QJsonObject playlistToJson(const Playlist& pl);
Playlist    playlistFromJson(const QJsonObject& obj);

QJsonObject  playlistItemToJson(const PlaylistItem& it);
PlaylistItem playlistItemFromJson(const QJsonObject& obj);

QString      playlistModeToString(PlaylistMode m);
PlaylistMode playlistModeFromString(const QString& s,
                                    PlaylistMode   fallback = PlaylistMode::Sequential);

// Clamp helper used by setters and load paths. Returns `min..max` clamped value.
int clampIntervalMin(int value);

} // namespace wekde
