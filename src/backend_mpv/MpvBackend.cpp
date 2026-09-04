#include "MpvBackend.hpp"

#include <QtGlobal>
#include <QtCore/QObject>
#include <QtCore/QDir>
#include <QtCore/QThread>

#include <QtGui/QGuiApplication>
#include <QtGui/QOpenGLContext>
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
#    include <QtOpenGL/QOpenGLFramebufferObject>
#else
#    include <QtGui/QOpenGLFramebufferObject>
#endif
#include <QtGui/QOpenGLFunctions>
#include <QtQuick/QQuickWindow>
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
#    include <QtQuick/QQuickOpenGLUtils>
#endif

#include <QtGui/QOffscreenSurface>
#include <QtQuick/QSGSimpleTextureNode>
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
#    include <QSGTexture>
#endif

#include <clocale>
#include <array>
#include <cstdlib>
#include <functional>
#include <memory>
#include <qobjectdefs.h>
#include <sys/stat.h>

#if defined(__linux__) || defined(__FreeBSD__)
// #ifdef ENABLE_X11
#    if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
#        include <QX11Info> // IWYU pragma: keep
#    elif (QT_VERSION < QT_VERSION_CHECK(6, 5, 0))
// Qt 6.0-6.4: use platformNativeInterface for X11 (6.0-6.1) and Wayland (6.0-6.4)
#        include <qpa/qplatformnativeinterface.h>
#    endif
// #endif
#endif

Q_LOGGING_CATEGORY(wekdeMpv, "wekde.mpv")

#define _Q_DEBUG() qCDebug(wekdeMpv)

using namespace mpv;

/// some api tips
/*
 * Assumes the OpenGL context lives on a certain thread
 * All mpv_render_* APIs have to be assumed to implicitly use the OpenGL context, if you pass a
 * mpv_render_context using the OpenGL backend
 *
 */

namespace
{
[[maybe_unused]] void on_mpv_events(void* ctx) { Q_UNUSED(ctx) }

void on_mpv_redraw(void* ctx);

void* get_proc_address_mpv(void* ctx, const char* name) {
    Q_UNUSED(ctx)

    QOpenGLContext* glctx = QOpenGLContext::currentContext();
    if (! glctx) return nullptr;

    return reinterpret_cast<void*>(glctx->getProcAddress(QByteArray(name)));
}

int CreateMpvContex(mpv_handle* mpv, mpv_render_context** mpv_gl) {
    mpv_opengl_init_params gl_init_params { get_proc_address_mpv, nullptr };
    mpv_render_param       params[] { { MPV_RENDER_PARAM_API_TYPE,
                                        const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL) },
                                      { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params },
                                      { MPV_RENDER_PARAM_INVALID, nullptr },
                                      { MPV_RENDER_PARAM_INVALID, nullptr } };

#if defined(__linux__) || defined(__FreeBSD__)
    if (QGuiApplication::platformName().contains("xcb")) {
        params[2].type = MPV_RENDER_PARAM_X11_DISPLAY;
#    if (QT_VERSION >= QT_VERSION_CHECK(6, 2, 0))
        if (auto* x11App = qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
            params[2].data = x11App->display();
        }
#    elif (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
        auto* native   = QGuiApplication::platformNativeInterface();
        params[2].data = native->nativeResourceForWindow("display", nullptr);
#    else
        params[2].data = QX11Info::display();
#    endif
    }
    if (QGuiApplication::platformName().contains("wayland")) {
        params[2].type = MPV_RENDER_PARAM_WL_DISPLAY;
#    if (QT_VERSION >= QT_VERSION_CHECK(6, 5, 0))
        if (auto* waylandApp = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>()) {
            params[2].data = waylandApp->display();
        }
#    else
        auto* native   = QGuiApplication::platformNativeInterface();
        params[2].data = native->nativeResourceForWindow("display", nullptr);
#    endif
    }
#endif
    int code = mpv_render_context_create(mpv_gl, mpv, params);
    return code;
}

[[maybe_unused]] QSGTexture* createTextureFromGl(uint32_t handle, QSize size,
                                                 QQuickWindow* window) {
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
    return QNativeInterface::QSGOpenGLTexture::fromNative(handle, window, size);
#elif (QT_VERSION >= QT_VERSION_CHECK(5, 14, 0))
    return window->createTextureFromNativeObject(
        QQuickWindow::NativeObjectTexture, &handle, 0, size);
#else
    return window->createTextureFromId(handle, size);
#endif
}

} // namespace

