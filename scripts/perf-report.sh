#!/bin/bash
# Summarizes what Slatrix logged about its own speed over the last day, or over a `log show --last` duration such as
# 2h or 7d: each timed flow, the loading states people saw, rows that moved under the reader, and main-thread hangs.
set -euo pipefail
duration=${1:-1d}

lines=$(/usr/bin/log show --last "$duration" --style compact \
    --predicate 'subsystem == "ai.nuanu.slatrix" AND category == "performance" AND process == "Slatrix"' |
    awk '
        function field(key,   i) {
            for (i = 1; i <= NF; i++) if (index($i, key "=") == 1) return substr($i, length(key) + 2)
            return ""
        }
        / interval=/ {
            name = field("interval")
            print (name ~ /\.loading$/ ? "loading" : "interval"), name, field("ms")
        }
        / event=/ { print "event", field("event"), field("px") }
        / hang ms=/ { print "hang", field("during"), field("ms") }
    ')

# Count, nearest-rank percentiles and max per name, from "kind name value" lines.
table() {
    sort -k2,2 -k3,3g | awk -v title="$1" -v total="$2" '
        function rank(p,   i) { i = int(p * n); if (i < p * n) i++; return v[i < 1 ? 1 : i] }
        function flush() {
            if (!n) return
            printf "  %-24s %6d %9.1f %9.1f %9.1f", name, n, rank(0.5), rank(0.95), v[n]
            if (total) printf " %9.1f", sum / 1000
            printf "\n"
        }
        NR == 1 {
            printf "%s\n  %-24s %6s %9s %9s %9s%s\n", title, "", "count", "p50", "p95", "max", total ? "   total s" : ""
        }
        $2 != name { flush(); name = $2; n = 0; sum = 0 }
        { v[++n] = $3; sum += $3 }
        END { if (!NR) print title ": none"; flush() }
    '
}
only() { grep "^$1 " <<< "$lines" || true; }

echo "Slatrix performance, last $duration (ms)"
echo
only interval | table Flows 0
echo
only loading | table "Loading on screen" 1
echo
only "event timeline.jump" | awk '
    { n++; px = $3 < 0 ? -$3 : $3; if (px > max) max = px }
    END { printf "Rows that moved under the reader: %d%s\n", n, n ? sprintf(" (largest %d px)", max) : "" }'
echo
hangs=$(only hang)
echo "Main-thread hangs of 100 ms or more: $(grep -c . <<< "$hangs" || true)"
if [[ -n $hangs ]]; then
    sort -k3,3gr <<< "$hangs" | head -10 | awk '{ printf "  %7.0f  during %s\n", $3, $2 }'
fi
