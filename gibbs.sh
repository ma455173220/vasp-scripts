#!/bin/bash

# Gibbs calculation setup script
echo "============================================"
echo "  VASP Gibbs/Frequency Calculation Setup"
echo "============================================"
echo ""

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
    echo "Warning: $folder_name folder already exists, will remove and recreate"
    rm -rf "$folder_name"
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
    output=$(center-of-mass.py POSCAR)
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
        # Only modify DIPOL line (not affecting LDIPOL and IDIPOL)
        sed -i "s/^DIPOL\s*=.*/DIPOL = $dipol/" INCAR
        echo "Updated DIPOL = $dipol"
    else
        echo "Error: INCAR file does not exist"
        exit 1
    fi
else
    # Comment out dipole-related parameters in INCAR
    echo "Disabling dipole correction in INCAR..."
    if [ -f "INCAR" ]; then
        sed -i 's/^DIPOL\s*=/#DIPOL =/' INCAR
        sed -i 's/^LDIPOL\s*=/#LDIPOL =/' INCAR
        sed -i 's/^IDIPOL\s*=/#IDIPOL =/' INCAR
        echo "Commented out DIPOL, LDIPOL, IDIPOL"
    else
        echo "Error: INCAR file does not exist"
        exit 1
    fi
fi

# 5. Modify NSW and comment out optimization-related parameters
echo "Modifying structure optimization parameters..."

# Change NSW to 1
sed -i 's/NSW\s*=\s*[0-9]*/NSW = 1/' INCAR
echo "Changed NSW to 1"

# Comment out the entire line: IOPT = 7 ; POTIM = 0 ; IBRION = 3
sed -i 's/^IOPT = 7 ; POTIM = 0 ; IBRION = 3/#IOPT = 7 ; POTIM = 0 ; IBRION = 3/' INCAR
echo "Commented out optimizer setting line"

# Comment out NEB-related parameters (lines starting with IMAGES, SPRING, LCLIMB, ICHAIN, IOPT)
sed -i 's/^IMAGES\s*=/#IMAGES =/' INCAR
sed -i 's/^SPRING\s*=/#SPRING =/' INCAR
sed -i 's/^LCLIMB\s*=/#LCLIMB =/' INCAR
sed -i 's/^ICHAIN\s*=/#ICHAIN =/' INCAR
sed -i 's/^IOPT\s*=/#IOPT =/' INCAR
echo "Commented out NEB-related parameters (IMAGES, SPRING, LCLIMB, ICHAIN, IOPT)"

# Modify EDIFF to 1E-07
if grep -q "^EDIFF\s*=" INCAR; then
    sed -i 's/^EDIFF\s*=.*/EDIFF = 1E-07/' INCAR
    echo "Changed EDIFF to 1E-07"
else
    echo "EDIFF = 1E-07" >> INCAR
    echo "Added EDIFF = 1E-07"
fi

# 6. Set Gibbs calculation parameters
echo "Setting Gibbs calculation parameters..."

# Set or modify IBRION to 5
if grep -q "^IBRION\s*=" INCAR; then
    sed -i 's/^IBRION\s*=.*/IBRION = 5/' INCAR
else
    echo "IBRION = 5" >> INCAR
fi

# Set or modify POTIM to 0.015
if grep -q "^POTIM\s*=" INCAR; then
    sed -i 's/^POTIM\s*=.*/POTIM = 0.015/' INCAR
else
    echo "POTIM = 0.015" >> INCAR
fi

# Set or modify NFREE to 2
if grep -q "^NFREE\s*=" INCAR; then
    sed -i 's/^NFREE\s*=.*/NFREE = 2/' INCAR
else
    echo "NFREE = 2" >> INCAR
fi

# Handle NWRITE based on calculation type
if [ "$nwrite_value" = "default" ]; then
    # For regular Gibbs calculation, remove NWRITE line if it exists
    if grep -q "^NWRITE\s*=" INCAR; then
        sed -i '/^NWRITE\s*=/d' INCAR
        echo "Removed NWRITE (using default value)"
    else
        echo "NWRITE not found in INCAR (will use default value)"
    fi
else
    # For IDM calculation, set NWRITE = 3
    if grep -q "^NWRITE\s*=" INCAR; then
        sed -i "s/^NWRITE\s*=.*/NWRITE = $nwrite_value/" INCAR
    else
        echo "NWRITE = $nwrite_value" >> INCAR
    fi
    echo "Set NWRITE = $nwrite_value (for IDM frequency analysis)"
fi

echo "Set IBRION = 5, POTIM = 0.015, NFREE = 2"

# 7. Modify VASP_EXE in vasp_runscript
echo "Modifying vasp_runscript..."
if [ -f "vasp_runscript" ]; then
    sed -i 's/VASP_EXE="vasp_std"/VASP_EXE="vasp_gam"/' vasp_runscript
    echo "Changed VASP_EXE to vasp_gam"
    
    # Modify SBATCH ntasks to 128
    sed -i 's/^#SBATCH --ntasks=[0-9]*/#SBATCH --ntasks=128/' vasp_runscript
    echo "Changed #SBATCH --ntasks to 128"
    
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
grep -E "^(NSW|IBRION|POTIM|NFREE|EDIFF)" INCAR
if [ "$use_dipole" = true ]; then
    grep "^DIPOL" INCAR
fi
if [ "$nwrite_value" != "default" ]; then
    grep "^NWRITE" INCAR
else
    echo "NWRITE = (default - not specified)"
fi
echo ""
echo "=== Commented Lines ==="
grep "^#IOPT = 7" INCAR
grep "^#IMAGES\|^#SPRING\|^#LCLIMB\|^#ICHAIN\|^#IOPT" INCAR 2>/dev/null || echo "No commented NEB parameters found"
if [ "$use_dipole" = false ]; then
    grep "^#DIPOL\|^#LDIPOL\|^#IDIPOL" INCAR 2>/dev/null || echo "No dipole parameters found in INCAR"
fi
echo ""
echo "=== Key Settings in vasp_runscript ==="
grep "VASP_EXE=" vasp_runscript 2>/dev/null || echo "VASP_EXE setting not found"
grep "#SBATCH --ntasks=" vasp_runscript 2>/dev/null || echo "ntasks setting not found"
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
