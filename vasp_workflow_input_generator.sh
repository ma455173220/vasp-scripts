#!/bin/bash
# =====================================================
# Auto-generate INCAR_step0 (optional gamma-only pre-opt)
# Auto-generate INCAR_step1, INCAR_step2, INCAR_scf, INCAR_band, INCAR_dos
# Auto-generate KPOINTS_scf, KPOINTS_band, KPOINTS_dos
# Auto-generate vasp_runscript for each step
# Auto-generate workflow execution script
# =====================================================

# ===== DEPENDENCY CHECK =====
echo "============================================================"
echo ">>> CHECKING EXTERNAL DEPENDENCIES"
echo "============================================================"

DEPENDENCIES_OK=true
MISSING_DEPS=()

# Function to check if command exists
check_command() {
    local cmd=$1
    local description=$2
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "✅ $cmd - $description"
    else
        echo "❌ $cmd - $description (NOT FOUND)"
        DEPENDENCIES_OK=false
        MISSING_DEPS+=("$cmd")
    fi
}

# Function to check if file exists and is executable
check_script() {
    local script=$1
    local description=$2
    if [ -f "$script" ] ; then
        echo "✅ $script - $description"
    else
        echo "❌ $script - $description (NOT FOUND)"
        DEPENDENCIES_OK=false
        MISSING_DEPS+=("$script")
    fi
}

echo ""
echo "Checking essential system commands..."
check_command "sbatch" "SLURM job submission system"
check_command "squeue" "SLURM job queue query"
check_command "grep" "Text pattern matching"
check_command "sed" "Stream text editor"
check_command "awk" "Text processing tool"

echo ""
echo "Checking VASP-related tools..."
check_command "vaspkit" "VASP toolkit for generating KPOINTS"

echo ""
echo "Checking Python scripts (if exist)..."
# Common Python scripts that might be used
check_command "center-of-mass.py" "Center of mass calculation for dipole correction"

echo ""
echo "Checking base runscript template..."
RUNSCRIPT_BASE="vasp_runscript"  # This will be configurable later
check_script "$RUNSCRIPT_BASE" "Base VASP submission script template"

echo ""
echo "Checking required input files..."
if [ -f "INCAR" ]; then
    echo "✅ INCAR - Base VASP input parameters"
else
    echo "❌ INCAR - Base VASP input parameters (NOT FOUND)"
    DEPENDENCIES_OK=false
    MISSING_DEPS+=("INCAR")
fi

if [ -f "POSCAR" ]; then
    echo "✅ POSCAR - Crystal structure"
else
    echo "❌ POSCAR - Crystal structure (NOT FOUND)"
    DEPENDENCIES_OK=false
    MISSING_DEPS+=("POSCAR")
fi

if [ -f "POTCAR" ]; then
    echo "✅ POTCAR - Pseudopotential file"
else
    echo "❌ POTCAR - Pseudopotential file (NOT FOUND)"
    DEPENDENCIES_OK=false
    MISSING_DEPS+=("POTCAR")
fi

echo ""
echo "============================================================"
if [ "$DEPENDENCIES_OK" = true ]; then
    echo "✅ ALL DEPENDENCIES SATISFIED - Proceeding with workflow setup"
    echo "============================================================"
else
    echo "❌ MISSING DEPENDENCIES DETECTED"
    echo "============================================================"
    echo ""
    echo "The following dependencies are missing or not accessible:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  • $dep"
    done
    echo ""
    echo "Please ensure all dependencies are installed and accessible before running this script."
    echo ""
    echo "Common solutions:"
    echo "  • For SLURM commands (sbatch, squeue): Make sure you're on a SLURM-managed cluster"
    echo "  • For vaspkit: Install from https://vaspkit.com/"
    echo "  • For VASP files (INCAR, POSCAR, POTCAR): Prepare these input files first"
    echo "  • For runscript template: Create a base submission script named '$RUNSCRIPT_BASE'"
    echo "  • For Python scripts: Ensure Python is installed and scripts are in current directory"
    echo ""
    read -p "Continue anyway? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting..."
        exit 1
    fi
    echo "⚠️ Continuing with missing dependencies - some features may not work correctly"
    echo "============================================================"
