#!/bin/bash
############################################################
# Script Name: nupdown_summary_submit.sh
#
# Description:
#   Automates NUPDOWN setup/submission & Postprocess summary
#
# Usage:
#   1. Generate defect structures (superfrac_slurm.sh or doped)
#   2. Parent folder contains defect subfolders (e.g. v_O-option1...)
#   3. Set DEFECT_PATH to match subfolder names (e.g. DEFECT_PATH="v_O*")
#   4. Run:
#         bash nupdown_summary_submit.sh
#
# Functions:
#   [1] NUPDOWN Test:
#       - Reads NUPDOWN from INCAR, creates NUPDOWN_X, NUPDOWN_X+2, no_NUPDOWN
#       - Optional job submission
#       - If NUPDOWN missing in INCAR → exit
#
#   [2] Postprocess Summary:
#       - Summarizes lowest E0 from finished jobs
#       - Links ground_state to lowest E0 directory
#
############################################################

# ============================
# Configurable Variables
# ============================
SUBMISSION_SCRIPT="vasp_runscript"
SUBMISSION_CMD="sbatch"
DEFECT_PATH="v_O*"
SUMMARY_LOG="summary.log"

root_dir=$PWD

# ============================
# Check environment and files
# ============================

# Check sbatch command
if ! command -v "$SUBMISSION_CMD" &> /dev/null; then
    echo "❌ ERROR: $SUBMISSION_CMD command not found. Please load your scheduler module or check PATH."
    exit 1
fi

# Check submission script exists
if [[ ! -f "$SUBMISSION_SCRIPT" ]]; then
    echo "❌ ERROR: Submission script '$SUBMISSION_SCRIPT' not found in current directory."
    echo "Please make sure it exists here: $root_dir"
    exit 1
fi

