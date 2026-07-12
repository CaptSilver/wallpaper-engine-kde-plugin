# tools/scripts/lib/mem.sh — RAM-aware parallelism helper.
#
# Sourced by the memory-heavy instrumented-build gates (mutation, coverage) so a
# high core count doesn't OOM a box that's short on RAM.
#
# mem_bounded_jobs PER_JOB_MB [MEMINFO_FILE]
#   Echo min(nproc, floor(MemAvailable_MB / PER_JOB_MB)), clamped to at least 1.
#   Instrumented (-g / coverage / mutation) builds and Mull's parallel test runs
#   each cost roughly PER_JOB_MB of RSS, so N cores × that RSS is what exhausts
#   memory; bounding on available RAM instead of core count keeps the peak safe.
#   Prefers MemAvailable (the kernel's allocatable-without-swap estimate) and
#   falls back to MemTotal. MEMINFO_FILE is overridable for testing (default
#   $MEMINFO_FILE, then /proc/meminfo).
mem_bounded_jobs() {
    local per_job_mb="${1:?mem_bounded_jobs: PER_JOB_MB required}"
    local meminfo="${2:-${MEMINFO_FILE:-/proc/meminfo}}"
    local cores mem_kb by_mem
    cores="$(nproc 2>/dev/null || echo 4)"
    mem_kb="$(awk '/^MemAvailable:/ { print $2; exit }' "$meminfo" 2>/dev/null)"
    [[ -z "$mem_kb" ]] && mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' "$meminfo" 2>/dev/null)"
    [[ -z "$mem_kb" ]] && mem_kb=8388608 # 8 GB fallback when /proc/meminfo is unreadable
    by_mem=$(( mem_kb / 1024 / per_job_mb ))
    (( by_mem < 1 )) && by_mem=1
    (( by_mem < cores )) && cores="$by_mem"
    printf '%s\n' "$cores"
}