fi

ROOT_DIR=$(pwd)

# ===== Configurable variable for runscript base name =====
RUNSCRIPT_BASE="vasp_runscript"  # Change this prefix to customize submission script names
                                 # Scripts will be ${RUNSCRIPT_BASE}_step0, ${RUNSCRIPT_BASE}_step1, ${RUNSCRIPT_BASE}_scf, etc.

# ===== Function: separator =====
separator() {
    echo "============================================================"
    echo ">>> $1"
}

# ===== Function: get_vasp_exe =====
get_vasp_exe() {
    local runscript_file=$1
    if [ -f "$runscript_file" ]; then
        grep "VASP_EXE=" "$runscript_file" | sed 's/.*VASP_EXE="\([^"]*\)".*/\1/'
    else
        echo "unknown"
    fi
}

# ===== Function: update_key =====
update_key() {
    local file=$1
    local key=$2
    local value=$3
    local comment=$4

    active_count=$(grep -i "^[[:space:]]*$key[[:space:]]*=" "$file" | wc -l)

    if (( active_count > 1 )); then
        echo "⚠️ Multiple active $key found in $file. Keeping first and commenting out others."
        awk -v key="$key" '
        BEGIN{IGNORECASE=1; count=0}
        {
            if ($0 ~ "^[[:space:]]*"key"[[:space:]]*=") {
                count++
                if (count > 1) {
                    sub(/^([[:space:]]*)/, "&#")
                    print $0
                } else {
                    print $0
                }
            } else {
                print $0
            }
        }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi

    if [[ "$value" == "COMMENT" ]]; then
        if grep -qi "^[[:space:]]*$key[[:space:]]*=" "$file"; then
            sed -i "0,/^[[:space:]]*$key[[:space:]]*=/s//\#&/" "$file"
            echo "🔧 $key commented in $file"
        else
            echo "ℹ️ $key not found in $file, nothing to comment"
        fi
        return
    fi

    if grep -qi "$key" "$file"; then
        sed -i "0,/^\(#\s*\)\?\s*$key\s*=.*/s//${key} = ${value}    #${comment}/" "$file"
        echo "🔧 $key set to $value in $file"
    else
        echo "${key} = ${value}    #${comment}" >> "$file"
        echo "➕ $key added as $value in $file"
    fi
}

# ===== Function: update_runscript =====
update_runscript() {
    local runscript_file=$1
    local jobname=$2
    local kpoints_file=$3
    
    # Determine VASP_EXE based on k-mesh in KPOINTS file
    local vasp_exe="vasp_std"  # default
    
    if [ -f "$kpoints_file" ]; then
        # Read the fourth line of KPOINTS file which contains the k-mesh
        local kmesh_line=$(sed -n '4p' "$kpoints_file")
        # Extract k-mesh values
        local kx=$(echo $kmesh_line | awk '{print $1}')
        local ky=$(echo $kmesh_line | awk '{print $2}')
        local kz=$(echo $kmesh_line | awk '{print $3}')
        
        # Check if it's gamma-only (1 1 1)
        if [[ "$kx" == "1" && "$ky" == "1" && "$kz" == "1" ]]; then
            vasp_exe="vasp_gam"
            echo "🔍 Detected 1×1×1 k-mesh in $kpoints_file → using vasp_gam"
        else
            vasp_exe="vasp_std"
            echo "🔍 Detected ${kx}×${ky}×${kz} k-mesh in $kpoints_file → using vasp_std"
        fi
    else
        echo "⚠️ KPOINTS file $kpoints_file not found, defaulting to vasp_std"
    fi
    
    # Update JOBNAME
    if grep -q "JOBNAME=" "$runscript_file"; then
        sed -i "s/JOBNAME=\"[^\"]*\"/JOBNAME=\"${jobname}\"/" "$runscript_file"
        echo "🔧 JOBNAME set to ${jobname} in $runscript_file"
    else
        echo "⚠️ JOBNAME not found in $runscript_file"
    fi
    
    # Update VASP_EXE
    if grep -q "VASP_EXE=" "$runscript_file"; then
        sed -i "s/VASP_EXE=\"[^\"]*\"/VASP_EXE=\"${vasp_exe}\"/" "$runscript_file"
        echo "🔧 VASP_EXE set to ${vasp_exe} in $runscript_file"
    else
        echo "⚠️ VASP_EXE not found in $runscript_file"
    fi
}

