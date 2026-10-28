#!/bin/bash

# Gibbs calculation setup script
echo "============================================"
echo "  VASP Gibbs/Frequency Calculation Setup"
echo "============================================"
echo ""

# Shared helpers (vasp_common.sh): next to this script, else on PATH
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"; [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh || true)
[ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"

# Locate center-of-mass.py: next to vasp_common.sh (this repo), then PATH
COM_SCRIPT=$(find_tool center-of-mass.py)

# Ask for calculation type
echo "Please select calculation type:"
echo "  1) IDM frequency calculation (Improved Dimer Method - NWRITE=3)"
echo "  2) Regular Gibbs calculation (NWRITE default)"
echo ""
read -p "Enter option (1 or 2): " calc_type

# Set parameters based on selection
case $calc_type in
    1)
        folder_name="Gibbs_IDM"
        nwrite_value=3
        calc_mode="IDM Frequency Calculation"
        echo ""
        echo ">>> Selected: IDM Frequency Calculation Mode"
        ;;
    2)
        folder_name="Gibbs"
        nwrite_value="default"
        calc_mode="Regular Gibbs Calculation"
        echo ""
        echo ">>> Selected: Regular Gibbs Calculation Mode"
        ;;
    *)
        echo "Error: Invalid option, please enter 1 or 2"
        exit 1
        ;;
esac

# Ask whether to use dipole correction
echo ""
echo "Use dipole correction?"
echo "  y) Yes - run center-of-mass.py and set DIPOL (for slabs/surfaces with vacuum)"
echo "  n) No  - skip DIPOL setup and comment out DIPOL/LDIPOL/IDIPOL in INCAR"
echo "          (for bulk, gas-phase molecules in box, or non-polar systems)"
echo ""
read -p "Enter option (y or n) [default: y]: " dipole_input
dipole_input=${dipole_input:-y}

case $dipole_input in
    y|Y|yes|YES|Yes)
        use_dipole=true
        echo ">>> Dipole correction: ENABLED"
        ;;
    n|N|no|NO|No)
        use_dipole=false
        echo ">>> Dipole correction: DISABLED"
        ;;
    *)
        echo "Error: Invalid option, please enter y or n"
        exit 1
        ;;
esac

echo "Directory: $folder_name"
echo "============================================"
echo ""
echo "Starting setup for $calc_mode..."

# 1. Create Gibbs folder
if [ -d "$folder_name" ]; then
    echo "Warning: $folder_name folder already exists (it may hold a finished calculation)"
    if confirm "Delete it and recreate?"; then
        rm -rf "$folder_name"
    else
        echo "Keeping existing $folder_name - nothing done."
        exit 1
    fi
fi
mkdir "$folder_name"
echo "Created $folder_name folder"

# 2. Copy required files to Gibbs folder
required_files=("INCAR" "CONTCAR" "KPOINTS" "POTCAR" "vasp_runscript")
for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        cp "$file" "$folder_name/"
        echo "Copied $file"
    else
        echo "Error: File $file not found"
        exit 1
    fi
done

# Enter Gibbs folder
cd "$folder_name"

# 3. Rename CONTCAR to POSCAR
if [ -f "CONTCAR" ]; then
    mv CONTCAR POSCAR
    echo "Renamed CONTCAR to POSCAR"
else
    echo "Error: CONTCAR file does not exist"
    exit 1
fi

# Generate gamma-point KPOINTS file
echo "Generating gamma-point KPOINTS..."
echo -e "102\n2\n0" | vaspkit > /dev/null 2>&1
if [ -f "KPOINTS" ]; then
    echo "Generated gamma-point KPOINTS file"
else
    echo "Warning: vaspkit may not have successfully generated KPOINTS file"
fi

# 4. Handle DIPOL setting based on user choice
if [ "$use_dipole" = true ]; then
    # Run center-of-mass.py to get center of mass coordinates
    echo "Running center-of-mass.py to calculate center of mass..."
    if [ -z "$COM_SCRIPT" ]; then
        echo "Error: center-of-mass.py not found (script directory or PATH)"
        exit 1
    fi
    output=$(python3 "$COM_SCRIPT" POSCAR)
    echo "$output"

    # Extract content within [] as dipol variable
    dipol=$(echo "$output" | grep -o '\[.*\]' | sed 's/\[//g' | sed 's/\]//g' | tr -s ' ')
    if [ -z "$dipol" ]; then
        echo "Error: Cannot extract center of mass coordinates from center-of-mass.py output"
        exit 1
    fi
    echo "Extracted center of mass coordinates: $dipol"

    # Modify DIPOL value in INCAR file
    echo "Modifying INCAR file..."
    if [ -f "INCAR" ]; then
        # Only modify DIPOL (not LDIPOL / IDIPOL)
        incar_set DIPOL "$(echo $dipol)"
        echo "Updated DIPOL = $dipol"
    else
        echo "Error: INCAR file does not exist"
        exit 1
    fi
else
    # Comment out dipole-related parameters in INCAR
    echo "Disabling dipole correction in INCAR..."
    if [ -f "INCAR" ]; then
        incar_comment DIPOL
        incar_comment LDIPOL
        incar_comment IDIPOL
        echo "Commented out DIPOL, LDIPOL, IDIPOL"
    else
        echo "Error: INCAR file does not exist"
        exit 1
    fi
fi

