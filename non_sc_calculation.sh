#!/bin/bash
# non_sc_calculation.sh
# Sets up a static self-consistent run (NSW=0, IBRION=-1, denser k-mesh, writes
# WAVECAR/CHGCAR/AECCAR) in NON-SC-kmesh-0.03/ from a converged relaxation.
# (The directory name is historical: this is an SCF run, not ICHARG=11.)
# Usage: Run in the directory containing a converged VASP relaxation.

set -euo pipefail

# Shared helpers (vasp_common.sh): next to this script, else on PATH
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"; [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh || true)
[ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"

# ─── Configuration ────────────────────────────────────────────────────────────
NEW_DIRECTORY="NON-SC-kmesh-0.03"
FILES_REMOVED=(WAVECAR CHG CHGCAR vasprun.xml PROCAR LOCPOT DOSCAR vaspout.h5)
KPOINTS_SPACING="0.03"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

SEP="---------------------------------------------------------"

# ─── Locate job submission script (PBS or Slurm) ──────────────────────────────
# Header-limited scan (first 4 KB of each file); asks if there are several ($RUNSCRIPT overrides)
SUBMISSION_SCRIPT=$(find_runscript || true)
if [[ -z "$SUBMISSION_SCRIPT" ]]; then
    echo -e "${RED}ERROR:${NC} No PBS (#PBS) or Slurm (#SBATCH) submission script found in the current directory."
    exit 1
fi
SUBMISSION_SCRIPT="$(realpath "$SUBMISSION_SCRIPT")"
[[ "$(sched_of "$SUBMISSION_SCRIPT")" == pbs ]] && SCHEDULER="PBS" || SCHEDULER="Slurm"

echo "Submission script: $(basename "$SUBMISSION_SCRIPT")  (scheduler: $SCHEDULER)"

# FILES_NEEDED uses basename for display; actual copy uses full path where needed
FILES_NEEDED=(INCAR CONTCAR POTCAR KPOINTS "$(basename "$SUBMISSION_SCRIPT")")
echo "Files to copy: ${FILES_NEEDED[*]}"
echo "$SEP"

# ─── Functions ────────────────────────────────────────────────────────────────

check_convergence() {
    # Returns 0 (true) if OUTCAR shows convergence, 1 otherwise.
    if grep -q 'reached required accuracy' "$PWD/OUTCAR" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

check_d_f_elements() {
    # Check the POSCAR in NEW_DIRECTORY (already copied there as POSCAR).
    local poscar="$NEW_DIRECTORY/POSCAR"
    if [[ ! -f "$poscar" ]]; then
        echo "POSCAR file does not exist in $NEW_DIRECTORY"
        return
    fi

    local el
    el=$(poscar_df_elements "$poscar" | head -1)   # Ti_pv/<hash> -> Ti
    if [[ -n "$el" ]]; then
        echo -e "${YELLOW}WARNING:${NC} POSCAR contains d/f-block element '$el'. Modify LMAXMIX accordingly (e.g. LMAXMIX = 4 for d, 6 for f)."
        return
    fi

    echo "POSCAR does not contain d-block or f-block elements."
}

read_kpoints() {
    # Determine vasp_gam vs vasp_std from KPOINTS in NEW_DIRECTORY.
    # Sets global variable VASP_MOD.
    local kpoints_file="$NEW_DIRECTORY/KPOINTS"
    if [[ ! -f "$kpoints_file" ]]; then
        echo -e "${RED}ERROR:${NC} KPOINTS not found in $NEW_DIRECTORY"
        VASP_MOD="vasp_std"
        return
    fi

    local line
    line=$(sed -n '4p' "$kpoints_file")
    read -ra numbers <<< "$line"

    VASP_MOD="vasp_gam"
    for number in "${numbers[@]}"; do
        if [[ "$number" != "1" ]]; then
            VASP_MOD="vasp_std"
            break
        fi
    done
}

file_editor() {
    local incar="$NEW_DIRECTORY/INCAR"
    # Patch the copy in NEW_DIRECTORY, not the original next to the SCF run
    local sub_script="$NEW_DIRECTORY/$(basename "$SUBMISSION_SCRIPT")"

    # ── INCAR modifications ──
    # Set NSW=0 and IBRION=-1 for non-SCF (static) run
    incar_set NSW 0 "$incar" "(Non SCF calculation)"
    incar_set IBRION -1 "$incar" "(Non SCF calculation)"
    # Comment out NELMIN (not meaningful for non-SCF)
    incar_comment NELMIN "$incar"
    # Ensure wavefunctions and charge density are written
    incar_set LWAVE .TRUE. "$incar" "(Write WAVECAR)"
    incar_set LCHARG .TRUE. "$incar" "(Write CHGCAR)"
    incar_set LAECHG .TRUE. "$incar" "(Bader charge)"

    # DOS-related tags only if not already active
    incar_get LORBIT "$incar" >/dev/null || incar_set LORBIT 11 "$incar" "(PAW radii for projected DOS)"
    incar_get NEDOS "$incar" >/dev/null || incar_set NEDOS 2001 "$incar" "(DOSCAR points)"

    # ── Generate denser k-mesh with vaspkit (run inside NEW_DIRECTORY) ──
    if command -v vaspkit &>/dev/null; then
        (cd "$NEW_DIRECTORY" && echo -e "102\n1\n${KPOINTS_SPACING}\n" | vaspkit > /dev/null)
    else
        echo -e "${YELLOW}WARNING:${NC} vaspkit not found in PATH. KPOINTS not regenerated."
    fi

    # ── Determine vasp_gam vs vasp_std ──
    read_kpoints
    echo "VASP executable set to: $VASP_MOD"

    # ── Patch submission script ──
    if [[ -f "$sub_script" ]]; then
        sed -i "s/VASP_EXE=\"[^\"]*\"/VASP_EXE=\"$VASP_MOD\"/" "$sub_script"
    else
        echo -e "${YELLOW}WARNING:${NC} Submission script '$sub_script' not found; VASP_EXE not updated."
    fi

    # ── Summary ──
    echo "INCAR key settings after modification:"
    grep -iE "^[[:space:]]*(NSW|IBRION)[[:space:]]*=" "$incar" | awk -F "#" '{print "  " $1}'
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# 1. Check convergence
if ! check_convergence; then
    echo "Calculation not converged (no 'reached required accuracy' in OUTCAR). Exiting."
    exit 1
fi
echo -e "${GREEN}Convergence confirmed.${NC}"

# 2. Create output directory
if [[ ! -d "$NEW_DIRECTORY" ]]; then
    mkdir "$NEW_DIRECTORY"
    echo -e "${GREEN}${NEW_DIRECTORY}${NC} directory created!"
fi
echo "$SEP"

# 3. Remove large/unnecessary files from current directory
for f in "${FILES_REMOVED[@]}"; do
    # Use glob expansion safely
    for matched in $f; do
        if [[ -e "$matched" ]]; then
            rm -rf "$PWD/$matched"
            echo "Removed: '$matched'"
        fi
    done
done

# 4. Copy required files to NEW_DIRECTORY
ORIG_DIR="$PWD"
for f in "${FILES_NEEDED[@]}"; do
    # Handle absolute path for submission script
    local_f="$f"
    if [[ "$f" == /* ]]; then
        local_f="$(basename "$f")"
        src="$f"
    else
        src="$ORIG_DIR/$f"
    fi

    if [[ -s "$src" ]]; then
        if [[ "$local_f" == "CONTCAR" ]]; then
            cp "$src" "$NEW_DIRECTORY/POSCAR"
            echo "'CONTCAR' -> '$NEW_DIRECTORY/POSCAR'"
        else
            cp "$src" "$NEW_DIRECTORY/$local_f"
            echo "'$local_f' -> '$NEW_DIRECTORY/$local_f'"
        fi
    else
        echo -e "${RED}ERROR:${NC} '$local_f' does not exist or is empty. Aborting."
        echo "$SEP"
        exit 1
    fi
done
echo "$SEP"

# 5. Edit INCAR / KPOINTS / submission script
file_editor
echo "$SEP"

# 6. Check for d/f-block elements and warn about LMAXMIX
check_d_f_elements
echo "$SEP"
