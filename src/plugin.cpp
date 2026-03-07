#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <array>
#include "MpvBackend.hpp"
#include "SceneBackend.hpp"
#include "MouseGrabber.hpp"
#include "TTYSwitchMonitor.hpp"
#include "PluginInfo.hpp"
#include "FileHelper.hpp"

constexpr std::array<uint, 2> WPVer { 1, 2 };

class Port : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

public:
    void registerTypes(const char* uri) override {
        if (strcmp(uri, "com.github.catsout.wallpaperEngineKde") != 0) return;
        qputenv("QML_XHR_ALLOW_FILE_READ", "1");
        // Allow web wallpapers to make cross-origin requests (XHR/fetch).
        // Wallpaper Engine (Windows) uses CEF with --disable-web-security;
        // many workshop wallpapers rely on this for weather/API calls.
        {
            QByteArray flags = qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
            if (!flags.contains("--disable-web-security")) {
                if (!flags.isEmpty()) flags.append(' ');
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
        qmlRegisterType<wekde::FileHelper>(uri, WPVer[0], WPVer[1], "FileHelper");
    }
};

#include "plugin.moc"
