#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <array>
#include "MpvBackend.hpp"
#include "SceneBackend.hpp"
#include "MouseGrabber.hpp"
#include "TTYSwitchMonitor.hpp"
#include "ScreenSaverMonitor.hpp"
#include "MprisMonitor.hpp"
#include "PluginInfo.hpp"
#include "FileHelper.hpp"
#include "WebAudioBridge.hpp"
#include "WebUrlInterceptor.hpp"
#include "SafeWallpaperBridge.hpp"
#include "MigrationHelper.h"
#include "PlaylistManager.hpp"
#include "PlaylistsModel.hpp"
#include "PlaylistItemsModel.hpp"

constexpr std::array<uint, 2> WPVer { 1, 2 };

class Port : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

public:
    void registerTypes(const char* uri) override {
        if (strcmp(uri, "com.github.captsilver.wallpaperEngineKde") != 0) return;
        qputenv("QML_XHR_ALLOW_FILE_READ", "1");
        // Allow web wallpapers to make cross-origin requests (XHR/fetch).
        // Wallpaper Engine (Windows) uses CEF with --disable-web-security;
        // many workshop wallpapers rely on this for weather/API calls.
        {
            QByteArray flags = qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
            if (! flags.contains("--disable-web-security")) {
                if (! flags.isEmpty()) flags.append(' ');
                flags.append("--disable-web-security");
                qputenv("QTWEBENGINE_CHROMIUM_FLAGS", flags);
            }
        }
        qmlRegisterType<wekde::PluginInfo>(uri, WPVer[0], WPVer[1], "PluginInfo");
        qmlRegisterType<wekde::MouseGrabber>(uri, WPVer[0], WPVer[1], "MouseGrabber");
        qmlRegisterType<scenebackend::SceneObject>(uri, WPVer[0], WPVer[1], "SceneViewer");
        std::setlocale(LC_NUMERIC, "C");
        qmlRegisterType<mpv::MpvObject>(uri, WPVer[0], WPVer[1], "Mpv");
        qmlRegisterType<wekde::TTYSwitchMonitor>(uri, WPVer[0], WPVer[1], "TTYSwitchMonitor");
        qmlRegisterType<wekde::ScreenSaverMonitor>(
            uri, WPVer[0], WPVer[1], "ScreenSaverMonitor");
        qmlRegisterType<wekde::MprisMonitor>(uri, WPVer[0], WPVer[1], "MprisMonitor");
        qmlRegisterType<wekde::FileHelper>(uri, WPVer[0], WPVer[1], "FileHelper");
        qmlRegisterType<wekde::WebAudioBridge>(uri, WPVer[0], WPVer[1], "WebAudioBridge");
        qmlRegisterType<wekde::WebUrlInterceptor>(uri, WPVer[0], WPVer[1], "WebUrlInterceptor");
        qmlRegisterType<wekde::SafeWallpaperBridge>(
            uri, WPVer[0], WPVer[1], "SafeWallpaperBridge");
        qmlRegisterType<wekde::PlaylistManager>(uri, WPVer[0], WPVer[1], "PlaylistManager");
        qmlRegisterUncreatableType<wekde::PlaylistsModel>(
            uri,
            WPVer[0],
            WPVer[1],
            "PlaylistsModel",
            "PlaylistsModel is owned by PlaylistManager");
        qmlRegisterUncreatableType<wekde::PlaylistItemsModel>(
            uri,
            WPVer[0],
            WPVer[1],
            "PlaylistItemsModel",
            "PlaylistItemsModel is created via PlaylistManager.itemsModel()");
        qmlRegisterSingletonType<wekde::MigrationHelper>(
            uri, WPVer[0], WPVer[1], "MigrationHelper", [](QQmlEngine*, QJSEngine*) -> QObject* {
                return new wekde::MigrationHelper();
            });
    }
};

#include "plugin.moc"
