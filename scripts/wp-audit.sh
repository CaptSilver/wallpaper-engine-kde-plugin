#!/usr/bin/env bash
# wp-audit.sh — batch wallpaper audit harness.
#
# Runs sceneviewer-script over a chosen set of wallpapers, captures stderr,
# classifies the run (OK / WARN / JS_ERROR / ERROR / CRASH / NO_SCENE /
# NO_PROJECT), and writes one summary.csv plus per-wallpaper filtered logs.
#
# Subcommands:
#   list      — emit wallpaper IDs matching filters (one per line).
#   run       — audit a set of wallpapers and produce summary.csv + logs.
#   rerun     — re-audit non-OK rows from a prior summary.csv.
#   analyze   — print histograms + worst-N tables from a summary.csv.
#   help      — show this help.
#
# Quick examples:
#   scripts/wp-audit.sh list --type scene --since 2026-05-15
#   scripts/wp-audit.sh run  --type scene --runtime 10 --out /tmp/wp_audit-may
#   scripts/wp-audit.sh run  --ids list.txt
#   scripts/wp-audit.sh rerun --summary /tmp/wp_audit-may/summary.csv
#   scripts/wp-audit.sh analyze --summary /tmp/wp_audit-may/summary.csv
#
# All paths are configurable; defaults match the project's standard Bazzite layout.

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_WORKSHOP="$HOME/.steam/steam/steamapps/workshop/content/431960"
DEFAULT_ASSETS="$HOME/.steam/steam/steamapps/common/wallpaper_engine/assets"
DEFAULT_VIEWER="$REPO_ROOT/src/backend_scene/standalone_view/build-release/sceneviewer-script"
DEFAULT_CACHE_DIR="$HOME/.cache/wescene-renderer"
DEFAULT_RUNTIME=10
DEFAULT_RESOLUTION="1280x720"
DEFAULT_FPS=30
DEFAULT_TIMEOUT_OFFSET=4   # SIGTERM kicks in `runtime`; SIGKILL `runtime + offset`

usage() {
    sed -n '2,/^# All paths/p' "$0" | sed 's/^# \?//'
    cat <<'EOF'

Run options (subcommand `run` and `rerun`):
  --workshop DIR         Workshop content directory.
                         (default: $HOME/.steam/.../workshop/content/431960)
  --assets DIR           Wallpaper Engine assets directory.
                         (default: $HOME/.steam/.../common/wallpaper_engine/assets)
  --viewer PATH          sceneviewer-script binary.
                         (default: src/backend_scene/standalone_view/build-release/sceneviewer-script)
  --cache-dir DIR        wescene-renderer cache base (used by --wipe-cache).
                         (default: $HOME/.cache/wescene-renderer)
  --runtime SECS         Seconds the wallpaper runs before SIGTERM. (default: 10)
  --timeout-offset SECS  Extra seconds before SIGKILL after SIGTERM. (default: 4)
  --resolution WxH       Render resolution. (default: 1280x720)
  --fps N                Target FPS. (default: 30)
  --out DIR              Output directory. (default: /tmp/wp-audit-<timestamp>)
  --wipe-cache           Delete ~/.cache/wescene-renderer/<id> before each
                         wallpaper. Use this when validating shader-transform
                         changes — the SPV cache key is computed BEFORE
                         FixImplicitConversions, so cached results otherwise
                         hide pipeline-stage rewrites.
  --keep-ok-logs         Keep per-wallpaper logs for OK status too. By default
                         only non-OK logs are retained to save disk.
  --limit N              Stop after auditing N wallpapers. 0 = no limit. (default: 0)

List/run filters (mutually exclusive; default = all scene-type new today):
  --ids FILE             Read IDs from FILE (one per line). `-` = stdin.
  --type TYPE            Filter by project.json `type` field. Common values:
                         scene, video, web, application. Case-insensitive.
                         Use `unknown` to match wallpapers without a `type`
                         field (presets etc.).
  --since DATE           Filter by directory mtime >= DATE (YYYY-MM-DD or any
                         GNU date expression like "7 days ago").
  --until DATE           Filter by directory mtime <= DATE.
  --tag SUBSTR           Filter by substring match against project.json title
                         or tags array (case-insensitive).
  --all                  No filter — audit every installed wallpaper.
  --exclude-summary CSV  Skip IDs already in a prior summary.csv (any status).
  --include-status LIST  When combined with --exclude-summary, only include IDs
                         whose status in that summary is in LIST (comma-sep,
                         e.g. ERROR,CRASH). Default: all non-OK statuses.

Analyze options:
  --summary FILE         summary.csv to analyze (required).
  --top N                Top-N for worst-* tables. (default: 20)

Classification rules:
  CRASH      — terminate/segv/abort/sigfpe-style exit in stderr OR exit code
               in {132 SIGFPE, 134 SIGABRT, 135 SIGBUS, 136 SIGUSR1?, 139 SIGSEGV,
               other 128+N codes EXCEPT 130/137/143 which are our own teardown}.
  ERROR      — engine LOG_ERROR / shader compile fail / JSON parse fail.
  JS_ERROR   — SceneScript JS console error/undefined/null/NaN.
  WARN       — engine LOG_WARNING with no error.
  OK         — none of the above.
  NO_PROJECT — project.json missing.
  NO_SCENE   — scene.json/.pkg not resolvable (after gifscene.pkg fallback).

Exit codes:
  0  success (some wallpapers may still have failed — check summary.csv).
  1  invalid arguments.
  2  required binary / directory missing.
EOF
}

