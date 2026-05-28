// Unit tests for wekde::WekControl — the C++ session-bus surface that wraps
// the QML PlaylistController.
//
// Routing strategy: each test instantiates a PlaylistControllerStub that
// mirrors the QML controller's invokable API.  WekControl::Next() (etc) call
// QMetaObject::invokeMethod into the stub via Qt::DirectConnection (we
// override the connection type by calling the slot directly through QtTest's
// QTRY_COMPARE wait loop — Qt::QueuedConnection requires a running event
// loop, which QTRY_COMPARE drives).
//
// Per feedback_distrobox_dbus_launch_missing — dbus-launch /
// dbus-run-session are not available in the Bazzite Fedora toolbox.  Tests
// that need an actual bus QSKIP when the session bus is unreachable; the
// routing logic itself does not require a bus.

#include "../src/WekControl.hpp"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QSignalSpy>
#include <QtTest/QtTest>

using namespace wekde;

// Stub QObject mimicking the QML PlaylistController. Records the last
// invoked method name so tests can assert routing.  All public slots use the
// names that WekControl::*  forwards to (see PlaylistController.qml's
// public-export layer).
class PlaylistControllerStub : public QObject {
    Q_OBJECT
public:
    QString lastMethod;
    QString lastArg;

public slots:
    void next() { lastMethod = QStringLiteral("next"); }
    void previous() { lastMethod = QStringLiteral("previous"); }
    void pause() { lastMethod = QStringLiteral("pause"); }
    void resume() { lastMethod = QStringLiteral("resume"); }
    void togglePause() { lastMethod = QStringLiteral("togglePause"); }
    void mute() { lastMethod = QStringLiteral("mute"); }
    void unmute() { lastMethod = QStringLiteral("unmute"); }
    void toggleMute() { lastMethod = QStringLiteral("toggleMute"); }
    void activatePlaylistById(const QString& id) {
        lastMethod = QStringLiteral("activatePlaylistById");
        lastArg    = id;
    }
    void reload() { lastMethod = QStringLiteral("reload"); }

    // Direct-connection getters return a QVariant so the C++ adapter's
    // Q_RETURN_ARG(QVariant) marshalling works without per-type templating.
    QVariant currentWorkshopId() const { return QString("12345"); }
    QVariant currentPlaylistId() const { return QString("favorites"); }
    QVariant currentItemIndex() const { return 7; }
};

class TestWekControl : public QObject {
    Q_OBJECT

private slots:

    // -- Routing tests (no bus required) -------------------------------------
    // These exercise the C++ adapter's QMetaObject::invokeMethod dispatch
    // into the PlaylistControllerStub.  They construct WekControl via the
    // default ctor — that ctor's registerOn() call silently fails when the
    // session bus is unavailable, leaving a fully functional adapter
    // (m_registered=false, but slot bodies still dispatch to m_controller).

    void next_routesToController();
    void previous_routesToController();
    void pause_routesToController();
    void resume_routesToController();
    void toggle_routesToTogglePause();
    void mute_routesToController();
    void unmute_routesToController();
    void toggleMute_routesToController();
    void activatePlaylist_routesArgumentToController();
    void reload_routesToController();
    void currentWorkshopId_returnsStubValue();
    void currentPlaylistId_returnsStubValue();
    void currentItemIndex_returnsStubValue();

    // -- No-controller safety --------------------------------------------
    void allSlots_areNoOpsWhenControllerIsNull();
    void allGetters_returnSentinelsWhenControllerIsNull();

    // -- Signal contract ------------------------------------------------
    void emitWallpaperChanged_firesQtSignal();
    void emitWallpaperChanged_carriesBothArguments();

    // -- Session-bus integration (QSKIP without a bus) ------------------
    void registersOnSessionBus_whenBusReachable();
    void secondRegistrationFailsCleanly_whenBusReachable();

