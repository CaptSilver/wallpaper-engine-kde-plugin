// Pure layout helpers for the Scene backend's Keep-Aspect-Ratio letterboxing.
// Mirrors the SceneAspect.h C++ extraction: keep the decision pure and
// cross-runtime (QJSEngine + Node) so it is unit-testable without Vulkan or a
// Plasma WallpaperItem. backend/Scene.qml is a thin binding layer over these.

// Size the renderer item. Full-fill the parent unless we are in Keep-Aspect
// mode with a known (>0) native aspect ratio; then fit the wallpaper's native
// aspect inside the parent so the wrapper's backdrop Rectangle shows through
// the letterbox bars. Degenerate inputs fall back to full-fill (no NaN).
export function letterboxSize(isAspect, nativeAspectRatio, parentW, parentH) {
    if (!isAspect || nativeAspectRatio <= 0 || parentW <= 0 || parentH <= 0)
        return { width: parentW, height: parentH };
    return nativeAspectRatio > parentW / parentH
        ? { width: parentW, height: parentW / nativeAspectRatio }
        : { width: parentH * nativeAspectRatio, height: parentH };
}

// Choose the renderer fill mode so the renderer NEVER paints its own opaque
// bars in Keep-Aspect mode. When the native aspect is known the item is already
// sized to that aspect, so STRETCH fills it exactly (zero padding) and the bars
// are pure backdrop colour. Before the scene loads (aspect == 0) the item is
// full-screen, so ASPECTFIT degrades gracefully (no scene visible yet). Crop
// and Scale modes are unchanged. `modes` is { STRETCH, ASPECTFIT, ASPECTCROP }.
export function fillModeFor(isAspect, isCrop, nativeAspectRatio, modes) {
    if (!isAspect) return isCrop ? modes.ASPECTCROP : modes.STRETCH;
    if (nativeAspectRatio > 0) return modes.STRETCH;
    return modes.ASPECTFIT;
}