# ===== User prompts =====
echo "============================================================"
echo ">>> WORKFLOW CONFIGURATION"
echo ""

# Prompt for prefix
read -p "Enter prefix for workflow script name (e.g., 'BTO-s231'): " PREFIX
if [[ -z "$PREFIX" ]]; then
    PREFIX="workflow"
fi
WORKFLOW_SCRIPT="${PREFIX}.sh"

echo ""
echo ">>> GAMMA-ONLY PRE-OPTIMIZATION OPTION"
echo "Would you like to perform a gamma-only pre-optimization before step1?"
echo "This can be useful for large systems to get a rough initial structure."
read -p "Enter [y/n]: " -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    PERFORM_STEP0=true
    echo "✅ Gamma-only pre-optimization (step0) will be included."
else
    PERFORM_STEP0=false
    echo "ℹ️ Skipping gamma-only pre-optimization."
fi

# ===== Step 0 (Optional Gamma-only pre-optimization) =====
if [ "$PERFORM_STEP0" = true ]; then
    separator "STEP 0: Generating INCAR_step0 (Gamma-only pre-optimization)"
    cp INCAR INCAR_step0
    echo -e "102\n1\n0\n" | vaspkit > /dev/null 2>&1
    mv KPOINTS KPOINTS_step0
    echo "🔧 KPOINTS_step0 generated (Gamma-only)."
    cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step0"
    update_runscript "${RUNSCRIPT_BASE}_step0" "00" "KPOINTS_step0"
    echo "✅ Step0 files created for gamma-only pre-optimization."
fi

# ===== Step 1 =====
separator "STEP 1: Generating INCAR_step1"
cp INCAR INCAR_step1
echo -e "102\n1\n0.04\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_step1
echo "🔧 KPOINTS_step1 generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step1"
update_runscript "${RUNSCRIPT_BASE}_step1" "01" "KPOINTS_step1"

# ===== Step 2 =====
separator "STEP 2: Generating INCAR_step2"
cp INCAR INCAR_step2
update_key INCAR_step2 "LREAL" "COMMENT" "Disable LREAL=Auto for second optimization"
echo -e "102\n1\n0.04\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_step2
echo "🔧 KPOINTS_step2 generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step2"
update_runscript "${RUNSCRIPT_BASE}_step2" "02" "KPOINTS_step2"

# ===== Step 3 =====
separator "STEP 3: Generating INCAR_scf"
cp INCAR_step2 INCAR_scf
update_key INCAR_scf "LWAVE"  ".TRUE."   "Write WAVECAR"
update_key INCAR_scf "LCHARG" ".TRUE."   "Write CHGCAR"
update_key INCAR_scf "LAECHG" ".TRUE."   "Write AECCAR for Bader analysis"
update_key INCAR_scf "NSW"    "0"        "Non-SCF calculation"
update_key INCAR_scf "IBRION" "-1"       "Non-SCF calculation"
update_key INCAR_scf "IOPT"   "COMMENT"  "Disable IOPT for SCF"
update_key INCAR_scf "ICORELEVEL" "1" "Core energies"
# update_key INCAR_scf "LVHAR" ".TRUE."    "Write total local potential"