# 5. Modify NSW and comment out optimization-related parameters
echo "Modifying structure optimization parameters..."

# Change NSW to 1
incar_set NSW 1
echo "Changed NSW to 1"

# Comment out the VTST optimizer (IOPT; its POTIM / IBRION are reset below)
# and the NEB-related parameters (IMAGES, SPRING, LCLIMB, ICHAIN)
for tag in IOPT IMAGES SPRING LCLIMB ICHAIN; do
    incar_comment "$tag"
done
echo "Commented out optimizer / NEB-related parameters (IOPT, IMAGES, SPRING, LCLIMB, ICHAIN)"

# Modify EDIFF to 1E-07
incar_set EDIFF 1E-07
echo "Set EDIFF = 1E-07"

# 6. Set Gibbs calculation parameters
echo "Setting Gibbs calculation parameters..."
incar_set IBRION 5
incar_set POTIM 0.015
incar_set NFREE 2

# Handle NWRITE based on calculation type
if [ "$nwrite_value" = "default" ]; then
    # For regular Gibbs calculation, comment NWRITE out if it is set
    if incar_get NWRITE >/dev/null; then
        incar_comment NWRITE
        echo "Commented out NWRITE (using default value)"
    else
        echo "NWRITE not found in INCAR (will use default value)"
    fi
else
    # For IDM calculation, set NWRITE = 3
    incar_set NWRITE "$nwrite_value"
    echo "Set NWRITE = $nwrite_value (for IDM frequency analysis)"
fi

echo "Set IBRION = 5, POTIM = 0.015, NFREE = 2"

# 7. Modify VASP_EXE in vasp_runscript
echo "Modifying vasp_runscript..."
if [ -f "vasp_runscript" ]; then
    sed -i 's/VASP_EXE="vasp_std"/VASP_EXE="vasp_gam"/' vasp_runscript
    echo "Changed VASP_EXE to vasp_gam"
    
    # Modify SBATCH ntasks (--ntasks-per-node in vasp_runscript_setonix, or --ntasks) to 128
    sed -i 's/^#SBATCH --ntasks\(-per-node\)\?=[0-9]*/#SBATCH --ntasks\1=128/' vasp_runscript
    echo "Changed #SBATCH --ntasks(-per-node) to 128"
    
    # Modify SBATCH nodes to 1
    sed -i 's/^#SBATCH --nodes=[0-9]*/#SBATCH --nodes=1/' vasp_runscript
    echo "Changed #SBATCH --nodes to 1"
else
    echo "Warning: vasp_runscript file does not exist"
fi

# Display modified key parameters
echo ""
echo "============================================"
echo "  Configuration Summary"
echo "============================================"
echo "Calculation Mode: $calc_mode"
echo "Output Directory: $folder_name"
if [ "$use_dipole" = true ]; then
    echo "Dipole Correction: ENABLED (DIPOL = $dipol)"
else
    echo "Dipole Correction: DISABLED"
fi
echo ""
echo "=== Key INCAR Parameters ==="
grep -iE "^[[:space:]]*(NSW|IBRION|POTIM|NFREE|EDIFF)[[:space:]]*=" INCAR
if [ "$use_dipole" = true ]; then
    grep -iE "^[[:space:]]*DIPOL" INCAR
fi
if [ "$nwrite_value" != "default" ]; then
    grep -iE "^[[:space:]]*NWRITE" INCAR
else
    echo "NWRITE = (default - not specified)"
fi
echo ""
echo "=== Commented Lines ==="
grep -iE "^#[[:space:]]*(IMAGES|SPRING|LCLIMB|ICHAIN|IOPT)" INCAR 2>/dev/null || echo "No commented NEB parameters found"
if [ "$use_dipole" = false ]; then
    grep -iE "^#[[:space:]]*(DIPOL|LDIPOL|IDIPOL)" INCAR 2>/dev/null || echo "No dipole parameters found in INCAR"
fi
echo ""
echo "=== Key Settings in vasp_runscript ==="
grep "VASP_EXE=" vasp_runscript 2>/dev/null || echo "VASP_EXE setting not found"
grep -E "#SBATCH --ntasks(-per-node)?=" vasp_runscript 2>/dev/null || echo "ntasks setting not found"
grep "#SBATCH --nodes=" vasp_runscript 2>/dev/null || echo "nodes setting not found"
echo ""
echo "============================================"
echo "Setup Complete!"
echo "============================================"
echo ""
echo "############################################"
echo "#  !!  IMPORTANT REMINDERS BEFORE SUBMIT  !!"
echo "############################################"
echo ""
echo "  [1] FREEZE atoms in POSCAR:"
echo "      Edit $folder_name/POSCAR and add Selective Dynamics."
echo "      Set ONLY the molecule/adsorbate atoms to 'T T T',"
echo "      and freeze ALL other atoms (slab, substrate) with 'F F F'."
echo "      Otherwise the Hessian will be huge and frequencies"
echo "      will mix slab phonons with molecule modes."
echo ""
echo "  [2] Make sure VASP_EXE = vasp_gam in vasp_runscript."
echo "      (Gamma-only build is required since KPOINTS is now Gamma."
echo "       The script has already set this, but please double-check.)"
echo ""
echo "############################################"
echo ""
echo "Please check the files in $folder_name folder,"
echo "then submit vasp_runscript to start the calculation."
