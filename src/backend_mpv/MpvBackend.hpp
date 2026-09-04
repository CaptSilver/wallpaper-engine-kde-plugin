#ifndef MPVRENDERER_H_
#define MPVRENDERER_H_

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickFramebufferObject>
#include <QtCore/QLoggingCategory>
#include <QtCore/QMutex>
#include <atomic>
#include <memory>

#include "qthelper.hpp"

Q_DECLARE_LOGGING_CATEGORY(wekdeMpv)

namespace mpv
{

class MpvObject;

struct MpvHandle {
    MpvHandle(mpv_handle* mpv): handle(mpv) {}
    ~MpvHandle() { mpv_terminate_destroy(handle); }
    mpv_handle* handle;

    // Start tearing the player down. Called on the GUI thread from ~MpvObject:
    // detaches the wakeup callback, then asks the core to quit *without*
    // waiting for it. The blocking half of the teardown, ~MpvHandle's
    // mpv_terminate_destroy, runs on the Qt Quick render thread — the renderer
    // holds the last shared_ptr ref and cleanupNodes deletes it there — while
    // the GUI thread sits in polishAndSync, so anything it waits for freezes
    // every window plasmashell owns, not just the wallpaper. Starting the quit
    // here lets the core wind down alongside the QML destroy() delay, and
    // client.h names this as *the* asynchronous-destruction path: run "quit",
    // then react to MPV_EVENT_SHUTDOWN.
    void beginShutdown();

    // Wakeup callback indirection. The callback runs on an arbitrary mpv
    // player thread; without this hop it would deref a destroyed MpvObject
    // (the .so is dlopen'd into plasmashell — a dangling postEvent would
    // crash the desktop). MpvHandle outlives any single MpvObject via the
    // MpvRender shared_ptr ref, so the mutex + owner pointer stay valid
    // until ~MpvHandle joins the player thread via mpv_terminate_destroy.
    QMutex     wakeup_mutex;
    MpvObject* owner { nullptr };
};

class MpvRender;

class MpvObject : public QQuickFramebufferObject {
    Q_OBJECT
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(Status status READ status NOTIFY statusChanged)
    Q_PROPERTY(bool mute READ mute WRITE setMute NOTIFY muteChanged)
    Q_PROPERTY(QString logfile READ logfile WRITE setLogfile NOTIFY logfileChanged)
    Q_PROPERTY(int volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool initialized READ initialized NOTIFY initializedChanged)

    friend class MpvRender;

public:
    // mpv's wakeup callback fires on an arbitrary player thread; it must only
    // marshal back to the GUI thread (queued), never touch QObject state direct.
    static void wakeup(void* ctx);

    explicit MpvObject(QQuickItem* parent = nullptr);
    virtual ~MpvObject();
    Renderer* createRenderer() const override;

    enum Status
    {
        Stopped,
        Playing,
        Paused,
    };
    Q_ENUM(Status)
    // Returns the cached status maintained by refreshStatus on observed mpv
    // property-change events. Inline + trivial so QML bindings that read
    // `status` reactively pay no sync mpv_get_property cost per evaluation.
    Status status() const { return m_lastStatus; }
    // Sync read from mpv (the historical status() body). Used at ctor time
    // to bootstrap m_lastStatus before the event-driven path takes over.
    Status liveStatus() const;
    // Pure mapping of mpv's (idle-active, pause) flags to a playback Status.
    static Status deriveStatus(bool idleActive, bool paused);
    // Re-derive from the given flags; emit statusChanged() iff the status
    // crossed a boundary vs the last seen value. Returns whether it changed.
    bool refreshStatus(bool idleActive, bool paused);
    // True only after mpv_create() AND mpv_initialize() both succeeded. QML reads
    // this to fall back instead of presenting a black void when mpv is unavailable.
    bool    initialized() const { return m_mpv != nullptr && m_inited_ok; }
    QUrl    source() const;
    bool    mute() const;
    QString logfile() const;
    int     volume() const;

    void setSource(const QUrl& source);
    void setMute(const bool& mute);
    void setLogfile(const QString& logfile);
    void setVolume(const int& volume);

public slots:
    void play();
    void pause();
    void stop();

    bool     command(const QVariant& params);
    bool     setProperty(const QString& name, const QVariant& value);
    QVariant getProperty(const QString& name, bool* ok = nullptr) const;
    void     initCallback();
    void     checkAndEmitFirstFrame();
    // GUI-thread drain of mpv's event queue (posted by wakeup()); emits
    // statusChanged() when an observed property moves the derived status.
    void onMpvEvents();

signals:
    void initFinished();
    void statusChanged();
    void initializedChanged();
    void sourceChanged();
    void firstFrame();
    // Surface mpv load failures so QML can react immediately instead of
    // waiting for the 15s watchdog. Two emit sites:
    //   - setSource(): when this->command(loadfile, ...) returns false
    //     (sync rejection by mpv's command parser).
    //   - onMpvEvents(): when mpv posts MPV_EVENT_END_FILE with
    //     reason == MPV_END_FILE_REASON_ERROR (async demux/decode failure).
    // The reason string is short English (mpv_error_string for the async
    // path; a literal diagnostic for the sync path), suitable for direct
    // display in the loadInfoShow pane.
    void sourceLoadFailed(const QString& reason);
    void muteChanged();
    void volumeChanged();
    void logfileChanged();

private:
    // Render context ready: set by the queued initCallback() after MpvRender emits
    // inited(); gates setSource()'s loadfile. Distinct from m_inited_ok (mpv_initialize).
    bool inited = false;
    QUrl m_source;
    // Last status surfaced via statusChanged(); the diff anchor so the signal
    // fires once per real transition rather than per observed-property event.
    Status m_lastStatus { Stopped };
    bool   m_inited_ok { false }; // set once mpv_initialize() succeeds

private:
    mpv_handle*                m_mpv { nullptr };
    std::shared_ptr<MpvHandle> m_shared_mpv { nullptr };
    // Written on the GUI thread (setSource) and read+written on the Qt Quick
    // render thread (checkAndEmitFirstFrame, via MpvRender::synchronize), so it
    // must be atomic.  Mirrors the sibling MpvRender::m_dirty atomic style.
    std::atomic<bool> m_first_frame { true };
};
} // namespace mpv

#endif