# ===== Step 4 =====
echo ">>> STEP 4: LMAXMIX Adjustment based on POSCAR"
if [ -f "POSCAR" ]; then
    echo "Checking elements in POSCAR for LMAXMIX adjustment..."
    elements=$(awk 'NR==6 {for (i=1; i<=NF; i++) print $i}' POSCAR)

    d_elements=("Sc" "Ti" "V" "Cr" "Mn" "Fe" "Co" "Ni" "Cu" "Zn" "Y" "Zr" "Nb" "Mo" "Tc" "Ru" "Rh" "Pd" "Ag" "Cd" "W" "Pt" "Au" "Hg")
    lanthanides=("La" "Ce" "Pr" "Nd" "Pm" "Sm" "Eu" "Gd" "Tb" "Dy" "Ho" "Er" "Tm" "Yb" "Lu")
    actinides=("Th" "Pa" "U" "Np" "Pu" "Am" "Cm" "Bk" "Cf" "Es" "Fm" "Md" "No" "Lr")

    contains_d=false
    contains_f=false

    for e in $elements; do
        if [[ " ${d_elements[@]} " =~ " $e " ]]; then contains_d=true; fi
        if [[ " ${lanthanides[@]} " =~ " $e " || " ${actinides[@]} " =~ " $e " ]]; then contains_f=true; fi
    done

    if [ "$contains_f" = true ]; then
        update_key INCAR_scf "LMAXMIX" "6" "f-electron detected"
    elif [ "$contains_d" = true ]; then
        update_key INCAR_scf "LMAXMIX" "4" "d-electron detected"
    else
        echo "ℹ️ No d/f electrons detected, LMAXMIX unchanged."
    fi
fi

# ===== Step 5 =====
echo ">>> STEP 5: Generating KPOINTS_scf"
echo -e "102\n1\n0.03\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_scf
echo "🔧 KPOINTS_scf generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_scf"
update_runscript "${RUNSCRIPT_BASE}_scf" "03" "KPOINTS_scf"

# ===== Step 6 =====
separator "STEP 6: Generating INCAR_band"
cp INCAR_scf INCAR_band
update_key INCAR_band "ICHARG" "11"     "Band structure calculation"
update_key INCAR_band "LWAVE"  ".FALSE." "Disable WAVECAR"
update_key INCAR_band "LCHARG" ".FALSE." "Disable CHGCAR"
update_key INCAR_band "LAECHG" ".FALSE." "Disable AECCAR"
update_key INCAR_band "ICORELEVEL" "COMMENT" "Core energies"
update_key INCAR_band "LVHAR" "COMMENT"    "Write total local potential"
echo ">>> STEP 7: Generating KPOINTS_band"
echo -e "303\n" | vaspkit > /dev/null 2>&1
mv KPATH.in KPOINTS_band
echo "🔧 KPOINTS_band generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_band"
update_runscript "${RUNSCRIPT_BASE}_band" "04" "KPOINTS_band"

# ===== Step 8 =====
separator "STEP 8: Generating INCAR_dos"
cp INCAR_band INCAR_dos
update_key INCAR_dos "NEDOS"  "3001" "DOS calculation points"
update_key INCAR_dos "LORBIT" "11"   "Projection for DOS"
echo "⚠️ Please manually set EMIN and EMAX in INCAR_dos according to your system!"
echo ">>> STEP 9: Generating KPOINTS_dos"
echo -e "102\n1\n0.02\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_dos
echo "🔧 KPOINTS_dos generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_dos"
update_runscript "${RUNSCRIPT_BASE}_dos" "05" "KPOINTS_dos"

# ===== Generate workflow execution script =====
separator "Generating workflow execution script: $WORKFLOW_SCRIPT"

cat > "$WORKFLOW_SCRIPT" << 'EOL'
#!/bin/bash

##############################################
# ===== USER CONFIGURATION =====
# Define which steps to run:
EOL