err() { printf '%s\n' "wp-audit: $*" >&2; }
die() { err "$*"; exit "${2:-1}"; }

# ─── Path helpers ─────────────────────────────────────────────────────────────
resolve_scene_path() {
    # Echo the scene file to feed sceneviewer. Returns 0 on success, 1 on miss.
    # Tries (in order): the project.json `file` field, then ${file%.json}.pkg,
    # then scene.pkg. The packaged fallback covers gifscene/scene/etc. variants.
    local dir="$1" pj="$2"
    local sfile
    sfile=$(jq -r '.file // "scene.json"' "$pj" 2>/dev/null || echo "scene.json")
    [[ -z $sfile ]] && sfile="scene.json"
    if [[ -f "$dir/$sfile" ]]; then printf '%s\n' "$dir/$sfile"; return 0; fi
    local alt="$dir/${sfile%.json}.pkg"
    if [[ -f $alt ]]; then printf '%s\n' "$alt"; return 0; fi
    if [[ -f "$dir/scene.pkg" ]]; then printf '%s\n' "$dir/scene.pkg"; return 0; fi
    return 1
}

# ─── Filtering ────────────────────────────────────────────────────────────────
# Emits one ID per line based on filter flags. Reads workshop dir + jq filters.
cmd_list() {
    local workshop="$WORKSHOP"
    local mode=all
    local ids_file=""
    local type_filter="" since="" until_="" tag_filter=""
    local exclude_summary="" include_status="ERROR,CRASH,JS_ERROR,WARN,NO_SCENE,NO_PROJECT"

    while (( $# )); do
        case $1 in
            --ids) ids_file=$2; mode=ids; shift 2;;
            --type) type_filter=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); mode=type; shift 2;;
            --since) since=$2; shift 2;;
            --until) until_=$2; shift 2;;
            --tag) tag_filter=$2; shift 2;;
            --all) mode=all; shift;;
            --exclude-summary) exclude_summary=$2; shift 2;;
            --include-status) include_status=$2; shift 2;;
            --workshop) workshop=$2; shift 2;;
            *) die "unknown list flag: $1";;
        esac
    done

    [[ -d $workshop ]] || die "workshop dir not found: $workshop" 2

    # Step 1: candidate IDs
    local -a candidates=()
    if [[ $mode == ids ]]; then
        if [[ $ids_file == "-" ]]; then mapfile -t candidates
        else mapfile -t candidates < "$ids_file"; fi
    else
        # Walk workshop dir, optionally with mtime filters via `find`
        local find_args=("$workshop" -maxdepth 1 -mindepth 1 -type d)
        if [[ -n $since ]]; then find_args+=(-newermt "$since"); fi
        if [[ -n $until_ ]]; then find_args+=(-not -newermt "$until_"); fi
        mapfile -t candidates < <(find "${find_args[@]}" -printf "%f\n" | sort)
    fi

    # Step 2: build exclusion set if provided
    declare -A exclude=()
    if [[ -n $exclude_summary ]]; then
        [[ -f $exclude_summary ]] || die "exclude-summary not found: $exclude_summary" 2
        local incl_re
        incl_re=$(printf '%s' "$include_status" | sed 's/,/|/g')
        while IFS=, read -r id status _rest; do
            [[ $id == "id" || -z $id ]] && continue
            # If id's status NOT in include_status set, exclude (skip from re-audit).
            if [[ ! $status =~ ^($incl_re)$ ]]; then
                exclude[$id]=1
            fi
        done < "$exclude_summary"
    fi

    # Step 3: per-candidate filtering
    local id pj type title
    for id in "${candidates[@]}"; do
        [[ -z $id ]] && continue
        # Strip CR if any
        id=${id%$'\r'}
        [[ -n ${exclude[$id]:-} ]] && continue
        pj="$workshop/$id/project.json"
        if [[ -n $type_filter || -n $tag_filter ]]; then
            [[ -f $pj ]] || continue
        fi
        if [[ -n $type_filter ]]; then
            type=$(jq -r '.type // "unknown"' "$pj" 2>/dev/null | tr '[:upper:]' '[:lower:]' \
                   || echo unknown)
            [[ $type == "$type_filter" ]] || continue
        fi
        if [[ -n $tag_filter ]]; then
            title=$(jq -r '[(.title // ""), ((.tags // []) | join(" "))] | join(" ")' "$pj" 2>/dev/null \
                    || echo "")
            shopt -s nocasematch
            [[ $title == *"$tag_filter"* ]] || { shopt -u nocasematch; continue; }
            shopt -u nocasematch
        fi
        printf '%s\n' "$id"
    done
}