# Check DEFECT_PATH directories exist
dirs_found=( $DEFECT_PATH )
if [[ ${#dirs_found[@]} -eq 0 || ! -d "${dirs_found[0]}" ]]; then
    echo "❌ ERROR: No directories found matching DEFECT_PATH='$DEFECT_PATH'."
    echo "Please check the pattern or adjust DEFECT_PATH."
    exit 1
fi

# ============================
# Menu for function selection
# ============================
echo "Select operation mode:"
echo "1) NUPDOWN test"
echo "2) Postprocess summary"
read -p "Enter choice (1/2): " choice

if [[ "$choice" == "1" ]]; then
    read -p "Do you want to submit jobs after NUPDOWN setup? (y/n): " perform_submit
fi

# ============================
# Part 1: NUPDOWN test
# ============================
if [[ "$choice" == "1" ]]; then
    for defect_dir in $DEFECT_PATH; do
        [[ "$defect_dir" == *bulk* ]] && continue

        cp "$SUBMISSION_SCRIPT" "$defect_dir"
        cd "$defect_dir" || continue

        nupdown=$(grep -i '^NUPDOWN' INCAR | awk -F'=' '{print $2}' | awk '{print $1}')
        if [[ -z "$nupdown" ]]; then
            echo "❌ ERROR: NUPDOWN missing in $defect_dir/INCAR."
            cd "$root_dir"
            exit 1
        fi

        dir_nupdown="NUPDOWN_${nupdown}"
        nupdown_plus2=$(awk "BEGIN {print $nupdown + 2}")
        dir_nupdown_plus2="NUPDOWN_${nupdown_plus2}"
        dir_no_nupdown="no_NUPDOWN"

        for new_dir in "$dir_nupdown" "$dir_nupdown_plus2" "$dir_no_nupdown"; do
            mkdir -p "$new_dir"
            cp INCAR POSCAR POTCAR KPOINTS "$SUBMISSION_SCRIPT" "$new_dir"
        done

        sed -i "s/^NUPDOWN *= *.*/NUPDOWN = $nupdown/" "$dir_nupdown/INCAR"
        sed -i "s/^NUPDOWN *= *.*/NUPDOWN = $nupdown_plus2/" "$dir_nupdown_plus2/INCAR"
        sed -i "s/^NUPDOWN/#NUPDOWN/" "$dir_no_nupdown/INCAR"

        if [[ "$perform_submit" == "y" ]]; then
            for submit_dir in "$dir_nupdown" "$dir_nupdown_plus2" "$dir_no_nupdown"; do
                cd "$submit_dir" && $SUBMISSION_CMD "$SUBMISSION_SCRIPT" && cd ..
            done
        fi
        cd "$root_dir"
    done
fi

# ============================
# Part 2: Postprocess summary
# ============================
if [[ "$choice" == "2" ]]; then
    echo "Defect Directory, E0, mag" > "$SUMMARY_LOG"
    for defect_dir in $DEFECT_PATH; do
        [[ "$defect_dir" == *bulk* ]] && continue

        cd "$defect_dir" || continue
        [ -L ground_state ] && rm ground_state

        min_e0=""
        min_dir=""
        min_mag=""
        min_nupdown_e0=""
        min_nupdown_dir=""
        min_nupdown_mag=""

        for dir in */; do
            outcar_path="${dir}OUTCAR"
            oszicar_path="${dir}OSZICAR"

            [[ ! -s "$outcar_path" ]] && { echo "[MISSING] $defect_dir/$dir OUTCAR"; continue; }
            grep -q "reached required accuracy" "$outcar_path" || { echo "[INCOMPLETE] $defect_dir/$dir"; continue; }
            grep -q "Total CPU time used" "$outcar_path" || { echo "[INCOMPLETE] $defect_dir/$dir"; continue; }
            [[ ! -f "$oszicar_path" ]] && { echo "[MISSING OSZICAR] $defect_dir/$dir"; continue; }

            min_e0_line=$(grep "E0=" "$oszicar_path" | tail -1)
            e0_value=$(echo "$min_e0_line" | awk -F'E0=' '{split($2,a," "); print a[1]}')
            mag_value=$(echo "$min_e0_line" | awk -F'mag=' '{print $2}' | awk '{print $1}')

            if [[ -n "$e0_value" && "$e0_value" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then
                [[ -z "$min_e0" || $(echo "$e0_value < $min_e0" | bc -l) -eq 1 ]] && {
                    min_e0="$e0_value"; min_dir="$dir"; min_mag="$mag_value";
                }
                if [[ "$dir" == NUPDOWN_* ]]; then
                    [[ -z "$min_nupdown_e0" || $(echo "$e0_value < $min_nupdown_e0" | bc -l) -eq 1 ]] && {
                        min_nupdown_e0="$e0_value"; min_nupdown_dir="$dir"; min_nupdown_mag="$mag_value";
                    }
                fi
            fi
        done

        if [[ -n "$min_dir" ]]; then
            echo "$defect_dir/$min_dir, $min_e0, $min_mag" >> "$root_dir/$SUMMARY_LOG"
            if [[ "$min_dir" == "no_NUPDOWN/" && -n "$min_nupdown_dir" ]]; then
                ln -s "$min_nupdown_dir" ground_state
            else
                ln -s "$min_dir" ground_state
            fi
            if [[ "$min_dir" == "no_NUPDOWN/" && -n "$min_nupdown_dir" ]]; then
                rounded_mag=$(printf "%.0f" "$min_mag")
                nupdown_val=$(echo "$min_nupdown_dir" | sed -E 's#NUPDOWN_([0-9.]+)/?#\1#')
                nupdown_val_rounded=$(printf "%.0f" "$nupdown_val")
                normalized_mag=$(awk -v val="$rounded_mag" 'BEGIN { printf("%d", (val == 0 || val == -0) ? 0 : val) }')
                normalized_nupdown=$(awk -v val="$nupdown_val_rounded" 'BEGIN { printf("%d", (val == 0 || val == -0) ? 0 : val) }')
                [[ "$normalized_mag" != "$normalized_nupdown" ]] && \
                    echo "[MISMATCH] $defect_dir: mag=$normalized_mag vs NUPDOWN=$normalized_nupdown"
            fi
        else
            echo "[NO VALID STRUCTURE] $defect_dir"
        fi
        cd "$root_dir"
    done
fi