bool MpvObject::command(const QVariant& params) {
    if (! m_mpv) {
        qWarning() << "MpvObject::command on uninitialized mpv (video backend unavailable)";
        return false;
    }
    int errorCode = mpv::qt::get_error(mpv::qt::command(m_mpv, params));
    return (errorCode >= 0);
}

bool MpvObject::setProperty(const QString& name, const QVariant& value) {
    if (! m_mpv) {
        qWarning() << "MpvObject::setProperty on uninitialized mpv:" << name;
        return false;
    }
    int errorCode = mpv::qt::get_error(mpv::qt::set_property(m_mpv, name, value));
    _Q_DEBUG() << "Setting property" << name << "to" << value;
    return (errorCode >= 0);
}

QVariant MpvObject::getProperty(const QString& name, bool* ok) const {
    auto* mpv = m_mpv;
    if (ok) *ok = false;

    if (! mpv) {
        qWarning() << "MpvObject::getProperty on uninitialized mpv:" << name;
        return QVariant();
    }
    if (name.isEmpty()) {
        return QVariant();
    }
    QVariant  result    = mpv::qt::get_property(mpv, name);
    const int errorCode = mpv::qt::get_error(result);
    if (errorCode >= 0) {
        if (ok) {
            *ok = true;
        }
    } else {
        _Q_DEBUG() << "Failed to query property: " << name << "code" << errorCode << " result"
                   << result;
    }
    return result;
}

void MpvObject::initCallback() {
    QUrl temp(m_source.toString());
    m_source.clear();
    inited = true;
    setSource(temp);
    Q_EMIT initFinished();
}

void MpvObject::play() {
    if (status() != Paused) return;
    this->setProperty("pause", false);
}

void MpvObject::pause() {
    if (status() != Playing) return;
    this->setProperty("pause", true);
}

void MpvObject::stop() {
    if (status() == Stopped) return;
    bool result = this->command(QVariantList { "stop" });
    if (result) {
        m_source.clear();
        Q_EMIT sourceChanged();
    }
}

MpvObject::Status MpvObject::deriveStatus(bool idleActive, bool paused) {
    return idleActive ? Stopped : (paused ? Paused : Playing);
}

MpvObject::Status MpvObject::liveStatus() const {
    return deriveStatus(getProperty("idle-active").toBool(), getProperty("pause").toBool());
}

bool MpvObject::refreshStatus(bool idleActive, bool paused) {
    const Status now = deriveStatus(idleActive, paused);
    if (now == m_lastStatus) return false;
    m_lastStatus = now;
    _Q_DEBUG() << "status ->" << now;
    Q_EMIT statusChanged();
    return true;
}

// mpv surfaces pause/idle-active changes through its event queue after
// mpv_observe_property; wakeup() posts this drain to the GUI thread.
void MpvObject::onMpvEvents() {
    if (! m_mpv) return;
    while (true) {
        mpv_event* ev = mpv_wait_event(m_mpv, 0); // non-blocking
        if (ev->event_id == MPV_EVENT_NONE) break;
        if (ev->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            refreshStatus(getProperty("idle-active").toBool(), getProperty("pause").toBool());
        } else if (ev->event_id == MPV_EVENT_END_FILE) {
            // mpv signals demuxer/decoder failures via END_FILE with
            // reason=ERROR; other reasons (EOF on a non-looping source,
            // STOP, REDIRECT, QUIT) are informational, not failures.
            // loop=inf is set in the ctor so EOF should never reach here
            // in practice, but the filter keeps the signal honest if a
            // future option-set unsets loop.
            auto* d = static_cast<mpv_event_end_file*>(ev->data);
            if (d && d->reason == MPV_END_FILE_REASON_ERROR) {
                const char* msg = mpv_error_string(d->error);
                _Q_DEBUG() << "END_FILE reason=ERROR error=" << d->error
                           << "msg=" << (msg ? msg : "<null>");
                Q_EMIT sourceLoadFailed(QString::fromUtf8(msg ? msg : "unknown mpv error"));
            }
        }
    }
}

