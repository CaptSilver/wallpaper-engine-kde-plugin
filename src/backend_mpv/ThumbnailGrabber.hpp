#pragma once
#include <QString>
#include <memory>

namespace wekde
{

// Headless libmpv frame grabber. Synchronous API — for async consumption use
// FileHelper::generateThumbnail which wraps this on a QThreadPool task.
class ThumbnailGrabber {
public:
    ThumbnailGrabber();
    ~ThumbnailGrabber();

    // Returns true on success; writes JPEG to outPath.
    bool grab(const QString& videoPath, const QString& outPath, double atSeconds);

private:
    struct Impl;
    std::unique_ptr<Impl> d;
};

} // namespace wekde
