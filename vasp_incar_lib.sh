#!/bin/bash
# vasp_incar_lib.sh - small shared helpers for the vasp-scripts (bash + awk only)
# Usage: source vasp_incar_lib.sh
#
#   incar_get     KEY [FILE]                 print the value of the active KEY (exit 1 if none)
#   incar_set     KEY VALUE [FILE] [COMMENT] set KEY = VALUE:
#                     edits the first active occurrence (value up to # or !, other text kept),
#                     else uncomments the first commented "# KEY = ..." line,
#                     else appends "KEY = VALUE    #COMMENT".
#                     Any further active copies are commented out / removed, so exactly
#                     one active KEY remains. Keys are case-insensitive; ';'-separated
#                     lines are handled per tag (a commented ';' line is never uncommented
#                     as a whole - a new line is inserted after it instead).
#   incar_comment KEY [FILE]                 comment out every active KEY
#   poscar_species [FILE]                    element symbols of POSCAR line 6, with POTCAR
#                                            suffixes stripped (Ti_pv, Ti_pv/<hash> -> Ti)
#   poscar_vacuum_c [FILE]                   largest empty gap along c (Angstrom, normal to ab)
#   runscript_scheduler FILE                 PBS / SLURM if the first 4 KB has #PBS / #SBATCH
# FILE defaults to INCAR / POSCAR. Strings in double quotes (e.g. WANNIER90_WIN) are left alone.

