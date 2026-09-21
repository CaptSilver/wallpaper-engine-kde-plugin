# tools/scripts/lib/fuzz_corpus_budget.sh — shared corpus-size budget check.
#
# Committed fuzz seed corpora bloat two ways: a directory can grow past a byte
# cap, or it can accumulate more small files than a cap on count -- a byte-only
# check misses the second. minimize.sh's own guard used to be bytes-only too,
# and ran after the mv into place, so an oversized-by-file-count merge had
# already landed before anything caught it. Both call sites now share this.
#
# check_fuzz_corpus_budget DIR MAX_BYTES MAX_FILES
#   Fails (echoes a reason, returns 1) if DIR exceeds either cap.
check_fuzz_corpus_budget() {
    local dir="$1" max_bytes="$2" max_files="$3"
    local bytes files
    bytes=$(du -bs "$dir" | cut -f1)
    files=$(find "$dir" -type f | wc -l)
    if (( bytes > max_bytes )); then
        echo "budget exceeded: $dir ($bytes bytes > $max_bytes)"
        return 1
    fi
    if (( files > max_files )); then
        echo "budget exceeded: $dir ($files files > $max_files)"
        return 1
    fi
    return 0
}