# ─── Classification ───────────────────────────────────────────────────────────
# Inspects a raw stderr log + exit code. Echoes one line with TAB-separated
# fields: status\tfatal,error,warn,js_err,shader_err,parse_err
# (so audit_one can interpolate them into the CSV row in the right column order).
classify() {
    local log=$1 exit_code=$2

    local fatal error warn js_err shader_err parse_err
    # Real-crash signatures, ignoring INFO lines (which may legitimately contain
    # an object named e.g. 'ERROR FATAL' from the wallpaper author).
    fatal=$(grep -vE "^INFO " "$log" 2>/dev/null \
              | grep -cE "Segmentation fault|SIGSEGV|SIGABRT|terminate called|AddressSanitizer|core dumped|^Aborted|panic" \
              || true)
    # Engine LOG_ERROR (excluding JS console.log forwarding to avoid double-count).
    error=$(grep -vE "JS console\\.log:" "$log" 2>/dev/null | grep -cE "^ERROR " || true)
    warn=$(grep -vE "JS console\\.log:" "$log" 2>/dev/null | grep -cE "^WARNING " || true)
    js_err=$(grep -cE "JS console\\.log:.*([Ee]rror|[Uu]ndefined|null|NaN)" "$log" 2>/dev/null || true)
    shader_err=$(grep -cE "compilation errors|shader compilation failed|glslang\\(parse\\)|boolean expression expected" "$log" 2>/dev/null || true)
    parse_err=$(grep -cE "parse error at line|json.exception.parse_error" "$log" 2>/dev/null || true)

    local status
    if (( ${fatal:-0} > 0 )); then
        status=CRASH
    elif (( exit_code > 128 )) \
         && (( exit_code != 130 )) && (( exit_code != 137 )) && (( exit_code != 143 )); then
        # 130=SIGINT, 137=SIGKILL, 143=SIGTERM — those are our own teardown.
        # Anything else (SIGFPE=136, SIGSEGV=139, SIGABRT=134, SIGBUS=135, etc.)
        # is a real crash even when no fatal signature reached stderr.
        status=CRASH
    elif (( ${error:-0} > 0 )) || (( ${shader_err:-0} > 0 )) || (( ${parse_err:-0} > 0 )); then
        status=ERROR
    elif (( ${js_err:-0} > 0 )); then
        status=JS_ERROR
    elif (( ${warn:-0} > 0 )); then
        status=WARN
    else
        status=OK
    fi
    printf '%s\t%d,%d,%d,%d,%d,%d\n' \
        "$status" "${fatal:-0}" "${error:-0}" "${warn:-0}" "${js_err:-0}" \
        "${shader_err:-0}" "${parse_err:-0}"
}