_incar_awk() {
    # $1 = mode (get|set|comment); KEY, VAL, CMT passed through the environment
    awk -v mode="$1" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function nq(s,   t) { t = s; return gsub(/"/, "", t) }
    # split line into code (before first # or !) and comment (from it)
    function split_code(line) {
        if (match(line, /[#!]/)) { code = substr(line, 1, RSTART - 1); cmt = substr(line, RSTART) }
        else { code = line; cmt = "" }
    }
    function keyof(seg,   p) { p = index(seg, "="); if (!p) return ""; return toupper(trim(substr(seg, 1, p - 1))) }
    function newseg(seg, val,   p, lead, k, tail) {
        p = index(seg, "=")
        k = substr(seg, 1, p - 1); lead = k; sub(/[^ \t].*$/, "", lead)
        tail = substr(seg, p + 1); match(tail, /[ \t]*$/); tail = substr(tail, RSTART)
        return lead trim(k) " = " val tail
    }
    BEGIN { K = toupper(ENVIRON["KEY"]); V = ENVIRON["VAL"]; C = ENVIRON["CMT"]; done = 0; inq = 0; n = 0 }
    { L[++n] = $0 }
    END {
        # pass 1: classify lines
        for (i = 1; i <= n; i++) {
            line = L[i]; act[i] = ""; com[i] = 0
            if (inq) { if (nq(line) % 2) inq = 0; continue }
            split_code(line)
            if (nq(code) % 2) inq = 1
            if (line ~ /^[ \t]*[#!]/) {
                t = line; sub(/^[ \t]*[#!]+[ \t]*/, "", t); split_code(t)
                if (keyof(code) == K && index(code, "=")) com[i] = (index(code, ";") ? 2 : 1)
                continue
            }
            m = split(code, seg, ";")
            for (j = 1; j <= m; j++) if (keyof(seg[j]) == K) act[i] = act[i] " " j
        }
        if (mode == "get") {
            for (i = 1; i <= n; i++) if (act[i] != "") {
                split_code(L[i]); split(code, seg, ";"); split(trim(act[i]), js, " ")
                s = seg[js[1]]; print trim(substr(s, index(s, "=") + 1)); exit 0
            }
            exit 1
        }
        first = 0; for (i = 1; i <= n && !first; i++) if (act[i] != "") first = i
        uc = 0; if (mode == "set" && !first) for (i = 1; i <= n && !uc; i++) if (com[i]) uc = i
        for (i = 1; i <= n; i++) {
            line = L[i]
            if (i == uc && com[i] == 1) {           # uncomment a single-tag commented line
                t = line; sub(/^[ \t]*[#!]+[ \t]*/, "", t); split_code(t)
                print newseg(code, V) cmt; continue
            }
            if (i == uc && com[i] == 2) { print line; print K " = " V (C != "" ? "    #" C : ""); continue }
            if (act[i] == "") { print line; continue }
            split_code(line); m = split(code, seg, ";"); nk = split(trim(act[i]), js, " ")
            for (j = 1; j <= m; j++) keep[j] = 1
            for (q = 1; q <= nk; q++) {
                j = js[q]
                if (mode == "set" && i == first && q == 1) {
                    seg[j] = newseg(seg[j], V)
                    if (cmt == "" && C != "") cmt = "   #" C
                } else keep[j] = 0
            }
            out = ""; removed = ""; kept = 0
            for (j = 1; j <= m; j++) {
                if (keep[j]) { if (!kept && j > 1) sub(/^[ \t]+/, "", seg[j]); out = out (kept ? ";" : "") seg[j]; kept++ }
                else removed = removed (removed == "" ? "" : " ;") seg[j]
            }
            if (!kept) { print "# " line; continue }
            print out cmt
            if (removed != "") print "# " trim(removed)
        }
        if (mode == "set" && !first && !uc) print K " = " V (C != "" ? "    #" C : "")
    }' "${2:-INCAR}"
}

incar_get() {
    local key="$1" file="${2:-INCAR}"
    [ -f "$file" ] || return 1
    KEY="$key" _incar_awk get "$file"
}

incar_set() {
    local key="$1" value="$2" file="${3:-INCAR}" comment="${4:-}"
    [ -f "$file" ] || { echo "incar_set: $file not found" >&2; return 1; }
    KEY="$key" VAL="$value" CMT="$comment" _incar_awk set "$file" > "$file.incar_tmp" \
        && mv "$file.incar_tmp" "$file"
}

incar_comment() {
    local key="$1" file="${2:-INCAR}"
    [ -f "$file" ] || { echo "incar_comment: $file not found" >&2; return 1; }
    KEY="$key" _incar_awk comment "$file" > "$file.incar_tmp" && mv "$file.incar_tmp" "$file"
}

poscar_species() {
    awk 'NR==6 { for (i = 1; i <= NF; i++) { s = $i; sub(/[\/_].*$/, "", s); print s } }' "${1:-POSCAR}"
}

poscar_vacuum_c() {
    # Largest empty slab along c, measured normal to the ab plane (Angstrom)
    awk '
    function det3() { return a[1]*(b[2]*c[3]-b[3]*c[2]) - a[2]*(b[1]*c[3]-b[3]*c[1]) + a[3]*(b[1]*c[2]-b[2]*c[1]) }
    NR==2 { s = $1 }
    NR==3 { a[1]=$1; a[2]=$2; a[3]=$3 }
    NR==4 { b[1]=$1; b[2]=$2; b[3]=$3 }
    NR==5 { c[1]=$1; c[2]=$2; c[3]=$3 }
    NR==6 { line = 7; if ($1 ~ /^[0-9]+$/) line = 6 }
    NR==line { nat = 0; for (i = 1; i <= NF; i++) nat += $i; ctype = line + 1 }
    NR==ctype && /^[ \t]*[Ss]/ { ctype++ }
    NR==ctype { cart = ($1 ~ /^[CcKk]/); first = NR + 1 }
    first && NR>=first && NR<first+nat {
        if (cart) {   # fractional z = (a x b).r / det
            cx = a[2]*b[3]-a[3]*b[2]; cy = a[3]*b[1]-a[1]*b[3]; cz = a[1]*b[2]-a[2]*b[1]
            z = ($1*cx + $2*cy + $3*cz) / det3()
        } else z = $3
        z -= int(z); if (z < 0) z += 1; zs[++k] = z
    }
    END {
        if (k < 1) { print 0; exit }
        for (i = 2; i <= k; i++) { v = zs[i]; for (j = i-1; j >= 1 && zs[j] > v; j--) zs[j+1] = zs[j]; zs[j+1] = v }
        gap = zs[1] + 1 - zs[k]
        for (i = 2; i <= k; i++) if (zs[i] - zs[i-1] > gap) gap = zs[i] - zs[i-1]
        sc = s; d = det3(); if (d < 0) d = -d
        cx = a[2]*b[3]-a[3]*b[2]; cy = a[3]*b[1]-a[1]*b[3]; cz = a[1]*b[2]-a[2]*b[1]
        area = sqrt(cx*cx + cy*cy + cz*cz)
        if (sc < 0) sc = (-sc / d) ^ (1/3)
        printf "%.3f\n", gap * sc * d / area
    }' "${1:-POSCAR}"
}

runscript_scheduler() {
    # Only the first 4 KB are read, so large output files are cheap to skip
    local hdr
    hdr=$(head -c 4096 "$1" 2>/dev/null | tr -d '\000')
    if [[ "$hdr" =~ (^|$'\n')#PBS ]]; then
        echo "PBS"
    elif [[ "$hdr" =~ (^|$'\n')#SBATCH ]]; then
        echo "SLURM"
    else
        return 1
    fi
}
