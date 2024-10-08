#!/bin/bash

# Set the list of filenames to delete, common large VASP files
LARGE_FILES=(
    "WAVECAR" "CHG" "CHGCAR" "LOCPOT" "PROCAR" "POT" "vasprun.xml" "vaspout.h5"
    "*.amn" "*.mmn" "*.chk" "*.spn" "*.spn.fmt" "*.npz" "*_wsvec.dat" "*_symmed_hr.dat" "*_hr.dat"
)

# Traverse the current directory and all subdirectories, deleting specified large files
for file in "${LARGE_FILES[@]}"; do
    find . -type f -name "$file" -exec rm -v {} +
done

echo "Cleanup completed."