# ─── Per-wallpaper run ────────────────────────────────────────────────────────
audit_one() {
    local id=$1 workshop=$2 assets=$3 viewer=$4 runtime=$5 timeout_s=$6 resolution=$7 fps=$8
    local out_dir=$9 wipe_cache=${10} keep_ok=${11} cache_dir=${12}

    local pj="$workshop/$id/project.json"
    if [[ ! -f $pj ]]; then
        printf '%s,NO_PROJECT,,,,,,,,""\n' "$id"
        return
    fi
    local title sfile scenepath
    title=$(jq -r '.title // ""' "$pj" 2>/dev/null | tr ',\n' '  ' | head -c 80 || echo "")

    if ! scenepath=$(resolve_scene_path "$workshop/$id" "$pj"); then
        printf '%s,NO_SCENE,,,,,,,,"%s"\n' "$id" "$title"
        return
    fi

    if (( wipe_cache )); then
        rm -rf "$cache_dir/$id" 2>/dev/null || true
    fi

    local rawlog
    rawlog=$(mktemp)
    timeout --kill-after=2 "$timeout_s" "$viewer" \
        -f "$fps" -R "$resolution" \
        "$assets" "$scenepath" > /dev/null 2> "$rawlog" &
    local pid=$!
    sleep "$runtime"
    set +e
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    local exit_code=$?
    set -e

    local class status counters
    class=$(classify "$rawlog" "$exit_code")
    status=${class%%$'\t'*}     # before tab
    counters=${class#*$'\t'}    # after tab: fatal,error,warn,js_err,shader_err,parse_err

    if [[ $status != OK ]] || (( keep_ok )); then
        {
            echo "=== $id ($title) ==="
            echo "=== fatal ==="
            grep -vE "^INFO " "$rawlog" 2>/dev/null \
                | grep -E "Segmentation fault|SIGSEGV|SIGABRT|terminate called|AddressSanitizer|core dumped|^Aborted|panic" \
                | sort -u | head -10
            echo "=== errors ==="
            grep -vE "JS console\\.log:" "$rawlog" 2>/dev/null | grep -E "^ERROR " | sort -u | head -30
            echo "=== shader_err ==="
            grep -E "compilation errors|shader compilation failed|glslang\\(parse\\)|boolean expression expected|ERROR: [0-9]" "$rawlog" 2>/dev/null | sort -u | head -20
            echo "=== parse_err ==="
            grep -E "parse error at line|json.exception.parse_error" "$rawlog" 2>/dev/null | sort -u | head -10
            echo "=== js_err (top distinct) ==="
            grep -E "JS console\\.log:" "$rawlog" 2>/dev/null \
                | sed -E 's/(line=)[0-9]+/\1N/g' | sort -u | head -20
            echo "=== warnings ==="
            grep -vE "JS console\\.log:" "$rawlog" 2>/dev/null | grep -E "^WARNING " | sort -u | head -10
            echo "=== exit_code=$exit_code ==="
        } > "$out_dir/logs/$id.log"
    fi
    rm -f "$rawlog"

    # CSV row matches header in cmd_run():
    # id,status,exit,fatal,error,warn,js_err,shader_err,parse_err,title
    printf '%s,%s,%s,%s,"%s"\n' "$id" "$status" "$exit_code" "$counters" "$title"
}

# ─── Run / Rerun ──────────────────────────────────────────────────────────────
cmd_run() {
    local action=$1   # "run" or "rerun"
    shift

    WORKSHOP=$DEFAULT_WORKSHOP
    ASSETS=$DEFAULT_ASSETS
    VIEWER=$DEFAULT_VIEWER
    CACHE_DIR=$DEFAULT_CACHE_DIR
    RUNTIME=$DEFAULT_RUNTIME
    RESOLUTION=$DEFAULT_RESOLUTION
    FPS=$DEFAULT_FPS
    TIMEOUT_OFFSET=$DEFAULT_TIMEOUT_OFFSET
    OUT_DIR=""
    WIPE_CACHE=0
    KEEP_OK_LOGS=0
    LIMIT=0
    REAUDIT_SUMMARY=""

    local list_args=()

    # Ctrl-C should take any in-flight sceneviewer child with it. Without
    # the trap, the parent dies before `wait` and the child becomes an
    # orphan still painting frames + writing to its rawlog tmpfile.
    # Cleanup also removes any rawlog files that weren't reaped.
    trap 'kill $(jobs -p) 2>/dev/null || true; rm -f /tmp/tmp.* 2>/dev/null || true; exit 130' INT TERM

    while (( $# )); do
        case $1 in
            --workshop)        WORKSHOP=$(realpath -m "$2"); shift 2;;
            --assets)          ASSETS=$(realpath -m "$2"); shift 2;;
            --viewer)          VIEWER=$(realpath -m "$2"); shift 2;;
            --cache-dir)       CACHE_DIR=$(realpath -m "$2"); shift 2;;
            --runtime)         RUNTIME=$2; shift 2;;
            --timeout-offset)  TIMEOUT_OFFSET=$2; shift 2;;
            --resolution)      RESOLUTION=$2; shift 2;;
            --fps)             FPS=$2; shift 2;;
            --out)             OUT_DIR=$2; shift 2;;
            --wipe-cache)      WIPE_CACHE=1; shift;;
            --keep-ok-logs)    KEEP_OK_LOGS=1; shift;;
            --limit)           LIMIT=$2; shift 2;;
            --summary)         REAUDIT_SUMMARY=$2; shift 2;;
            # forwarded to list:
            --ids|--type|--since|--until|--tag|--exclude-summary|--include-status)
                list_args+=("$1" "$2"); shift 2;;
            --all)
                list_args+=("$1"); shift;;
            *) die "unknown run flag: $1";;
        esac
    done

    [[ -x $VIEWER ]] || die "viewer not executable: $VIEWER (build with cmake --build build-release)" 2
    [[ -d $WORKSHOP ]] || die "workshop dir not found: $WORKSHOP" 2
    [[ -d $ASSETS ]] || die "assets dir not found: $ASSETS" 2

    if [[ -z $OUT_DIR ]]; then
        OUT_DIR="/tmp/wp-audit-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$OUT_DIR/logs"

    # For `rerun`, derive ID list from prior summary's non-OK rows.
    if [[ $action == rerun ]]; then
        [[ -f $REAUDIT_SUMMARY ]] || die "--summary required for rerun, file missing: $REAUDIT_SUMMARY" 1
        local rerun_ids="$OUT_DIR/_rerun_ids.txt"
        awk -F, 'NR>1 && $2 != "OK" {print $1}' "$REAUDIT_SUMMARY" > "$rerun_ids"
        list_args+=(--ids "$rerun_ids" --workshop "$WORKSHOP")
    else
        list_args+=(--workshop "$WORKSHOP")
    fi

    local ids
    mapfile -t ids < <(cmd_list "${list_args[@]}")
    local total=${#ids[@]}
    (( total == 0 )) && { err "no wallpapers matched the filter"; return; }
    if (( LIMIT > 0 )) && (( LIMIT < total )); then
        ids=("${ids[@]:0:$LIMIT}")
        total=$LIMIT
    fi

    local summary="$OUT_DIR/summary.csv"
    local progress="$OUT_DIR/progress.txt"
    echo "id,status,exit,fatal,error,warn,js_err,shader_err,parse_err,title" > "$summary"
    : > "$progress"

    err "running $total wallpapers; output → $OUT_DIR"
    err "config: runtime=${RUNTIME}s resolution=$RESOLUTION fps=$FPS wipe_cache=$WIPE_CACHE"

    local timeout_s=$(( RUNTIME + TIMEOUT_OFFSET ))
    local i=0
    for id in "${ids[@]}"; do
        i=$(( i + 1 ))
        local row
        row=$(audit_one "$id" "$WORKSHOP" "$ASSETS" "$VIEWER" "$RUNTIME" \
                       "$timeout_s" "$RESOLUTION" "$FPS" "$OUT_DIR" \
                       "$WIPE_CACHE" "$KEEP_OK_LOGS" "$CACHE_DIR")
        printf '%s\n' "$row" >> "$summary"
        # Progress line: extract status from row
        local id_part="${row%%,*}"; local rest="${row#*,}"; local status="${rest%%,*}"
        printf '[%4d/%4d] %-12s %-9s\n' "$i" "$total" "$id_part" "$status" \
            | tee -a "$progress" >&2
    done

    echo "DONE $(date)" >> "$progress"
    err "done. summary: $summary"

    # Quick tally
    err "status histogram:"
    tail -n +2 "$summary" | awk -F, '{print $2}' | sort | uniq -c | sort -rn >&2
}

