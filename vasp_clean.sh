#!/bin/bash
# Recursively delete common large VASP / Wannier90 files below the current directory.
# Usage: vasp_clean.sh [-n] [-y]
#   -n  dry run: list what would be deleted, delete nothing
#   -y  do not ask for confirmation

DRY_RUN=false
ASSUME_YES=false
while getopts ":nyh" opt; do
    case $opt in
        n) DRY_RUN=true ;;
        y) ASSUME_YES=true ;;
        h) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        \?) echo "Unknown option -$OPTARG (use -h)"; exit 1 ;;
    esac
done

# Set the list of filenames to delete, common large VASP files
LARGE_FILES=(
    "WAVECAR" "CHG" "CHGCAR" "LOCPOT" "PROCAR" "POT" "vasprun.xml" "vaspout.h5"
    "*.amn" "*.mmn" "*.chk" "*.spn" "*.spn.fmt" "*.npz" "*_wsvec.dat" "*_symmed_hr.dat" "*_hr.dat"
)

# One traversal for all patterns
find_args=()
for file in "${LARGE_FILES[@]}"; do
    [ ${#find_args[@]} -gt 0 ] && find_args+=(-o)
    find_args+=(-name "$file")
done
mapfile -d '' FOUND < <(find . -type f \( "${find_args[@]}" \) -print0)

if [ ${#FOUND[@]} -eq 0 ]; then
    echo "Nothing to delete."
    exit 0
fi

total_size=$(printf '%s\0' "${FOUND[@]}" | du -ch --files0-from=- 2>/dev/null | tail -1 | cut -f1)
printf '%s\n' "${FOUND[@]}"
echo "------------------------------------------------------"
echo "${#FOUND[@]} file(s), ${total_size:-?} in total"

if [ "$DRY_RUN" = true ]; then
    echo "Dry run (-n): nothing deleted."
    exit 0
fi

if [ "$ASSUME_YES" != true ]; then
    read -p "Delete these files? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Nothing deleted."
        exit 0
    fi
fi

printf '%s\0' "${FOUND[@]}" | xargs -0 rm -v --

echo "Cleanup completed."
