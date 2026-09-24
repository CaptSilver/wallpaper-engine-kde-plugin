#include "ThumbnailGrabber.hpp"
#include "ThumbnailGrabberOptions.hpp"
#include <QDebug>
#include <QFileInfo>
#include <mpv/client.h>

namespace wekde
{

bool applyMpvOption(mpv_handle* mpv, const char* name, const char* value) {
    const int rc = mpv_set_option_string(mpv, name, value);
    if (rc < 0) {
        qWarning() << "ThumbnailGrabber: failed to set mpv option" << name << "=" << value << "("
                   << mpv_error_string(rc) << ")";
    }
    return rc >= 0;
}

struct ThumbnailGrabber::Impl {
    mpv_handle* mpv { nullptr };

    Impl() {
        // libmpv requires LC_NUMERIC=C — pinned process-wide at plugin
        // startup in plugin.cpp's registerTypes (idempotent and held for the
        // plasmashell lifetime).  Re-applying here would mutate process-global
        // locale state from a QThreadPool worker, which is UB by the C
        // standard (std::setlocale is not thread-safe) even though glibc
        // appears stable in practice.
        mpv = mpv_create();
        if (! mpv) {
            qCritical() << "ThumbnailGrabber: mpv_create() returned null "
                           "— video thumbnail subsystem disabled";
            return;
        }
        // Log-and-continue on a bad option: matches mpv_initialize() failure
        // below, which degrades gracefully rather than crashing the grabber.
        applyMpvOption(mpv, "vo", "null");
        applyMpvOption(mpv, "ao", "null");
        applyMpvOption(mpv, "audio", "no");
        applyMpvOption(mpv, "hwdec", "no");
        applyMpvOption(mpv, "input-default-bindings", "no");
        applyMpvOption(mpv, "input-vo-keyboard", "no");
        applyMpvOption(mpv, "screenshot-format", "jpg");
        applyMpvOption(mpv, "screenshot-jpeg-quality", "80");
        if (mpv_initialize(mpv) < 0) {
            qCritical() << "ThumbnailGrabber: mpv_initialize() failed "
                           "— video thumbnail subsystem disabled";
            mpv_destroy(mpv);
            mpv = nullptr;
        }
    }
    ~Impl() {
        if (mpv) mpv_terminate_destroy(mpv);
    }
};

ThumbnailGrabber::ThumbnailGrabber(): d(std::make_unique<Impl>()) {}
ThumbnailGrabber::~ThumbnailGrabber() = default;

bool ThumbnailGrabber::grab(const QString& videoPath, const QString& outPath, double atSeconds) {
    if (! d->mpv) {
        qWarning() << "ThumbnailGrabber: mpv handle is null (ctor failed?) for" << videoPath;
        return false;
    }
    if (! QFileInfo::exists(videoPath)) {
        qWarning() << "ThumbnailGrabber: source file does not exist:" << videoPath;
        return false;
    }

    const QByteArray vp = videoPath.toUtf8();
    const QByteArray op = outPath.toUtf8();
    const QByteArray ts = QByteArray::number(atSeconds, 'f', 3);

    const char* loadcmd[] = { "loadfile", vp.constData(), "replace", nullptr };
    if (mpv_command(d->mpv, loadcmd) < 0) {
        qWarning() << "ThumbnailGrabber: loadfile mpv_command failed for" << videoPath;
        return false;
    }

    // Wait for file load (5 second budget).
    bool loaded = false;
    for (int i = 0; i < 50 && ! loaded; i++) {
        mpv_event* ev = mpv_wait_event(d->mpv, 0.1);
        if (ev->event_id == MPV_EVENT_FILE_LOADED)
            loaded = true;
        else if (ev->event_id == MPV_EVENT_END_FILE) {
            qWarning() << "ThumbnailGrabber: END_FILE during load "
                          "(unreadable codec/container?) for"
                       << videoPath;
            return false;
        }
    }
    if (! loaded) {
        qWarning() << "ThumbnailGrabber: load timeout (>5s) for" << videoPath;
        return false;
    }

    const char* seekcmd[] = { "seek", ts.constData(), "absolute", "exact", nullptr };
    if (mpv_command(d->mpv, seekcmd) < 0) {
        qWarning() << "ThumbnailGrabber: seek mpv_command failed for" << videoPath
                   << "at t=" << atSeconds;
        return false;
    }

    // Wait for seek to complete.
    bool seeked = false;
    for (int i = 0; i < 50 && ! seeked; i++) {
        mpv_event* ev = mpv_wait_event(d->mpv, 0.1);
        if (ev->event_id == MPV_EVENT_PLAYBACK_RESTART)
            seeked = true;
        else if (ev->event_id == MPV_EVENT_END_FILE) {
            qWarning() << "ThumbnailGrabber: END_FILE during seek for" << videoPath;
            return false;
        }
    }
    // Seek timed out without a PLAYBACK_RESTART — bail rather than screenshot a
    // wrong-position (typically t=0) frame and falsely report success.
    if (! seeked) {
        qWarning() << "ThumbnailGrabber: seek timeout (>5s, no PLAYBACK_RESTART) for" << videoPath;
        return false;
    }

    const char* shotcmd[] = { "screenshot-to-file", op.constData(), "video", nullptr };
    if (mpv_command(d->mpv, shotcmd) < 0) {
        qWarning() << "ThumbnailGrabber: screenshot-to-file mpv_command failed for" << videoPath
                   << "->" << outPath;
        return false;
    }

    const bool ok = QFileInfo::exists(outPath) && QFileInfo(outPath).size() > 0;
    if (! ok) {
        qWarning() << "ThumbnailGrabber: screenshot file missing or zero-size for" << videoPath
                   << "->" << outPath;
    }
    return ok;
}

} // namespace wekde