if [ "$PERFORM_STEP0" = true ]; then
cat >> "$WORKFLOW_SCRIPT" << 'EOL'
# 0 = Step 0 Gamma-only Pre-optimization
EOL
fi

cat >> "$WORKFLOW_SCRIPT" << 'EOL'
# 1 = Step 1 Initial Optimization
# 2 = Step 2 LREAL=FALSE Optimization
# 3 = Step 3 SCF
# 4 = Step 4 Band Structure
# 5 = Step 5 DOS
#
# Example:
EOL

if [ "$PERFORM_STEP0" = true ]; then
cat >> "$WORKFLOW_SCRIPT" << 'EOL'
# RUN_STEPS=(0 1 2 3 4 5)   # Run all steps including gamma-only pre-opt
# RUN_STEPS=(1 2 3 4 5)     # Skip gamma-only pre-opt, run all others
EOL
else
cat >> "$WORKFLOW_SCRIPT" << 'EOL'
# RUN_STEPS=(1 2 3 4 5)     # Run all steps
EOL
fi

cat >> "$WORKFLOW_SCRIPT" << 'EOL'
# RUN_STEPS=(3 4 5)         # Skip optimization, run SCF + Band + DOS
# RUN_STEPS=(4)             # Only run Band (requires SCF already done)
##############################################
EOL

if [ "$PERFORM_STEP0" = true ]; then
cat >> "$WORKFLOW_SCRIPT" << EOL
RUN_STEPS=(0 1 2 3)
EOL
else
cat >> "$WORKFLOW_SCRIPT" << EOL
RUN_STEPS=(1 2 3)
EOL
fi

cat >> "$WORKFLOW_SCRIPT" << EOL
JOB_NAME="${PREFIX}_workflow"

# Whether to apply dipole correction (true/false)
# 1 = enable dipole correction, 0 = disable
USE_DIPOL_CORR=0

# ===== Submission script base name (customize here) =====
RUNSCRIPT_BASE="$RUNSCRIPT_BASE"  # Change this prefix to customize submission script names
                                 # Scripts will be \${RUNSCRIPT_BASE}_step1, \${RUNSCRIPT_BASE}_scf, etc.

##############################################
# ===== PATH CONFIGURATION =====
ROOT_DIR=\$(pwd)                       # Root working directory
SCF_DIR="\$ROOT_DIR/NON-SC-kmesh-0.03" # SCF output directory
BAND_DIR="\$ROOT_DIR/BAND"             # Band structure directory
DOS_DIR="\$ROOT_DIR/DOS"               # DOS directory

LOGFILE="\$ROOT_DIR/vasp_workflow_status.log"
SUB_CMD="sbatch --job-name=\$JOB_NAME" # Command to submit jobs

echo "=== Workflow Started ===" > "\$LOGFILE"
echo "Selected Steps: \${RUN_STEPS[@]}" >> "\$LOGFILE"

##############################################
# ===== FUNCTION: Check Job Completion =====
# Waits for a submitted job to finish and checks OUTCAR for convergence
# \$1 → Step number
# \$2 → Job ID
# \$3 → Mode ("opt" or "scf")
# \$4 → Directory containing OUTCAR
##############################################
check_job_done() {
    local step=\$1
    local jobid=\$2
    local check_mode=\$3
    local workdir=\$4

    while true; do
        # Wait while job is still in queue
        if squeue -j \$jobid 2>/dev/null | grep -q "\$jobid"; then
            sleep 60
        else
            OUTCAR_FILE="\$workdir/OUTCAR"
            # Check convergence conditions
            if [[ \$check_mode == "opt" ]]; then
                grep -q "Total CPU time used" "\$OUTCAR_FILE" && grep -q "reached required accuracy" "\$OUTCAR_FILE" \\
                    && echo "✅ Step \$step completed successfully." >> "\$LOGFILE" \\
                    || { echo "❌ Step \$step failed." >> "\$LOGFILE"; exit 1; }
            elif [[ \$check_mode == "scf" ]]; then
                grep -q "Total CPU time used" "\$OUTCAR_FILE" && grep -q "EDIFF is reached" "\$OUTCAR_FILE" \\
                    && echo "✅ Step \$step completed successfully." >> "\$LOGFILE" \\
                    || { echo "❌ Step \$step failed." >> "\$LOGFILE"; exit 1; }
            fi
            break
        fi
    done
}
EOL

