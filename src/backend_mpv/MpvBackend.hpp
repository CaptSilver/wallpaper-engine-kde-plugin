#ifndef MPVRENDERER_H_
#define MPVRENDERER_H_

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickFramebufferObject>
#include <QtCore/QLoggingCategory>
#include <atomic>
#include <memory>

#include "qthelper.hpp"

Q_DECLARE_LOGGING_CATEGORY(wekdeMpv)

namespace mpv
{

struct MpvHandle {
    MpvHandle(mpv_handle* mpv): handle(mpv) {}
    ~MpvHandle() { mpv_terminate_destroy(handle); }
    mpv_handle* handle;
};

class MpvRender;

class MpvObject : public QQuickFramebufferObject {
    Q_OBJECT
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(Status status READ status NOTIFY statusChanged)
    Q_PROPERTY(bool mute READ mute WRITE setMute)
    Q_PROPERTY(QString logfile READ logfile WRITE setLogfile)
    Q_PROPERTY(int volume READ volume WRITE setVolume)
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
    Status status() const;
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

private:
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