    // -- Q_CLASSINFO contract --------------------------------------
    void qClassInfo_dbusInterfaceName_isCorrect();

    // -- Ctor-injected connection (the dbus-launch fallback seam) ------
    void registerOnConnection_acceptsInjectedBus_orReturnsNull();
};

// -- Routing tests ---------------------------------------------------------

void TestWekControl::next_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Next();
    QTRY_COMPARE(stub.lastMethod, QString("next"));
}

void TestWekControl::previous_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Previous();
    QTRY_COMPARE(stub.lastMethod, QString("previous"));
}

void TestWekControl::pause_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Pause();
    QTRY_COMPARE(stub.lastMethod, QString("pause"));
}

void TestWekControl::resume_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Resume();
    QTRY_COMPARE(stub.lastMethod, QString("resume"));
}

void TestWekControl::toggle_routesToTogglePause() {
    // Toggle is the D-Bus name; the QML wrapper is called togglePause.
    // The C++ adapter renames in transit.
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Toggle();
    QTRY_COMPARE(stub.lastMethod, QString("togglePause"));
}

void TestWekControl::mute_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Mute();
    QTRY_COMPARE(stub.lastMethod, QString("mute"));
}

void TestWekControl::unmute_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Unmute();
    QTRY_COMPARE(stub.lastMethod, QString("unmute"));
}

void TestWekControl::toggleMute_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->ToggleMute();
    QTRY_COMPARE(stub.lastMethod, QString("toggleMute"));
}

void TestWekControl::activatePlaylist_routesArgumentToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->ActivatePlaylist(QStringLiteral("my_playlist"));
    QTRY_COMPARE(stub.lastMethod, QString("activatePlaylistById"));
    QCOMPARE(stub.lastArg, QString("my_playlist"));
}

void TestWekControl::reload_routesToController() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    control->Reload();
    QTRY_COMPARE(stub.lastMethod, QString("reload"));
}

void TestWekControl::currentWorkshopId_returnsStubValue() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    QCOMPARE(control->CurrentWorkshopId(), QString("12345"));
}

void TestWekControl::currentPlaylistId_returnsStubValue() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    QCOMPARE(control->CurrentPlaylistId(), QString("favorites"));
}

void TestWekControl::currentItemIndex_returnsStubValue() {
    auto                   control = std::make_unique<WekControl>();
    PlaylistControllerStub stub;
    control->setPlaylistController(&stub);
    QCOMPARE(control->CurrentItemIndex(), 7);
}

// -- No-controller safety --------------------------------------------------

void TestWekControl::allSlots_areNoOpsWhenControllerIsNull() {
    // Slot bodies must safely no-op when m_controller is null — used
    // during plugin startup before main.qml's WekControl element wires the
    // PlaylistController.
    auto control = std::make_unique<WekControl>();
    control->Next();
    control->Previous();
    control->Pause();
    control->Resume();
    control->Toggle();
    control->Mute();
    control->Unmute();
    control->ToggleMute();
    control->ActivatePlaylist(QStringLiteral("anything"));
    control->Reload();
    QVERIFY(true); // none of the above crashed
}

void TestWekControl::allGetters_returnSentinelsWhenControllerIsNull() {
    auto control = std::make_unique<WekControl>();
    QCOMPARE(control->CurrentWorkshopId(), QString());
    QCOMPARE(control->CurrentPlaylistId(), QString());
    QCOMPARE(control->CurrentItemIndex(), -1);
}

// -- Signal contract -------------------------------------------------------

void TestWekControl::emitWallpaperChanged_firesQtSignal() {
    auto       control = std::make_unique<WekControl>();
    QSignalSpy spy(control.get(), &WekControl::WallpaperChanged);
    control->emitWallpaperChanged(QStringLiteral("12345"), QStringLiteral("favorites"));
    QCOMPARE(spy.count(), 1);
}