if [ "$PERFORM_STEP0" = true ]; then
cat >> "$WORKFLOW_SCRIPT" << 'EOL'

##############################################
# ===== STEP 0: Gamma-only Pre-optimization =====
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 0 " ]]; then
    echo "=== Step 0: Gamma-only Pre-optimization Started ===" >> "$LOGFILE"
    cp INCAR_step0 INCAR
    cp KPOINTS_step0 KPOINTS
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        com=$(center-of-mass.py POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
        sed -i "s/^DIPOL *=.*/DIPOL = $com/" INCAR
    fi
    JOBID0=$($SUB_CMD ${RUNSCRIPT_BASE}_step0 | awk '{print $NF}')
    check_job_done 0 $JOBID0 "opt" "$ROOT_DIR"
    echo "Copying CONTCAR to POSCAR for next step..." >> "$LOGFILE"
    cp CONTCAR POSCAR
fi
EOL
fi

cat >> "$WORKFLOW_SCRIPT" << 'EOL'

##############################################
# ===== STEP 1: Initial Optimization =====
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 1 " ]]; then
    echo "=== Step 1: Initial Optimization Started ===" >> "$LOGFILE"
    cp INCAR_step1 INCAR
    cp KPOINTS_step1 KPOINTS
EOL

if [ "$PERFORM_STEP0" = true ]; then
cat >> "$WORKFLOW_SCRIPT" << 'EOL'
    # Use CONTCAR from step0 if step0 was run, otherwise use current POSCAR
    if [[ " ${RUN_STEPS[@]} " =~ " 0 " ]]; then
        echo "Using optimized structure from step0..." >> "$LOGFILE"
    fi
EOL
fi

cat >> "$WORKFLOW_SCRIPT" << 'EOL'
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        com=$(center-of-mass.py POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
        sed -i "s/^DIPOL *=.*/DIPOL = $com/" INCAR
    fi
    JOBID1=$($SUB_CMD ${RUNSCRIPT_BASE}_step1 | awk '{print $NF}')
    check_job_done 1 $JOBID1 "opt" "$ROOT_DIR"
    echo "Copying CONTCAR to POSCAR for next step..." >> "$LOGFILE"
    cp CONTCAR POSCAR
fi

##############################################
# ===== STEP 2: LREAL=FALSE Optimization =====
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 2 " ]]; then
    echo "=== Step 2: LREAL=FALSE Optimization Started ===" >> "$LOGFILE"
    cp INCAR_step2 INCAR
    cp KPOINTS_step2 KPOINTS
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        com=$(center-of-mass.py POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
        sed -i "s/^DIPOL *=.*/DIPOL = $com/" INCAR
    fi
    JOBID2=$($SUB_CMD ${RUNSCRIPT_BASE}_step2 | awk '{print $NF}')
    check_job_done 2 $JOBID2 "opt" "$ROOT_DIR"
fi

##############################################
# ===== STEP 3: SCF Calculation =====
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 3 " ]]; then
    echo "=== Step 3: SCF Started ===" >> "$LOGFILE"
    mkdir -p "$SCF_DIR"
    cp ${RUNSCRIPT_BASE}_scf "$SCF_DIR/"
    cp INCAR_scf "$SCF_DIR/INCAR"
    cp KPOINTS_scf "$SCF_DIR/KPOINTS"
    cp POTCAR "$SCF_DIR/"
    cp CONTCAR "$SCF_DIR/POSCAR"
    cd "$SCF_DIR"
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        com=$(center-of-mass.py POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
        sed -i "s/^DIPOL *=.*/DIPOL = $com/" INCAR
    fi
    JOBID3=$($SUB_CMD ${RUNSCRIPT_BASE}_scf | awk '{print $NF}')
    check_job_done 3 $JOBID3 "scf" "$SCF_DIR"
    cd "$ROOT_DIR"
fi

##############################################
# ===== STEP 4: Band Structure =====
##############################################
run_band() {
    echo "=== Step 4: Band Structure Started ===" >> "$LOGFILE"
    mkdir -p "$BAND_DIR"
    cd "$BAND_DIR"
    ln -sf "$SCF_DIR/CHGCAR" CHGCAR      # Link SCF charge density
    cp "$SCF_DIR/POSCAR" POSCAR          # Use SCF structure
    cp "$ROOT_DIR/POTCAR" POTCAR
    cp "$ROOT_DIR/INCAR_band" INCAR
    cp "$ROOT_DIR/KPOINTS_band" KPOINTS
    cp "$ROOT_DIR/${RUNSCRIPT_BASE}_band" ${RUNSCRIPT_BASE}_band
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        com=$(center-of-mass.py POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
        sed -i "s/^DIPOL *=.*/DIPOL = $com/" INCAR
    fi
    JOBID4=$($SUB_CMD ${RUNSCRIPT_BASE}_band | awk '{print $NF}')
    check_job_done 4 $JOBID4 "scf" "$BAND_DIR"
    cd "$ROOT_DIR"
}

##############################################
# ===== STEP 5: DOS Calculation =====
##############################################
run_dos() {
    echo "=== Step 5: DOS Calculation Started ===" >> "$LOGFILE"
    mkdir -p "$DOS_DIR"
    cd "$DOS_DIR"
    ln -sf "$SCF_DIR/CHGCAR" CHGCAR      # Link SCF charge density
    cp "$SCF_DIR/POSCAR" POSCAR          # Use SCF structure
    cp "$ROOT_DIR/POTCAR" POTCAR
    cp "$ROOT_DIR/INCAR_dos" INCAR
    cp "$ROOT_DIR/KPOINTS_dos" KPOINTS
    cp "$ROOT_DIR/${RUNSCRIPT_BASE}_dos" ${RUNSCRIPT_BASE}_dos
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        com=$(center-of-mass.py POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
        sed -i "s/^DIPOL *=.*/DIPOL = $com/" INCAR
    fi
    JOBID5=$($SUB_CMD ${RUNSCRIPT_BASE}_dos | awk '{print $NF}')
    check_job_done 5 $JOBID5 "scf" "$DOS_DIR"
    cd "$ROOT_DIR"
}

##############################################
# ===== STEP 4 & 5 Execution Logic =====
# If both 4 and 5 selected → run in parallel
# If only one selected → run that one alone
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 4 " && " ${RUN_STEPS[@]} " =~ " 5 " ]]; then
    echo "=== Step 4 & 5: Running Band and DOS in Parallel ===" >> "$LOGFILE"

    # Start BAND in background
    run_band &
    PID_BAND=$!

    # Start DOS in background
    run_dos &
    PID_DOS=$!

    # Wait for both to finish
    wait $PID_BAND
    STATUS_BAND=$?
    wait $PID_DOS
    STATUS_DOS=$?

    # Check results
    if [[ $STATUS_BAND -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ Error: Band Structure step failed (PID=$PID_BAND)" >> "$LOGFILE"
        exit 1
    fi
    if [[ $STATUS_DOS -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ Error: DOS step failed (PID=$PID_DOS)" >> "$LOGFILE"
        exit 1
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Step 4 & 5 completed successfully." >> "$LOGFILE"
elif [[ " ${RUN_STEPS[@]} " =~ " 4 " ]]; then
    run_band
elif [[ " ${RUN_STEPS[@]} " =~ " 5 " ]]; then
    run_dos
fi

echo "=== Workflow Completed at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOGFILE"
EOL

chmod +x "$WORKFLOW_SCRIPT"

echo "============================================================"
if [ "$PERFORM_STEP0" = true ]; then
    echo "✅ All files generated successfully including step0 (gamma-only pre-optimization):"
    echo "   - INCAR_step0, KPOINTS_step0, ${RUNSCRIPT_BASE}_step0 (JOBNAME=00, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step0"))"
    echo "   - INCAR_step1, KPOINTS_step1, ${RUNSCRIPT_BASE}_step1 (JOBNAME=01, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step1"))"
    echo "   - INCAR_step2, KPOINTS_step2, ${RUNSCRIPT_BASE}_step2 (JOBNAME=02, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step2"))"
    echo "   - INCAR_scf, KPOINTS_scf, ${RUNSCRIPT_BASE}_scf (JOBNAME=03, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_scf"))"
    echo "   - INCAR_band, KPOINTS_band, ${RUNSCRIPT_BASE}_band (JOBNAME=04, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_band"))"
    echo "   - INCAR_dos, KPOINTS_dos, ${RUNSCRIPT_BASE}_dos (JOBNAME=05, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_dos"))"
    echo ""
    echo "🎯 Generated workflow execution script: $WORKFLOW_SCRIPT"
    echo ""
    echo "📋 Recommended workflow with gamma-only pre-optimization:"
    echo "   1. Edit $WORKFLOW_SCRIPT to select desired steps (RUN_STEPS array)"
    echo "   2. Run \"nohup ./$WORKFLOW_SCRIPT &\" to execute the workflow"
    echo ""
    echo "   Default steps: Step0 (gamma-only) → Step1 → Step2 → SCF"
    echo "   Full workflow: Step0 → Step1 → Step2 → SCF → Band & DOS"
