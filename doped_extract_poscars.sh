#!/bin/bash

# Loop through all subdirectories in the current directory
for dir in */; do
    # Remove trailing slash to get the folder name
    folder_name=$(basename "$dir")
    
    # Remove "_0" suffix from the folder name
    clean_name=${folder_name%_0}
    
    # Path to POSCAR inside vasp_gam subdirectory
    poscar_path="$dir/vasp_gam/POSCAR"
    
    # Check if POSCAR exists
    if [ -f "$poscar_path" ]; then
        # Copy POSCAR to current directory and rename without "_0"
        cp "$poscar_path" "${clean_name}.vasp"
        echo "Copied $poscar_path → ${clean_name}.vasp"
    else
        echo "⚠️ POSCAR not found in $poscar_path"
    fi
done
