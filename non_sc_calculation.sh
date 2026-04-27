#!/bin/bash
# non_sc_calculation.sh
# Sets up a Non-Self-Consistent (fixed-charge) VASP calculation from a converged SCF run.
# Usage: Run in the directory containing a converged VASP calculation.

set -euo pipefail

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
# Search before any cd; store candidates as absolute paths.
SUBMISSION_SCRIPT=""
SCHEDULER=""

# Exclude known VASP binary/output files from the search
EXCLUDE_NAMES=( CHGCAR WAVECAR vasprun.xml PROCAR POTCAR DOSCAR OUTCAR INCAR
                CONTCAR POSCAR KPOINTS LOCPOT EIGENVAL IBZKPT OSZICAR )

build_find_excludes() {
    local args=()
    for name in "${EXCLUDE_NAMES[@]}"; do
        args+=(! -name "$name")
    done
    echo "${args[@]}"
}

# Collect ALL candidate scripts and their scheduler types
declare -a CANDIDATE_SCRIPTS=()
declare -a CANDIDATE_SCHEDULERS=()

while IFS= read -r -d '' f; do
    if grep -ql "^#PBS" "$f" 2>/dev/null; then
        CANDIDATE_SCRIPTS+=("$(realpath "$f")")
        CANDIDATE_SCHEDULERS+=("PBS")
    elif grep -ql "^#SBATCH" "$f" 2>/dev/null; then
        CANDIDATE_SCRIPTS+=("$(realpath "$f")")
        CANDIDATE_SCHEDULERS+=("Slurm")
    fi
done < <(find . -maxdepth 1 -type f $(build_find_excludes) -print0)

case ${#CANDIDATE_SCRIPTS[@]} in
    0)
        echo -e "${RED}ERROR:${NC} No PBS (#PBS) or Slurm (#SBATCH) submission script found in the current directory."
        exit 1
        ;;
    1)
        # Unambiguous — use directly
        SUBMISSION_SCRIPT="${CANDIDATE_SCRIPTS[0]}"
        SCHEDULER="${CANDIDATE_SCHEDULERS[0]}"
        ;;
    *)
        # Multiple candidates — prompt user to choose
        echo -e "${YELLOW}Multiple submission scripts found:${NC}"
        for i in "${!CANDIDATE_SCRIPTS[@]}"; do
            printf "  [%d] %s  (%s)\n" "$((i+1))" "$(basename "${CANDIDATE_SCRIPTS[$i]}")" "${CANDIDATE_SCHEDULERS[$i]}"
        done
        while true; do
            read -rp "Select script to use [1-${#CANDIDATE_SCRIPTS[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#CANDIDATE_SCRIPTS[@]} )); then
                SUBMISSION_SCRIPT="${CANDIDATE_SCRIPTS[$((choice-1))]}"
                SCHEDULER="${CANDIDATE_SCHEDULERS[$((choice-1))]}"
                break
            else
                echo "  Invalid input. Please enter a number between 1 and ${#CANDIDATE_SCRIPTS[@]}."
            fi
        done
        ;;
esac

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

    # Extract element symbols from line 6 (VASP5 format)
    local elements
    mapfile -t elements < <(awk 'NR==6 {for (i=1; i<=NF; i++) print $i}' "$poscar")

    # d-block (Groups 3–12, common subset — extend as needed)
    local d_elements=(Sc Ti V Cr Mn Fe Co Ni Cu Zn
                      Y Zr Nb Mo Tc Ru Rh Pd Ag Cd
                      Hf Ta W Re Os Ir Pt Au Hg
                      La Hg)
    # Lanthanides
    local lanthanides=(La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu)
    # Actinides
    local actinides=(Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr)

    local transition_elements=("${d_elements[@]}" "${lanthanides[@]}" "${actinides[@]}")

    for el in "${elements[@]}"; do
        for trans in "${transition_elements[@]}"; do
            if [[ "$el" == "$trans" ]]; then
                echo -e "${YELLOW}WARNING:${NC} POSCAR contains d/f-block element '$el'. Modify LMAXMIX accordingly (e.g. LMAXMIX = 4 for d, 6 for f)."
                return
            fi
        done
    done

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
    local sub_script="$SUBMISSION_SCRIPT"  # absolute path — safe after cd

    # ── INCAR modifications ──
    # Set NSW=0 and IBRION=-1 for non-SCF (static) run
    sed -i '/^NSW/       s/=.*/=  0       #(Non SCF calculation)/'   "$incar"
    sed -i '/^IBRION/    s/=.*/=  -1      #(Non SCF calculation)/'   "$incar"
    # Comment out NELMIN (not meaningful for non-SCF)
    sed -i '/^NELMIN/    s/^/# /'                                     "$incar"
    # Ensure wavefunctions and charge density are written
    sed -i 's/\(#\s*\)\?\s*LWAVE\s*=.*/LWAVE  =  .TRUE.   #(Write WAVECAR)/'  "$incar"
    sed -i 's/\(#\s*\)\?\s*LCHARG\s*=.*/LCHARG =  .TRUE.   #(Write CHGCAR)/'  "$incar"
    sed -i 's/\(#\s*\)\?\s*LAECHG\s*=.*/LAECHG =  .TRUE.   #(Bader charge)/'  "$incar"

    # Append DOS-related tags only if not already present
    grep -q '^LORBIT' "$incar" || echo "LORBIT =  11    #(PAW radii for projected DOS)" >> "$incar"
    grep -q '^NEDOS'  "$incar" || echo "NEDOS  =  2001  #(DOSCAR points)"               >> "$incar"

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
    grep -E "^NSW|^IBRION" "$incar" | awk -F "#" '{print "  " $1}'
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
