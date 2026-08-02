#!/usr/bin/env bash
#
# Converts the AdGuard DNS filter from adblock syntax into wildcard domains:
#
#     ||example.com^   ->   *.example.com
#
# The script exits non-zero — failing the workflow loudly — rather than
# publishing a list that is empty or suspiciously small. A blocklist that goes
# silently stale is worse than one that visibly breaks.
#
# Every setting can be overridden from the environment, which is what the test
# suite does to exercise the safety nets against a healthy source.

set -euo pipefail

SOURCE_URL="${SOURCE_URL:-https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt}"
OUTPUT="${OUTPUT:-adguard-wildcard.txt}"

MIN_ENTRIES="${MIN_ENTRIES:-100000}"   # absolute floor: never publish fewer than this
MAX_SHRINK_PCT="${MAX_SHRINK_PCT:-20}" # fail if the list shrinks more than this vs. the committed one

# Byte-wise collation, so sort order never depends on the runner's locale.
# Without it, a locale change alone would show up as a whole-file diff.
export LC_ALL=C

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
raw="$work/filter.txt"

# --- 1. fetch and validate the input -----------------------------------------

if ! http_code="$(curl -sS -L --retry 3 --retry-delay 5 --max-time 120 \
                       -w '%{http_code}' -o "$raw" "$SOURCE_URL")"; then
    echo "ERROR: download failed (network, DNS or timeout)" >&2
    exit 1
fi

if [ "$http_code" != "200" ]; then
    echo "ERROR: source returned HTTP $http_code" >&2
    exit 1
fi

if [ ! -s "$raw" ]; then
    echo "ERROR: source returned an empty body" >&2
    exit 1
fi

# --- 2. classify and convert in a single pass --------------------------------
#
# Every source line lands in exactly one bucket, so the counts in the header add
# up to the line total and nothing hides in a gap between categories. Only plain
# ||domain^ rules convert without loss; anchoring the pattern at both ends keeps
# out rules carrying modifiers (||domain^$third-party), wildcards inside the
# domain (||ads-*.example.com^) and substring rules (.example.com^), none of
# which a *.domain entry can express.

awk -v counts="$work/counts.env" '
    /^!/                      { n_comment++;   next }
    /^[[:space:]]*$/          { n_blank++;     next }
    /^@@/                     { n_exception++; next }
    /^\/.*\/$/                { n_regex++;     next }
    /^\|\|[a-zA-Z0-9._-]+\^$/ { n_rule++
                                print "*." tolower(substr($0, 3, length($0) - 3))
                                next }
    /\$/                      { n_modifier++;  next }
                              { n_other++ }
    END {
        printf "n_total=%d\nn_comment=%d\nn_blank=%d\nn_exception=%d\n" \
               "n_regex=%d\nn_rule=%d\nn_modifier=%d\nn_other=%d\n",
               NR, n_comment, n_blank, n_exception,
               n_regex, n_rule, n_modifier, n_other > counts
    }
' "$raw" | sort -u > "$work/domains.txt"

# shellcheck source=/dev/null
. "$work/counts.env"

count="$(wc -l < "$work/domains.txt")"

# --- 3. safety net: absolute floor -------------------------------------------
# Also the backstop for a source that answers 200 with a body we cannot parse:
# whatever the cause, too few entries never gets published.

if [ "$count" -lt "$MIN_ENTRIES" ]; then
    echo "ERROR: got $count entries, floor is $MIN_ENTRIES — refusing to publish" >&2
    exit 1
fi

# --- 4. safety net: relative shrink ------------------------------------------

previous=0
if [ -f "$OUTPUT" ]; then
    previous="$(grep -cv -e '^#' -e '^$' "$OUTPUT" || true)"
fi

if [ "$previous" -gt 0 ]; then
    drop=$(( (previous - count) * 100 / previous ))
    if [ "$drop" -gt "$MAX_SHRINK_PCT" ]; then
        echo "ERROR: list shrank by ${drop}% ($previous -> $count), limit is ${MAX_SHRINK_PCT}% — refusing to publish" >&2
        exit 1
    fi
fi

# --- 5. skip the write when nothing actually changed -------------------------
# Compared on the payload only. The header carries a timestamp, so comparing
# whole files would force a pointless commit every single day.

if [ -f "$OUTPUT" ]; then
    { grep -v -e '^#' -e '^$' "$OUTPUT" || true; } > "$work/previous.txt"
    if cmp -s "$work/previous.txt" "$work/domains.txt"; then
        echo "No change ($count entries) — leaving $OUTPUT untouched."
        exit 0
    fi
fi

# --- 6. write the list -------------------------------------------------------

{
    echo "# Title: AdGuard DNS filter (wildcard)"
    echo "# Description: AdGuard DNS filter converted from adblock syntax to wildcard domains"
    echo "# Homepage: https://github.com/sikysikov/adguard-wildcard-blocklist"
    echo "# Source: $SOURCE_URL"
    echo "# Syntax: Domains Wildcard"
    echo "# Number of entries: $count"
    echo "# Last modified: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#"
    echo "# Conversion: ||domain^ -> *.domain"
    echo "#"
    echo "# Every source line accounted for (the categories below sum to the total):"
    echo "#   source lines            : $n_total"
    echo "#     converted             : $n_rule"
    echo "#     comments              : $n_comment"
    echo "#     blank                 : $n_blank"
    echo "#     skipped, exception @@ : $n_exception"
    echo "#     skipped, regex /.../  : $n_regex"
    echo "#     skipped, \$modifier    : $n_modifier"
    echo "#     skipped, other syntax : $n_other"
    echo "#"
    echo "# 'other syntax' is mostly wildcards inside the domain (||ads-*.example.com^),"
    echo "# substring rules (.example.com^) and rules without a trailing separator."
    echo "# None of those can be expressed as a *.domain entry, so they are left out"
    echo "# rather than converted approximately."
    echo "#"
    cat "$work/domains.txt"
} > "$OUTPUT"

echo "Wrote $OUTPUT: $count entries (previous: $previous)"
