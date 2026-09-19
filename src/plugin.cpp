#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <QDebug>
#include <array>
#include <KCrash>
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
#include "WebProfileRegistry.hpp"
#include "QmlCachePurge.hpp"
#include "SafeWallpaperBridge.hpp"
#include "SafeWallpaperBridgeController.hpp"
#include "PlaylistManager.hpp"
#include "PlaylistsModel.hpp"
#include "PlaylistItemsModel.hpp"
#include "WekControl.hpp"
#include "WekNotifier.hpp"
#include "WekDiagnostics.hpp"
#include "ActivityHelper.hpp"
#ifdef WEKDE_HAS_GLOBALACCEL
#    include "WekShortcuts.hpp"
#    include <QCoreApplication>
#endif

constexpr std::array<uint, 2> WPVer { 1, 2 };

namespace
{

// Runs once per process. On an ostree host (Bazzite, Kinoite)
// every file under /usr carries mtime 0, which QFileInfo reads back as an
// *invalid* timestamp rather than the epoch -- so Qt's QML disk cache can
// never validate a compiled entry for one of our QML/JS files against the
// file's current contents, and just keeps trusting whatever was cached the
// last time the file happened to have a real timestamp (an overlay
// install, or an install made before an ostree rebase). Qt itself will
// never *write* a fresh entry for a timestamp-less source (saveToDisk
// refuses), so any entry that exists for one is unverifiable by
// construction; removing it is safe and just costs one recompile. See
// QmlCachePurge.hpp for the mechanism in full. Cost here is roughly one
// qmlcache lookup per QML/JS file this plugin ships -- tens of stats, not
// a directory walk of /usr -- cheap enough to run unconditionally.
void purgeStaleQmlCacheOnce() {
    static bool done = false;
    if (done) return;
    done = true;

    const QStringList packageDirs = wekde::pluginQmlPackageDirs();
    if (packageDirs.isEmpty()) return;

    const wekde::QmlCachePurgeResult result =
        wekde::purgeUnverifiableQmlCache(packageDirs, wekde::qmlCacheDir());

    bool purgedMainQml = false;
    for (const wekde::QmlCacheEntry& entry : result.removed) {
        qWarning() << "wekde: purged unverifiable QML cache entry for" << entry.sourcePath << "->"
                   << entry.cacheFile;
        if (entry.sourcePath.endsWith(QStringLiteral("contents/ui/main.qml"))) purgedMainQml = true;
    }
    // A failed removal leaves a stale, unverifiable entry sitting in the
    // cache directory -- still worth a line, even though there is nothing
    // more we can do about it here.
    for (const wekde::QmlCacheEntry& entry : result.failed) {
        qWarning() << "wekde: failed to purge unverifiable QML cache entry for" << entry.sourcePath
                   << "->" << entry.cacheFile;
    }

    if (purgedMainQml) {
        // initializeEngine runs after the engine has already mapped
        // main.qml in, so this pass only protects files this session
        // hasn't loaded yet (backends, helpers, config UI). The purge
        // guarantees the *next* load of main.qml recompiles fresh; it
        // can't retroactively fix the copy this engine is already running.
        qWarning()
            << "wekde: main.qml's compiled QML cache was stale and has been purged, but this "
               "plasmashell session already loaded the old compiled copy -- restart "
               "plasmashell to pick up the fresh one (log out/in, or `systemctl --user "
               "restart plasma-plasmashell.service`)";
    }
}

} // namespace

class Port : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

public:
    void registerTypes(const char* uri) override {
        if (strcmp(uri, "com.github.captsilver.wallpaperEngineKde") != 0) return;

        // Register with KCrash so DrKonqi catches crashes in this plugin
        // .so.  plasmashell already registers (KCrash::initialize() is
        // idempotent), so this is just defensive in case the plugin is
        // dlopen'd before plasmashell has run init.
        //
        // KF6 6.x removed setApplicationProductName / setApplicationVersion /
        // setBugAddress from the KCrash namespace; the equivalent metadata
        // is now sourced from KAboutData::applicationData().  Plasmashell
        // already sets that for the running shell, so DrKonqi still has
        // enough to surface a useful crash report.  If we ever ship a
        // standalone wallpaper-host process this is where we'd set up a
        // KAboutData for it.
        KCrash::initialize();

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
        qmlRegisterType<wekde::ScreenSaverMonitor>(uri, WPVer[0], WPVer[1], "ScreenSaverMonitor");
        qmlRegisterType<wekde::MprisMonitor>(uri, WPVer[0], WPVer[1], "MprisMonitor");
        qmlRegisterType<wekde::FileHelper>(uri, WPVer[0], WPVer[1], "FileHelper");
        qmlRegisterType<wekde::WebAudioBridge>(uri, WPVer[0], WPVer[1], "WebAudioBridge");
        qmlRegisterType<wekde::WebUrlInterceptor>(uri, WPVer[0], WPVer[1], "WebUrlInterceptor");
        qmlRegisterType<wekde::WebProfileRegistry>(uri, WPVer[0], WPVer[1], "WebProfileRegistry");
        qmlRegisterType<wekde::SafeWallpaperBridge>(uri, WPVer[0], WPVer[1], "SafeWallpaperBridge");
        qmlRegisterType<wekde::SafeWallpaperBridgeController>(
            uri, WPVer[0], WPVer[1], "SafeWallpaperBridgeController");
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
        qmlRegisterType<wekde::WekControl>(uri, WPVer[0], WPVer[1], "WekControl");
        qmlRegisterType<wekde::WekNotifier>(uri, WPVer[0], WPVer[1], "WekNotifier");
        qmlRegisterType<wekde::WekDiagnostics>(uri, WPVer[0], WPVer[1], "WekDiagnostics");
        qmlRegisterType<wekde::ActivityHelper>(uri, WPVer[0], WPVer[1], "ActivityHelper");

#ifdef WEKDE_HAS_GLOBALACCEL
        // Register KGlobalAccel-bound actions.  Construct once per process
        // (qApp ownership ensures the KActionCollection lives as long as
        // the host process).  KGlobalAccel dedupes by action id within the
        // component name, so multi-plasmoid construction is harmless.
        static auto* shortcuts = new wekde::WekShortcuts(qApp);
        Q_UNUSED(shortcuts);
#endif
    }

    void initializeEngine(QQmlEngine* engine, const char* uri) override {
        QQmlExtensionPlugin::initializeEngine(engine, uri);
        if (strcmp(uri, "com.github.captsilver.wallpaperEngineKde") != 0) return;
        purgeStaleQmlCacheOnce();
    }
};

#include "plugin.moc"
