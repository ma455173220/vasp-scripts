#!/bin/bash
# vasp_common.sh - shared bash helpers for the vasp-scripts (bash + awk only).
# Source it; it only defines functions and VASP_COMMON_DIR, never runs anything.
# Scripts find it next to themselves first, then on PATH:
#   _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"
#   [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh)
#   [ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (script directory or PATH)" >&2; exit 1; }
#   source "$_lib"
#
# INCAR      incar_get KEY [FILE]                 value of the active KEY (exit 1 if none)
#            incar_set KEY VALUE [FILE] [COMMENT] set KEY = VALUE: edits the first active occurrence
#                (value up to # or !, other text kept), else uncomments the first "# KEY = ..."
#                line, else appends "KEY = VALUE    #COMMENT". Further active copies are
#                commented out / removed (exactly one active KEY remains). Case-insensitive;
#                ';' lines handled per tag (a commented ';' line is never uncommented as a
#                whole - a new line is inserted after it). Text inside "..." is left alone.
#            incar_comment KEY [FILE]             comment out every active KEY
# POSCAR     poscar_species [FILE]                line-6 symbols with POTCAR suffixes stripped
#            poscar_df_elements [FILE]            d/f-block elements present (POSCAR order)
#            lmaxmix_for_poscar [FILE]            6 (f), 4 (d) or nothing
#            poscar_vacuum_c [FILE]               largest empty gap along c (Angstrom, normal to ab)
#            kpath_task [FILE]                    vaspkit k-path task: 302 (2D, gap > 8 A) or 303;
#                                                 $KPATH_TASK overrides
# Jobs       runscript_scheduler FILE             PBS / SLURM from the first 4 KB (#PBS / #SBATCH)
#            sched_of [SCRIPT]                    pbs / slurm: script header, else command on PATH
#            submit_cmd_of [SCRIPT]               qsub / sbatch
#            find_runscript [DIR]                 the job script in DIR (header-limited scan);
#                                                 asks only if several ($RUNSCRIPT overrides)
#            submit_job [-s pbs|slurm] SCRIPT [ARGS...]  submit from the current dir, print the bare job ID
#            job_active ID [pbs|slurm]            0 while queued/running (errors retried 3x)
#            vasp_job_status [-f] [DIR]           "converged|unconverged|running|failed<TAB>reason";
#                                                 exit 0 only if converged. -f: the job has ended
#                                                 (an incomplete OUTCAR is "failed", not "running")
# Misc       find_tool PATH_OR_NAME...            first existing candidate, else the same name next
#                                                 to vasp_common.sh, else on PATH (prints nothing)
#            die MSG / warn MSG / confirm PROMPT  error+exit / warning / y/N question (default No)

VASP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"

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

# ----------------------------------------------------------------------------
# POSCAR helpers
# ----------------------------------------------------------------------------
VASP_D_ELEMENTS="Sc Ti V Cr Mn Fe Co Ni Cu Zn Y Zr Nb Mo Tc Ru Rh Pd Ag Cd Hf Ta W Re Os Ir Pt Au Hg"
VASP_F_ELEMENTS="La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr"

poscar_df_elements() {
    local el
    for el in $(poscar_species "${1:-POSCAR}"); do
        [[ " $VASP_D_ELEMENTS $VASP_F_ELEMENTS " == *" $el "* ]] && echo "$el"
    done
    return 0
}

lmaxmix_for_poscar() {
    local el has_d=false
    for el in $(poscar_df_elements "${1:-POSCAR}"); do
        [[ " $VASP_F_ELEMENTS " == *" $el "* ]] && { echo 6; return 0; }
        has_d=true
    done
    [ "$has_d" = true ] && echo 4
    return 0
}

kpath_task() {
    if [ -n "${KPATH_TASK:-}" ]; then
        echo "$KPATH_TASK"
    elif awk -v v="$(poscar_vacuum_c "${1:-POSCAR}")" 'BEGIN { exit !(v > 8) }'; then
        echo 302
    else
        echo 303
    fi
}

# ----------------------------------------------------------------------------
# Messages
# ----------------------------------------------------------------------------
die()  { echo -e "\033[31mERROR:\033[0m $*" >&2; exit 1; }
warn() { echo -e "\033[33mWARNING:\033[0m $*" >&2; }
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

find_tool() {
    local cand name
    for cand in "$@"; do
        [ -f "$cand" ] && { echo "$cand"; return 0; }
    done
    for cand in "$@"; do
        name=$(basename "$cand")
        [ -f "$VASP_COMMON_DIR/$name" ] && { echo "$VASP_COMMON_DIR/$name"; return 0; }
    done
    for cand in "$@"; do
        command -v "$(basename "$cand")" 2>/dev/null && return 0
    done
    return 1
}

# ----------------------------------------------------------------------------
# Scheduler / job helpers
# ----------------------------------------------------------------------------
sched_of() {
    case "$( [ -n "${1:-}" ] && runscript_scheduler "$1")" in
        PBS) echo pbs; return 0 ;;
        SLURM) echo slurm; return 0 ;;
    esac
    if [ -n "${VASP_SCHEDULER:-}" ]; then echo "$VASP_SCHEDULER"
    elif command -v sbatch >/dev/null 2>&1; then echo slurm
    elif command -v qsub >/dev/null 2>&1; then echo pbs
    else echo slurm; return 1
    fi
}