void MpvObject::wakeup(void* ctx) {
    // Runs on an arbitrary mpv thread — must not touch the MpvObject
    // identity directly. The ctx is the (shared_ptr-owned) MpvHandle, which
    // outlives any single MpvObject via MpvRender's ref. ~MpvObject clears
    // owner under wakeup_mutex; the lock here ensures that after that clear
    // returns, no future wakeup can dispatch into the dead QObject.
    auto*        mh = static_cast<MpvHandle*>(ctx);
    QMutexLocker lock(&mh->wakeup_mutex);
    if (! mh->owner) return;
    QMetaObject::invokeMethod(mh->owner, "onMpvEvents", Qt::QueuedConnection);
}

QUrl MpvObject::source() const { return m_source; }

bool MpvObject::mute() const {
    QVariant aid = getProperty("aid");
    // mpv reports `aid` as either a string ("auto", "no", "1", …) or
    // as a boolean flag (FORMAT_FLAG) once the value has settled —
    // qthelper unwraps the flag to a bool QVariant. Accept either form.
    if (aid.typeId() == QMetaType::Bool) return ! aid.toBool();
    return aid.toString() == QLatin1String("no");
}

QString MpvObject::logfile() const { return getProperty("log-file").toString(); }

int MpvObject::volume() const { return getProperty("volume").toInt(); }

void MpvObject::setMute(const bool& mute) {
    // aid is the audio track ID, "no" means no audio track
    setProperty("aid", mute ? "no" : "auto");
    emit muteChanged();
}

void MpvObject::setVolume(const int& volume) {
    setProperty("volume", volume);
    emit volumeChanged();
}

void MpvObject::setLogfile(const QString& logfile) {
    setProperty("log-file", logfile);
    emit logfileChanged();
}

void MpvObject::setSource(const QUrl& source) {
    if (source.isEmpty()) {
        stop();
        return;
    }
    if (! source.isValid() || (source == m_source)) {
        return;
    }
    if (! inited) {
        m_source = source;
        return;
    }
    bool result = this->command(QVariantList {
        "loadfile",
        source.isLocalFile() ? QDir::toNativeSeparators(source.toLocalFile()) : source.url() });
    if (result) {
        m_source = source;
        Q_EMIT sourceChanged();

        m_first_frame.store(false);
    } else {
        // Diagnostic kept per debug-logging policy: the sync-reject path
        // is rare (mpv accepts almost any QUrl-derived path syntactically)
        // so the LOG is load-bearing for future investigation.
        _Q_DEBUG() << "loadfile rejected for" << source;
        Q_EMIT sourceLoadFailed(
            QStringLiteral("libmpv rejected loadfile for %1").arg(source.toString()));
    }
}

namespace mpv
{

class MpvRender : public QObject, public QQuickFramebufferObject::Renderer {
    Q_OBJECT
public:
    MpvRender(std::shared_ptr<MpvHandle> mpv, QQuickWindow* win)
        // Match member declaration order (m_mpv, m_window, m_shared_mpv) to
        // silence -Wreorder-ctor; all three read the `mpv`/`win` params, not
        // each other, so the order is behaviourally identical.
        : m_mpv(mpv.get()->handle), m_window(win), m_shared_mpv(mpv) {}

    // Runs on the Qt Quick render thread, from cleanupNodes() with the GUI
    // thread blocked in polishAndSync — so anything that waits on the mpv core
    // here freezes every window plasmashell owns. render.h only permits the
    // _async APIs on a render thread and warns that a render thread waiting on
    // the core deadlocks until mpv breaks it with an internal timeout. Freeing
    // the context is the one thing that MUST happen here (it needs the GL
    // context current, and render.h requires it before the core is destroyed);
    // that free already disables video, and ~MpvHandle quits the player, so
    // there is nothing left for this thread to ask the core to do.
    virtual ~MpvRender() {
        _Q_DEBUG() << "destroyed";
        if (m_mpv_context) mpv_render_context_free(m_mpv_context);
        m_mpv_context = nullptr;
    }