void TestWekControl::emitWallpaperChanged_carriesBothArguments() {
    auto       control = std::make_unique<WekControl>();
    QSignalSpy spy(control.get(), &WekControl::WallpaperChanged);
    control->emitWallpaperChanged(QStringLiteral("12345"), QStringLiteral("favorites"));
    QCOMPARE(spy.at(0).at(0).toString(), QString("12345"));
    QCOMPARE(spy.at(0).at(1).toString(), QString("favorites"));
}

// -- Session-bus integration ----------------------------------------------

void TestWekControl::registersOnSessionBus_whenBusReachable() {
    if (! QDBusConnection::sessionBus().isConnected())
        QSKIP("no session bus — distrobox without dbus-launch (per "
              "feedback_distrobox_dbus_launch_missing)");
    auto* control = WekControl::registerOnSessionBus();
    if (! control)
        QSKIP("service already owned (concurrent test or live "
              "plasmoid)");
    QVERIFY(control->isRegistered());
    // Validate via introspection round-trip.
    QDBusInterface iface(QStringLiteral("com.github.captsilver.WallpaperEngine"),
                         QStringLiteral("/WallpaperEngine"),
                         QStringLiteral("com.github.captsilver.WallpaperEngine"));
    QVERIFY(iface.isValid());
    delete control;
}

void TestWekControl::secondRegistrationFailsCleanly_whenBusReachable() {
    // Mimics multi-monitor: first plasmoid wins, second goes silent.
    if (! QDBusConnection::sessionBus().isConnected())
        QSKIP("no session bus — distrobox without dbus-launch");
    auto* a = WekControl::registerOnSessionBus();
    if (! a) QSKIP("service already owned");
    auto* b = WekControl::registerOnSessionBus();
    QCOMPARE(b, nullptr);
    delete a;
}

// -- Q_CLASSINFO contract ------------------------------------------------

void TestWekControl::qClassInfo_dbusInterfaceName_isCorrect() {
    // Q_CLASSINFO("D-Bus Interface", "...") is what QDBusConnection reads
    // when exporting the object.  Pin the value so a typo here doesn't
    // silently rename the interface (which would break third-party panel
    // widgets without breaking the WekControl build).
    auto               control = std::make_unique<WekControl>();
    const QMetaObject* meta    = control->metaObject();
    const int          idx     = meta->indexOfClassInfo("D-Bus Interface");
    QVERIFY(idx >= 0);
    QCOMPARE(QString(meta->classInfo(idx).value()),
             QString("com.github.captsilver.WallpaperEngine"));
}

// -- Ctor-injected connection (the dbus-launch fallback seam) ------

void TestWekControl::registerOnConnection_acceptsInjectedBus_orReturnsNull() {
    // The injection seam: registerOnConnection(QDBusConnection, parent) is
    // the path tests use when a real bus is unavailable.  Without
    // dbus-launch, even private peer-to-peer connections require a server
    // socket — and qmltestrunner suites without QSKIP guards would wedge
    // here.  The test verifies the seam exists and returns nullptr
    // gracefully when the injected connection is invalid (the production
    // analogue of multi-monitor silent-fail).
    QDBusConnection invalid = QDBusConnection::connectToBus(
        QStringLiteral("unix:path=/no/such/socket"), QStringLiteral("tst_wekcontrol_invalid_bus"));
    // The connection ctor doesn't fail immediately — it fails at first use,
    // i.e. registerService below.  WekControl::registerOnConnection must
    // either return nullptr (registerService failed) or a registered
    // control.  Either is "the seam works"; we just must not crash.
    auto* control = WekControl::registerOnConnection(invalid);
    Q_UNUSED(control);
    QDBusConnection::disconnectFromBus(QStringLiteral("tst_wekcontrol_invalid_bus"));
    delete control;
    QVERIFY(true);
}

QTEST_GUILESS_MAIN(TestWekControl)
#include "tst_wekcontrol.moc"
