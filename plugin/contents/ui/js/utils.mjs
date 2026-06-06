/*
export function readTextFile(fileUrl) {
    return new Promise(function (resolve, reject) {
        const request = new XMLHttpRequest;
		// Setup listener
		request.onreadystatechange = function () {
			if (request.readyState !== XMLHttpRequest.DONE) return;

			// Process the response
			if (request.status >= 200 && request.status < 300) {
				// If successful
				resolve(request);
			} else {
				// If failed
				reject(`failed load file(${request.status}): ${fileUrl}`);
			}

		};
        request.open("GET", fileUrl);
		request.send();
	});
}
*/

export function parseJson(str) {
    if (!str) return null;
    let obj_j;
    try {
        obj_j = JSON.parse(str);
    } catch (e) {
        if (e instanceof SyntaxError) {
            console.error(e.message);
            obj_j = null;
        } else {
          throw e;  // re-throw the error unchanged
        }
    }
    return obj_j;
}

export function basename(path) {
    return path.split('/').reverse()[0];
}

export function dirname(path) {
    return path.substring(0, path.lastIndexOf("/"));
}

export function trimCharR(str, c) {
    let pos = 0;
    while(str.slice(pos - 1, str.length + pos) === c) {
        pos -= 1;
    }
    return str.slice(0, str.length + pos);
}


export function strToIntArray(str) {
    return [...str].map((e) => e.charCodeAt(0) - '0'.charCodeAt(0));
}
export function intArrayToStr(arr) {
    return arr.reduce((acc, e) => acc + e.toString(), "");
}

// Converts a wallpaper user-property `text` field into a human-readable
// label, with fallback to the property `key`.
//   • `ui_browse_properties_foo_bar` → "Foo Bar" (WE localization keys)
//   • "<b>Cool prop</b>" → "Cool prop" (HTML strips, whitespace collapses)
//   • empty / whitespace-only / falsy → returns `key`
// Pulled out of WallpaperPage.qml so it can be unit-tested directly —
// the underscore-split + regex are easy mutation targets.
export function formatPropertyLabel(text, key) {
    if (!text) return key;
    if (text.startsWith('ui_browse_properties_')) {
        const suffix = text.replace('ui_browse_properties_', '');
        return suffix.split('_').map(w =>
            w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
        ).join(' ');
    }
    let cleaned = text.replace(/<[^>]*>/g, ' ');
    cleaned = cleaned.replace(/\s+/g, ' ').trim();
    return cleaned || key;
}

const BYTE_UNITS = [
	'B',
	'kB',
	'MB',
	'GB',
	'TB',
	'PB',
	'EB',
	'ZB',
	'YB',
];

export function prettyBytes(number, maxFrac=0) {
    const UNITS = BYTE_UNITS;
    const abs = Math.abs(number);
    const exponent = abs < 1
        ? 0
        : Math.min(Math.floor(Math.log(abs) / Math.log(1024)), UNITS.length - 1);
    const unit = UNITS[exponent];
    const prefix = number < 0 ? '-' : '';

    const num_str = (abs / 1024 ** exponent).toFixed(maxFrac);
    return `${prefix}${num_str} ${unit}`;
}

// Map a Wallpaper Engine file-property `fileType` value to a Qt FileDialog
// `nameFilters` array.  WE uses small lowercase tokens ("video", "image",
// "sound"); unknown / missing values fall through to all-files so the user
// is never blocked from picking arbitrary content.  Returned filters are
// permissive ("All files (*)" always present) since WE wallpapers often
// accept formats outside the obvious extension list (e.g. .mov for video).
export function fileTypeNameFilters(fileType) {
    const ft = (typeof fileType === 'string') ? fileType.toLowerCase() : '';
    switch (ft) {
        case 'video':
            return ['Video files (*.webm *.mp4 *.mkv *.avi *.mov *.m4v)',
                    'All files (*)'];
        case 'image':
            return ['Image files (*.png *.jpg *.jpeg *.gif *.bmp *.webp *.tga)',
                    'All files (*)'];
        case 'sound':
        case 'audio':
            return ['Audio files (*.ogg *.mp3 *.wav *.flac *.opus *.m4a)',
                    'All files (*)'];
        default:
            return ['All files (*)'];
    }
}

// Whether a wallpaper should show the "Updated since you last loaded it" dot.
// `manifestTs` is the Steam Workshop timeupdated; `seenVersion` is the
// last_seen_version recorded when the wallpaper was last loaded (0 = never
// loaded / never recorded). Badge only wallpapers the user has actually loaded
// before AND that Steam has updated since — a never-loaded wallpaper has no
// "last load" to be newer than, so it must NOT badge, or the whole subscribed
// library lights up. Extracted from WallpaperListModel.loadItemFromJson so the
// comparison is unit-testable.
export function badgeUpdated(manifestTs, seenVersion) {
    return seenVersion > 0 && manifestTs > seenVersion;
}