submit_cmd_of() {
    [ "$(sched_of "${1:-}")" = pbs ] && echo qsub || echo sbatch
}

find_runscript() {
    if [ -n "${RUNSCRIPT:-}" ]; then echo "$RUNSCRIPT"; return 0; fi
    local dir="${1:-.}" f found=() i choice
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            CHGCAR|CHG|WAVECAR|vasprun.xml|vaspout.h5|PROCAR|POTCAR|DOSCAR|OUTCAR|*_OUTCAR|XDATCAR|AECCAR*|LOCPOT|ELFCAR|EIGENVAL|OSZICAR|INCAR|POSCAR|CONTCAR|KPOINTS|IBZKPT) continue ;;
        esac
        runscript_scheduler "$f" >/dev/null && found+=("${f#./}")
    done
    case ${#found[@]} in
        0) return 1 ;;
        1) echo "${found[0]}"; return 0 ;;
    esac
    echo "Multiple submission scripts found (RUNSCRIPT=<name> skips this question):" >&2
    for i in "${!found[@]}"; do echo "  [$((i+1))] ${found[$i]}" >&2; done
    while true; do
        read -r -p "Select script to use [1-${#found[@]}]: " choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#found[@]} )); then
            echo "${found[$((choice-1))]}"; return 0
        fi
        echo "  Invalid input." >&2
    done
}

submit_job() {
    local sched=""
    [ "${1:-}" = "-s" ] && { sched="$2"; shift 2; }
    local script="$1"; shift
    local out
    [ -n "$sched" ] || sched=$(sched_of "$script")
    if [ "$sched" = pbs ]; then
        out=$(qsub "$@" "$script") || return 1
        echo "$out" | tail -1
    else
        out=$(sbatch --parsable "$@" "$script") || return 1
        echo "$out" | tail -1 | cut -d';' -f1
    fi
}

job_active() {
    # 0 = still queued/running, 1 = finished. A scheduler error that is not a clear
    # "finished/unknown job" answer is retried 3 times before the job counts as finished.
    local jobid="$1" sched="${2:-}" out rc try
    [ -n "$sched" ] || sched=$(sched_of)
    for try in 1 2 3; do
        if [ "$sched" = pbs ]; then
            out=$(qstat "$jobid" 2>&1); rc=$?
            [[ $rc -eq 0 ]] && return 0
            echo "$out" | grep -qiE "finished|Unknown Job" && return 1
        else
            out=$(squeue -h -j "$jobid" -o %T 2>&1); rc=$?
            if [[ $rc -eq 0 ]]; then
                echo "$out" | grep -qE "^(PENDING|CONFIGURING|RUNNING|COMPLETING|SUSPENDED|REQUEUED|REQUEUE_HOLD|RESIZING|SIGNALING|STAGE_OUT)" && return 0
                return 1
            fi
            echo "$out" | grep -qi "Invalid job id" && return 1
        fi
        sleep "${JOB_ACTIVE_RETRY_SLEEP:-30}"
    done
    return 1
}

vasp_job_status() {
    # Same table as VASP_JOB_PARAMETERS:
    #   NSW missing or <= 0                       -> static run: "EDIFF is reached"
    #   IBRION 1/2/3/44                           -> optimisation / IDM: also "reached required accuracy"
    #   IBRION 0/5/6/7/8, none with NSW > 0, other -> MD / finite differences: "EDIFF is reached"
    local final=false
    [ "${1:-}" = "-f" ] && { final=true; shift; }
    local dir="${1:-.}" outcar ibrion nsw
    outcar="$dir/OUTCAR"
    if [ ! -f "$outcar" ]; then
        printf 'failed\tOUTCAR not found\n'; return 1
    fi
    if ! grep -q "Total CPU time used" "$outcar"; then
        if [ "$final" = false ] && [ -n "$(find "$outcar" -mmin -"${VASP_RUNNING_MINUTES:-60}" 2>/dev/null)" ]; then
            printf 'running\tOUTCAR updated in the last %s min\n' "${VASP_RUNNING_MINUTES:-60}"
        else
            printf 'failed\tJob did not complete normally\n'
        fi
        return 1
    fi
    ibrion=$(incar_get IBRION "$dir/INCAR" 2>/dev/null | awk '{print $1}')
    nsw=$(incar_get NSW "$dir/INCAR" 2>/dev/null | awk '{print $1}')
    if [[ -z "$nsw" ]] || { [[ "$nsw" =~ ^-?[0-9]+$ ]] && (( nsw <= 0 )); }; then
        grep -q "EDIFF is reached" "$outcar" && { printf 'converged\tstatic run\n'; return 0; }
        printf 'unconverged\tSCF did not converge\n'; return 1
    elif [[ "$ibrion" =~ ^(1|2|3|44)$ ]]; then
        grep -q "reached required accuracy" "$outcar" && grep -q "EDIFF is reached" "$outcar" \
            && { printf 'converged\toptimisation (IBRION=%s)\n' "$ibrion"; return 0; }
        printf 'unconverged\tOptimization did not converge\n'; return 1
    else
        grep -q "EDIFF is reached" "$outcar" && { printf 'converged\tIBRION=%s NSW=%s\n' "${ibrion:-default}" "$nsw"; return 0; }
        printf 'unconverged\tIBRION=%s (NSW=%s) did not meet criteria\n' "${ibrion:-default}" "$nsw"; return 1
    fi
}