else
    echo "✅ All INCAR_xxx, KPOINTS_xxx, and ${RUNSCRIPT_BASE}_xxx generated successfully:"
    echo "   - INCAR_step1, KPOINTS_step1, ${RUNSCRIPT_BASE}_step1 (JOBNAME=01, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step1"))"
    echo "   - INCAR_step2, KPOINTS_step2, ${RUNSCRIPT_BASE}_step2 (JOBNAME=02, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step2"))"
    echo "   - INCAR_scf, KPOINTS_scf, ${RUNSCRIPT_BASE}_scf (JOBNAME=03, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_scf"))"
    echo "   - INCAR_band, KPOINTS_band, ${RUNSCRIPT_BASE}_band (JOBNAME=04, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_band"))"
    echo "   - INCAR_dos, KPOINTS_dos, ${RUNSCRIPT_BASE}_dos (JOBNAME=05, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_dos"))"
    echo ""
    echo "🎯 Generated workflow execution script: $WORKFLOW_SCRIPT"
    echo ""
    echo "📋 Standard workflow:"
    echo "   1. Edit $WORKFLOW_SCRIPT to select desired steps (RUN_STEPS array)"
    echo "   2. Run \"nohup ./$WORKFLOW_SCRIPT &\" to execute the workflow"
    echo ""
    echo "   Default steps: Step1 → Step2 → SCF"
    echo "   Full workflow: Step1 → Step2 → SCF → Band & DOS"
fi
echo ""
echo "⚠️ IMPORTANT NOTES:"
echo "   • VASP_EXE is automatically set based on k-mesh in KPOINTS files:"
echo "     - vasp_gam for 1×1×1 k-mesh (gamma-only calculations)"
echo "     - vasp_std for all other k-meshes"
echo "   • For large systems, even with denser k-mesh settings, you might still get 1×1×1"
echo "   • Always check the console output above to see which VASP executable was assigned"
echo "   • The workflow script $WORKFLOW_SCRIPT includes automatic dipole correction"
echo "   • Modify USE_DIPOL_CORR=1 in $WORKFLOW_SCRIPT if dipole correction is needed"