    bool Dirty() const { return m_dirty.load(); }
    bool setDirty(bool v) { return m_dirty.exchange(v); };

signals:
    void mpvRedraw();
    void inited();

public slots:
    // render thread
    void renderFrame(QOpenGLFramebufferObject* fbo) {
        mpv_opengl_fbo mpfbo { .fbo             = static_cast<int>(fbo->handle()),
                               .w               = fbo->width(),
                               .h               = fbo->height(),
                               .internal_format = 0 };
        int            flip_y { 0 };

        mpv_render_param params[] = {
            { MPV_RENDER_PARAM_OPENGL_FBO, &mpfbo },
            // Flip rendering (needed due to flipped GL coordinate system).
            { MPV_RENDER_PARAM_FLIP_Y, &flip_y },
            { MPV_RENDER_PARAM_INVALID, nullptr }
        };
        mpv_render_context_render(m_mpv_context, params);
    }

    /*
     * This function is called when a new FBO is needed.
     * This happens on the initial frame.
     */
    QOpenGLFramebufferObject* createFramebufferObject(const QSize& size) override {
        return QQuickFramebufferObject::Renderer::createFramebufferObject(size);
    }

    /*
     * called as a result of QQuickFramebufferObject::update()
     * called once before the FBO is created
     * only place when it is safe for the renderer and the item to read and write each others
     * members
     */
    void synchronize(QQuickFramebufferObject* item) override {
        MpvObject* mpv_obj = static_cast<MpvObject*>(item);

        if (m_mpv_context == nullptr) {
            if (CreateMpvContex(m_mpv, &m_mpv_context) >= 0) {
                mpv_render_context_set_update_callback(m_mpv_context, on_mpv_redraw, this);
                Q_EMIT this->inited();
            }
        }

        if (Dirty()) {
            mpv_obj->checkAndEmitFirstFrame();
        }
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
        QQuickOpenGLUtils::resetOpenGLState();
#else
        m_window->resetOpenGLState();
#endif
    }

    void render() override {
        if (setDirty(false)) {
            QOpenGLFramebufferObject* fbo = framebufferObject();
            renderFrame(fbo);
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
            QQuickOpenGLUtils::resetOpenGLState();
#else
            m_window->resetOpenGLState();
#endif
        }
    }

private:
    mpv_render_context* m_mpv_context { nullptr };
    mpv_handle*         m_mpv { nullptr };
    // Only referenced by the Qt5 fallback codepath in render() / synchronize().
    // The project targets Qt6 / Plasma 6, so the field is unused under -Wall,
    // and -Werror would gate package builds.  Keep the field + the Qt5 branch
    // intact for upstream forks that still need them.
    [[maybe_unused]] QQuickWindow* m_window { nullptr };

    std::shared_ptr<MpvHandle> m_shared_mpv { nullptr };

    std::atomic<bool> m_dirty { false };
};

} // namespace mpv

namespace
{
void on_mpv_redraw(void* ctx) {
    auto* mpv = static_cast<mpv::MpvRender*>(ctx);
    mpv->setDirty(true);
    Q_EMIT mpv->mpvRedraw();
}
} // namespace

MpvObject::MpvObject(QQuickItem* parent)
    : QQuickFramebufferObject(parent), m_shared_mpv(std::make_shared<MpvHandle>(mpv_create())) {
    m_mpv = m_shared_mpv.get()->handle;

    if (! m_mpv) {
        qWarning() << "MpvObject: mpv_create() failed — video backend unavailable";
        return;
    }
    // All options must be set BEFORE mpv_initialize: post-init the option
    // surface becomes read-only and these calls would silently no-op.
    mpv_set_option_string(m_mpv, "terminal", "no");
    mpv_set_option_string(m_mpv, "config", "no");
    mpv_set_option_string(m_mpv, "vo", "libmpv");
    mpv_set_option_string(m_mpv, "hwdec", "auto"); // depends on vo being set

    // Wallpaper loops re-read from disk each cycle; the ~10MB demuxer cache
    // is pointless overhead vs. the OS page cache that handles sequential
    // re-reads better.
    mpv_set_option_string(m_mpv, "cache", "no");

    // Wallpapers have no audio path on the QML side — skip the decode
    // entirely.  Saves a few %CPU on AAC-tracked files.
    mpv_set_option_string(m_mpv, "audio", "no");

    // 1080p30 wallpapers need ~2 decode threads; mpv default (= CPU core
    // count) is wasteful and spawns idle threads on modern desktops.
    mpv_set_option_string(m_mpv, "vd-lavc-threads", "2");

    // Retime the video clock to the display refresh — smooths the loop
    // wrap and avoids judder on long-running wallpaper sessions.  The
    // default `audio` sync mode is wrong here (we have no audio path).
    mpv_set_option_string(m_mpv, "video-sync", "display-resample");

    // Modern per-file loop form.  `loop=inf` is the deprecated
    // playlist-loop alias that only worked because we never have a
    // playlist of more than one.
    mpv_set_option_string(m_mpv, "loop-file", "inf");

    // Default to warn so journald isn't flooded with mpv lifecycle prints
    // on shipping builds.  Env override `WEK_MPV_VERBOSE=1` restores info.
    const char* verbose = std::getenv("WEK_MPV_VERBOSE");
    mpv_set_option_string(
        m_mpv, "msg-level", (verbose && verbose[0] && verbose[0] != '0') ? "all=info" : "all=warn");

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "MpvObject: mpv_initialize() failed — video backend unavailable";
        return;
    }
    m_inited_ok = true;

    // Observe the properties that define Status and pump mpv's event queue so
    // statusChanged() actually fires — QML bindings on `status` depend on it.
    // The wakeup callback runs on an mpv thread; it only queues onMpvEvents().
    // Bootstrap m_lastStatus from a sync read; subsequent updates come via the
    // event-driven refreshStatus path so status() can stay pure-cache.
    m_lastStatus = liveStatus();
    mpv_observe_property(m_mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "idle-active", MPV_FORMAT_FLAG);
    {
        QMutexLocker lock(&m_shared_mpv->wakeup_mutex);
        m_shared_mpv->owner = this;
    }
    mpv_set_wakeup_callback(m_mpv, &MpvObject::wakeup, m_shared_mpv.get());

    Q_EMIT initializedChanged();
}

