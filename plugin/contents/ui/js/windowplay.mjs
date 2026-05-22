// Pure, cross-runtime (Node + QJSEngine) pause/play decision for WindowModel.
// Mirrors the layout.mjs extraction: keep the decision pure so it is
// unit-testable without a Plasma WindowModel / TasksModel / QQuickWindow, and
// so its equivalence to the previous multi-pass filter pipeline can be pinned.
// WindowModel.qml is a thin binding layer over this.

// Integer values MUST match Common.qml's PauseMode enum (declaration order).
export const PauseMode = Object.freeze({
    Never: 0, Any: 1, Max: 2, Focus: 3, FocusOrMax: 4, FullScreen: 5,
});

// One pass over `windows`. Each descriptor is a window that already passed the
// IsWindow + activity filters: { isMinimized, isMaximized, isFullScreen,
// isActive } (booleans). `mode` selects an early-out so we only inspect what a
// mode needs (Focus -> isActive only; Any -> notMin only). Returns the small
// count set the modes consume. max/full/active are conditioned on "not
// minimized", matching the previous code where maxWModel/fullSModel/activeModel
// were all derived from notMinWModel.
export function countWindows(windows, mode) {
    let notMin = 0, max = 0, full = 0, active = 0;
    for (let i = 0; i < windows.length; i++) {
        const w = windows[i];
        if (w.isMinimized === true) continue;   // matches IsMinimized:false filter
        notMin++;
        if (mode === PauseMode.Any) continue;    // Any needs only notMin
        if (w.isActive === true) active++;
        if (mode === PauseMode.Focus) continue;  // Focus needs only active
        if (w.isFullScreen === true) full++;
        if (w.isMaximized === true || w.isFullScreen === true) max++;
    }
    return { notMin, max, full, active };
}

// The play decision: returns true when the wallpaper should PLAY, exactly
// reproducing the previous switch (play iff no window satisfies the mode's
// predicate). Unknown modes play (the previous `default:` branch).
export function shouldPlay(windows, mode) {
    if (mode === PauseMode.Never) return true;
    const c = countWindows(windows, mode);
    switch (mode) {
    case PauseMode.Any:        return c.notMin === 0;
    case PauseMode.Max:        return c.max === 0;
    case PauseMode.Focus:      return c.active === 0;
    case PauseMode.FocusOrMax: return c.max === 0 && c.active === 0;
    case PauseMode.FullScreen: return c.full === 0;
    default:                   return true;
    }
}
