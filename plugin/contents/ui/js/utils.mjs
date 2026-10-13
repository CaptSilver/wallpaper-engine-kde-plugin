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
    // U+3164 (HANGUL FILLER) is Unicode category Lo, not Zs, so \s doesn't
    // match it — WE authors use it as fake indentation in the property
    // editor, and it survives a plain \s+ collapse. Fold it in as whitespace.
    cleaned = cleaned.replace(/[\s\u3164]+/g, ' ').trim();
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
// is never blocked from picking arbitrary content.  "All files (*)" is
// always present since WE wallpapers often accept formats outside the
// obvious extension list.
//
// The video extensions are passed in (FileHelper.videoExtensions(), the list
// the Videos-tab scanner uses) so there is one copy; without a list the
// video case offers all-files only.  The image and audio lists below have no
// scanner anywhere to track, so they are plain literals.
export function fileTypeNameFilters(fileType, videoExtensions) {
    const ft = (typeof fileType === 'string') ? fileType.toLowerCase() : '';
    switch (ft) {
        case 'video':
            if (!videoExtensions || !(videoExtensions.length > 0))
                return ['All files (*)'];
            return ['Video files (' + Array.from(videoExtensions, e => '*.' + e).join(' ') + ')',
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

// project.json gates some properties on another property's live value, e.g.
// `"condition": "mediavisualizer.value == true"` on the Now Playing rows.
// WE's own editor runs these as real JS; we don't want an eval()/Function()
// sandbox for wallpaper-authored strings sitting in the settings UI, so this
// is a small hand-rolled tokenizer + recursive-descent parser over the
// operators the Workshop corpus actually uses (read from ~1081 real
// project.json files, not guessed): ==, !=, <, >, <=, >=, a bare `=` (a
// common author typo for `==`), &&, ||, unary !, parens, true/false/number/
// 'string' literals, and `name.value` property references. Authors are
// inconsistent about spacing ("a.value==1", "b.value &&c.value"), so the
// tokenizer skips whitespace between tokens rather than requiring it.
//
// A few real conditions aren't boolean expressions at all — one WE-editor
// trick (ab)uses `condition` to run a ternary that assigns to another
// property's own `.text`, purely to relabel it in the *WE* editor; others
// chain method calls like `.split('/')[0].includes('0')`. Both are outside
// this grammar on purpose: there's no safe way to run an assignment or an
// arbitrary method call without eval(). Any unparsed or leftover input
// fails OPEN (the row stays visible) rather than guess at hiding it.
function tokenizeCondition(text) {
    const tokens = [];
    let i = 0;
    const n = text.length;
    while (i < n) {
        const c = text[i];
        if (c === ' ' || c === '\t' || c === '\n' || c === '\r') { i++; continue; }
        if (c === '(' || c === ')') { tokens.push({ t: c }); i++; continue; }
        if (c === '.') { tokens.push({ t: '.' }); i++; continue; }
        if (c === '!') {
            if (text[i + 1] === '=') { tokens.push({ t: '!=' }); i += 2; }
            else { tokens.push({ t: '!' }); i++; }
            continue;
        }
        if (c === '=') {
            // '==' and a lone '=' (author typo) both mean equality here —
            // there's no assignment target that makes sense in a condition.
            if (text[i + 1] === '=') { tokens.push({ t: '==' }); i += 2; }
            else { tokens.push({ t: '==' }); i++; }
            continue;
        }
        if (c === '<') {
            if (text[i + 1] === '=') { tokens.push({ t: '<=' }); i += 2; }
            else { tokens.push({ t: '<' }); i++; }
            continue;
        }
        if (c === '>') {
            if (text[i + 1] === '=') { tokens.push({ t: '>=' }); i += 2; }
            else { tokens.push({ t: '>' }); i++; }
            continue;
        }
        if (c === '&' && text[i + 1] === '&') { tokens.push({ t: '&&' }); i += 2; continue; }
        if (c === '|' && text[i + 1] === '|') { tokens.push({ t: '||' }); i += 2; continue; }
        if (c === "'") {
            let j = i + 1;
            while (j < n && text[j] !== "'") j++;
            if (j >= n) return null; // unterminated string literal
            tokens.push({ t: 'str', v: text.slice(i + 1, j) });
            i = j + 1;
            continue;
        }
        if (c >= '0' && c <= '9') {
            let j = i + 1;
            while (j < n && ((text[j] >= '0' && text[j] <= '9') || text[j] === '.')) j++;
            tokens.push({ t: 'num', v: Number(text.slice(i, j)) });
            i = j;
            continue;
        }
        if (/[A-Za-z_]/.test(c)) {
            let j = i + 1;
            while (j < n && /[A-Za-z0-9_]/.test(text[j])) j++;
            tokens.push({ t: 'ident', v: text.slice(i, j) });
            i = j;
            continue;
        }
        // A character outside this grammar (?, [, ,, /, …) means the whole
        // expression is something we don't attempt — bail rather than parse
        // a truncated fragment of it.
        return null;
    }
    return tokens;
}

const CONDITION_COMPARATORS = ['==', '!=', '<=', '>=', '<', '>'];

function parseConditionTokens(tokens, resolveValue) {
    let pos = 0;
    const peek = () => tokens[pos];
    const advance = () => tokens[pos++];

    function parseOr() {
        let left = parseAnd();
        while (peek() && peek().t === '||') {
            advance();
            // Must not fold this into `left || parseAnd()` — JS's `||` short-
            // circuits, so once `left` is true the parser would stop calling
            // parseAnd() at all and leave later clauses' tokens unconsumed.
            const right = parseAnd();
            left = Boolean(left) || Boolean(right);
        }
        return left;
    }
    function parseAnd() {
        let left = parseComparison();
        while (peek() && peek().t === '&&') {
            advance();
            const right = parseComparison(); // same short-circuit trap as parseOr above
            left = Boolean(left) && Boolean(right);
        }
        return left;
    }
    function parseComparison() {
        const left = parseUnary();
        const op = peek();
        if (op && CONDITION_COMPARATORS.indexOf(op.t) >= 0) {
            advance();
            const right = parseUnary();
            switch (op.t) {
                case '==': return left == right;
                case '!=': return left != right;
                case '<':  return left < right;
                case '>':  return left > right;
                case '<=': return left <= right;
                case '>=': return left >= right;
            }
        }
        return left;
    }
    function parseUnary() {
        if (peek() && peek().t === '!') {
            advance();
            return !Boolean(parseUnary());
        }
        return parsePrimary();
    }
    function parsePrimary() {
        const tok = peek();
        if (!tok) throw new Error('unexpected end of condition');
        if (tok.t === '(') {
            advance();
            const value = parseOr();
            if (!peek() || peek().t !== ')') throw new Error("expected ')'");
            advance();
            return value;
        }
        if (tok.t === 'num' || tok.t === 'str') { advance(); return tok.v; }
        if (tok.t === 'ident') {
            advance();
            if (tok.v === 'true') return true;
            if (tok.v === 'false') return false;
            // The only reference shape the corpus uses is `name.value` —
            // a bare identifier, or `name.anythingElse`, is outside the
            // grammar (e.g. the `.split(...)` method-chain case).
            if (!peek() || peek().t !== '.') throw new Error(`'${tok.v}' is not a literal or a name.value reference`);
            advance();
            const member = peek();
            if (!member || member.t !== 'ident' || member.v !== 'value')
                throw new Error(`unsupported member access on '${tok.v}'`);
            advance();
            return resolveValue(tok.v);
        }
        throw new Error(`unexpected token in condition`);
    }

    const result = parseOr();
    if (pos !== tokens.length) throw new Error('trailing tokens after condition');
    return result;
}

// `condition` is a raw project.json string; `resolveValue(name)` returns the
// CURRENT live value of another property (not necessarily its parsed
// default), so the caller can re-run this on every relevant property change
// and get a reactive show/hide. Missing/empty condition means "always
// shown" — that's WE's own semantics for a property with no `condition` key.
export function evaluateCondition(condition, resolveValue) {
    if (typeof condition !== 'string' || condition.trim() === '') return true;
    const tokens = tokenizeCondition(condition);
    if (!tokens || tokens.length === 0) return true;
    try {
        return Boolean(parseConditionTokens(tokens, resolveValue || (() => undefined)));
    } catch (e) {
        return true;
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


// The promise-like value Pyext's synchronous FileHelper calls return: then()
// calls back before returning, like the code built on it expects. It lives
// here, not on the Pyext QML object, because a real Promise that adopts it
// calls then() later, from a posted job -- by which time the settings page
// that made it may be gone (Plasma's wallpaper KCM builds the page, discards
// it and builds it again on every open). A then() that needed the destroyed
// page's QML context threw there, and Qt dereferences a null promise when a
// thenable's then() throws (QV4::RejectWrapper), crashing the host process.
export function syncThenable(value) {
    return {
        result: value,
        then(onFulfilled) {
            const next = typeof onFulfilled === 'function' ? onFulfilled(value) : undefined;
            return syncThenable(next !== undefined ? next : value);
        },
        catch() {
            return syncThenable(value);
        },
    };
}