void MpvHandle::beginShutdown() {
    // Tell libmpv to stop calling our wakeup (best-effort: doesn't block any
    // in-flight callback). Then take the wakeup_mutex to serialise against
    // any callback currently dispatching; clearing owner under that lock
    // means no FUTURE wakeup can ever dispatch into the destroyed MpvObject.
    // The .so is dlopen'd into plasmashell — a dangling postEvent here
    // would crash the desktop.
    if (handle) mpv_set_wakeup_callback(handle, nullptr, nullptr);
    {
        QMutexLocker lock(&wakeup_mutex);
        owner = nullptr;
    }
    // mpv_create() can fail; there is no core to wind down then, and the ctor
    // has already warned that the video backend is unavailable.
    if (! handle) return;

    // Only the _async command variants are documented safe for a caller that
    // must not wait on the core; the quit is fire-and-forget, so whoever ends
    // up running mpv_terminate_destroy mostly finds the work already done.
    const char* quit_cmd[] = { "quit", nullptr };
    const int   rc         = mpv_command_async(handle, 0, quit_cmd);
    // UNINITIALIZED just means mpv_initialize() never ran or failed — again
    // already reported at construction, and nothing is running to quit.
    if (rc < 0 && rc != MPV_ERROR_UNINITIALIZED) {
        // Not fatal — ~MpvHandle still terminates the core — but it means the
        // teardown fell back to the blocking path, which is what a report of
        // "the desktop freezes when the wallpaper changes" would look like.
        qCWarning(wekdeMpv) << "async quit rejected:" << mpv_error_string(rc);
    }
}

MpvObject::~MpvObject() {
    if (m_shared_mpv) m_shared_mpv->beginShutdown();
}

void MpvObject::checkAndEmitFirstFrame() {
    // m_first_frame starts true; setSource flips it false on a successful
    // loadfile; the first render tick flips it back true and emits exactly
    // once.  exchange() makes the test-and-flip atomic so a self-racing
    // synchronize() can never emit twice (mirrors MpvRender::m_dirty.exchange).
    if (! m_first_frame.exchange(true)) {
        Q_EMIT firstFrame();
    }
}

QQuickFramebufferObject::Renderer* MpvObject::createRenderer() const {
#if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
    window()->setPersistentOpenGLContext(true);
#endif
    window()->setPersistentSceneGraph(true);

    auto* render = new MpvRender(m_shared_mpv, window());

    // Use Queued signal to update at gui thread
    connect(render, &MpvRender::mpvRedraw, this, &MpvObject::update, Qt::QueuedConnection);
    connect(render, &MpvRender::inited, this, &MpvObject::initCallback, Qt::QueuedConnection);
    return render;
}

#include "MpvBackend.moc"
