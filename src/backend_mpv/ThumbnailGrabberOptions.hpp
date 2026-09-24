#pragma once

struct mpv_handle;

namespace wekde
{

// Sets one mpv option, logging (naming the option) and returning false on
// failure instead of dropping the error the way mpv_set_option_string's bare
// return code invites. Free function so a test can drive it against a real
// mpv_handle without going through ThumbnailGrabber's private Impl.
bool applyMpvOption(mpv_handle* mpv, const char* name, const char* value);

} // namespace wekde