# ─── Analyze ──────────────────────────────────────────────────────────────────
cmd_analyze() {
    local summary="" top=20 logs_dir=""
    while (( $# )); do
        case $1 in
            --summary) summary=$2; shift 2;;
            --top)     top=$2; shift 2;;
            --logs)    logs_dir=$2; shift 2;;
            *) die "unknown analyze flag: $1";;
        esac
    done
    [[ -f $summary ]] || die "--summary required and must exist" 1
    [[ -z $logs_dir ]] && logs_dir="$(dirname "$summary")/logs"

    echo "=== status distribution ==="
    tail -n +2 "$summary" | awk -F, '{print $2}' | sort | uniq -c | sort -rn
    echo
    echo "=== worst $top by shader_err ==="
    tail -n +2 "$summary" | awk -F, -v n="$top" '$8>0 {print $0}' \
        | sort -t, -k8 -n -r | head -"$top" \
        | awk -F, '{gsub(/"/,"",$10); printf "%-12s shdr=%-3s err=%-3s js=%-5s  %s\n",$1,$8,$5,$7,$10}'
    echo
    echo "=== worst $top by parse_err ==="
    tail -n +2 "$summary" | awk -F, -v n="$top" '$9>0 {print $0}' \
        | sort -t, -k9 -n -r | head -"$top" \
        | awk -F, '{gsub(/"/,"",$10); printf "%-12s parse=%-4s err=%-3s  %s\n",$1,$9,$5,$10}'
    echo
    echo "=== worst $top by js_err ==="
    tail -n +2 "$summary" | awk -F, -v n="$top" '$7>0 {print $0}' \
        | sort -t, -k7 -n -r | head -"$top" \
        | awk -F, '{gsub(/"/,"",$10); printf "%-12s js=%-5s err=%-3s  %s\n",$1,$7,$5,$10}'
    echo
    echo "=== CRASH list ==="
    awk -F, 'NR>1 && $2=="CRASH"{gsub(/"/,"",$10); printf "%-12s exit=%-3s  %s\n",$1,$3,$10}' "$summary"
    echo
    if [[ -d $logs_dir ]]; then
        echo "=== top engine ERROR signatures (across logs) ==="
        grep -h "^ERROR " "$logs_dir"/*.log 2>/dev/null \
            | sed -E 's|/tmp/[a-zA-Z0-9_-]+|/tmp/HASH|g; s|[0-9a-f]{20,}|HASH|g; s|[0-9]+x[0-9]+|WxH|g' \
            | sort | uniq -c | sort -rn | head -"$top"
        echo
        echo "=== top distinct JS-error signatures ==="
        grep -hE "JS console\\.log:" "$logs_dir"/*.log 2>/dev/null \
            | sed -E 's/line=[0-9]+/line=N/g' | sort | uniq -c | sort -rn | head -"$top"
    fi
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
case ${1:-help} in
    list)    shift; WORKSHOP=$DEFAULT_WORKSHOP; cmd_list "$@";;
    run)     shift; cmd_run run "$@";;
    rerun)   shift; cmd_run rerun "$@";;
    analyze) shift; cmd_analyze "$@";;
    help|-h|--help) usage;;
    *) usage; exit 1;;
esac
