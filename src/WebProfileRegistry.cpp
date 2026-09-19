#include "WebProfileRegistry.hpp"
#include "WebUrlInterceptor.hpp"

#include <QCoreApplication>
#include <QHash>
#include <QQmlEngine>
#include <QQuickWebEngineProfile>

namespace wekde
{

namespace
{

struct ProfileEntry {
    QQuickWebEngineProfile* profile     = nullptr;
    WebUrlInterceptor*      interceptor = nullptr;
};

// storage name -> the one live profile for it. Never erased: a profile is
// Chromium's on-disk state handle for that wallpaper (cookies, cache,
// localStorage), and the point of this table is that it outlives any one
// backend view.
QHash<QString, ProfileEntry>& profileTable() {
    static QHash<QString, ProfileEntry> table;
    return table;
}

// Every QML engine that touches these objects will eventually be torn down
// (a containment closing, a qmltestrunner file finishing) well before the
// profile's storage should stop being valid, so the profile and its
// interceptor are parented to the process instead of any one engine's root.
// qApp is unset only in odd test setups that never construct a
// QCoreApplication; the fallback keeps profileFor() usable there too.
QObject* registryOwner() {
    if (qApp != nullptr) return qApp;
    static QObject fallbackOwner;
    return &fallbackOwner;
}

bool isStorageNameChar(QChar ch) {
    const char16_t u = ch.unicode();
    return (u >= u'A' && u <= u'Z') || (u >= u'a' && u <= u'z') || (u >= u'0' && u <= u'9') ||
           u == u'_' || u == u'-';
}

} // namespace

WebProfileRegistry::WebProfileRegistry(QObject* parent): QObject(parent) {}

QString WebProfileRegistry::storageNameFor(const QString& workshopId) {
    QString sanitized;
    sanitized.reserve(workshopId.size());
    for (const QChar ch : workshopId) {
        if (isStorageNameChar(ch)) sanitized.append(ch);
    }
    return QStringLiteral("wek-wp-") + (sanitized.isEmpty() ? QStringLiteral("local") : sanitized);
}

QObject* WebProfileRegistry::profileFor(const QString& workshopId) {
    const QString name = storageNameFor(workshopId);

    auto& table = profileTable();
    auto  it    = table.find(name);
    if (it != table.end()) return it->profile;

    // The storage-name constructor sets it before the profile does any
    // network-context setup; a default-construct + later setStorageName()
    // leaves a window where the profile briefly owns Qt's default storage
    // name instead of this one.
    auto* profile = new QQuickWebEngineProfile(name, registryOwner());
    profile->setOffTheRecord(false);
    profile->setHttpCacheType(QQuickWebEngineProfile::DiskHttpCache);
    // 50 MiB is well above any single wallpaper's working set and lets
    // Chromium's LRU evict stale assets instead of the cache growing toward
    // Chromium's own default cap, which scales with free disk space, over a
    // long-running session. localStorage (the persistence clock/weather
    // wallpapers depend on) is a separate quota, unaffected by this cap.
    profile->setHttpCacheMaximumSize(50 * 1024 * 1024);
    QQmlEngine::setObjectOwnership(profile, QQmlEngine::CppOwnership);

    auto* interceptor = new WebUrlInterceptor(registryOwner());
    QQmlEngine::setObjectOwnership(interceptor, QQmlEngine::CppOwnership);
    interceptor->installOn(profile);

    table.insert(name, ProfileEntry { profile, interceptor });
    return profile;
}

QObject* WebProfileRegistry::interceptorFor(const QString& workshopId) {
    profileFor(workshopId); // creates the (profile, interceptor) pair if new
    return profileTable().value(storageNameFor(workshopId)).interceptor;
}

int WebProfileRegistry::liveProfileCount() const { return profileTable().size(); }

} // namespace wekde
