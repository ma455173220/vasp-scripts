#!/bin/bash
# =====================================================
# vasp_workflow_input_generator.sh - PBS (Gadi) and Slurm (Setonix)
#
# Generates INCAR_step0 (optional gamma-only pre-opt), INCAR_step1, INCAR_step2,
# INCAR_scf, INCAR_band, INCAR_dos, the matching KPOINTS_* and ${RUNSCRIPT_BASE}_*
# job scripts, and a workflow script <prefix>.sh that submits the steps one after
# another (run it with: nohup ./<prefix>.sh &). The workflow skips steps that have
# already finished, so it can simply be started again after it was killed.
#
# Usage: vasp_workflow_input_generator.sh [options]     (asks for anything not given)
#   --scheduler auto|pbs|slurm  job system (auto: from the job script header, else
#                               the command on PATH)
#   --prefix NAME               workflow script name (NAME.sh), PBS -N / Slurm job name
#   --steps "0 1 2 ..."         steps to generate and run: 0 gamma pre-opt, 1 opt,
#                               2 LREAL=F opt, 3 SCF, 4 band, 5 DOS (default: all)
#   --run "..."                 steps the workflow runs (default: --steps)
#   --offset N                  JOBNAME offset for step0/1/2 (jobs 00, 01 exist already)
#   --dipole y|n                dipole correction (DIPOL from the centre of mass)
#   --scf-dir NAME              SCF directory name
#   --runscript NAME            job script template (default: vasp_runscript)
#   --style gadi|setonix        prompts / job numbering / SCF directory of the old
#                               scripts (default: gadi for PBS, setonix for Slurm)
#   --yes                       continue even if dependency checks fail
#   -h, --help
#
# Old names: vasp_workflow_input_generator_gadi.sh (= --scheduler pbs) and
# vasp_workflow_input_generator_setonix.sh (= --scheduler slurm) still work,
# including answers piped to stdin.
#
# Styles (only the defaults differ; flags override them):
#   gadi    : asks prefix, gamma pre-opt y/n, dipole; generates every step and runs
#             0 1 2 (or 1 2); JOBNAME 00-02 (+offset) for step0-2, 03/04/05 for
#             SCF/band/DOS; SCF directory NON-SC-kmesh-0.03
#   setonix : asks prefix, offset, steps, dipole; runs the selected steps; JOBNAME
#             from the offset for step0-2, 00 for SCF/band/DOS; SCF-kmesh-0.03
# =====================================================

# ===== Shared helpers (incar_*, poscar_*, sched_of, submit_job, ...): next to this script, else PATH =====
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"
[ -f "$_lib" ] || _lib=$(command -v vasp_common.sh)
[ -n "$_lib" ] || { echo "❌ vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"
VASP_COMMON="$_lib"

# ===== Command line =====
SCHEDULER="auto"
STYLE=""
PREFIX=""
OPT_STEPS=""
OPT_RUN=""
JOB_OFFSET=""
OPT_DIPOLE=""
SCF_DIR_NAME=""
RUNSCRIPT_BASE="vasp_runscript"  # Change this prefix to customize submission script names
ASSUME_YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        --scheduler) SCHEDULER="$2"; shift ;;
        --style) STYLE="$2"; shift ;;
        --prefix) PREFIX="$2"; shift ;;
        --steps) OPT_STEPS="$2"; shift ;;
        --run) OPT_RUN="$2"; shift ;;
        --offset) JOB_OFFSET="$2"; shift ;;
        --dipole) OPT_DIPOLE="$2"; shift ;;
        --scf-dir) SCF_DIR_NAME="$2"; shift ;;
        --runscript) RUNSCRIPT_BASE="$2"; shift ;;
        --yes|-y) ASSUME_YES=true ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "❌ Unknown option: $1 (use --help)"; exit 1 ;;
    esac
    shift
done
case "$SCHEDULER" in
    auto) SCHEDULER=$(sched_of "$RUNSCRIPT_BASE") ;;
    pbs|slurm) ;;
    *) echo "❌ --scheduler must be auto, pbs or slurm"; exit 1 ;;
esac
[ -n "$STYLE" ] || { [ "$SCHEDULER" = pbs ] && STYLE=gadi || STYLE=setonix; }
[ -n "$SCF_DIR_NAME" ] || { [ "$STYLE" = gadi ] && SCF_DIR_NAME="NON-SC-kmesh-0.03" || SCF_DIR_NAME="SCF-kmesh-0.03"; }

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
if [ "$SCHEDULER" = pbs ]; then
    check_command "qsub" "PBS job submission system"
    check_command "qstat" "PBS job queue query"
else
    check_command "sbatch" "SLURM job submission system"
    check_command "squeue" "SLURM job queue query"
fi
check_command "grep" "Text pattern matching"
check_command "sed" "Stream text editor"
check_command "awk" "Text processing tool"

echo ""
echo "Checking VASP-related tools..."
check_command "vaspkit" "VASP toolkit for generating KPOINTS"

echo ""
echo "Checking Python scripts (if exist)..."
# center-of-mass.py: next to vasp_common.sh / this script, then PATH
COM_SCRIPT=$(find_tool center-of-mass.py)
if [ -n "$COM_SCRIPT" ]; then
    echo "✅ $COM_SCRIPT - Center of mass calculation for dipole correction"
else
    echo "⚠️ center-of-mass.py - Center of mass calculation for dipole correction (NOT FOUND; only needed with dipole correction)"
fi

echo ""
echo "Checking base runscript template..."
check_script "$RUNSCRIPT_BASE" "Base VASP submission script template"

echo ""
echo "Checking required input files..."
for f in INCAR POSCAR POTCAR; do
    case $f in INCAR) d="Base VASP input parameters" ;; POSCAR) d="Crystal structure" ;; POTCAR) d="Pseudopotential file" ;; esac
    if [ -f "$f" ]; then
        echo "✅ $f - $d"
    else
        echo "❌ $f - $d (NOT FOUND)"
        DEPENDENCIES_OK=false
        MISSING_DEPS+=("$f")
    fi
done

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
    if [ "$SCHEDULER" = pbs ]; then
        echo "  • For PBS commands (qsub, qstat): Make sure you're on a PBS-managed cluster"
    else
        echo "  • For SLURM commands (sbatch, squeue): Make sure you're on a SLURM-managed cluster"
    fi
    echo "  • For vaspkit: Install from https://vaspkit.com/"
    echo "  • For VASP files (INCAR, POSCAR, POTCAR): Prepare these input files first"
    echo "  • For runscript template: Create a base submission script named '$RUNSCRIPT_BASE'"
    echo "  • For Python scripts: Ensure Python is installed and scripts are in current directory"
    echo ""
    if [ "$ASSUME_YES" = true ]; then
        REPLY=y
    else
        read -p "Continue anyway? [y/N]: " -r
    fi
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting..."
        exit 1
    fi
    echo "⚠️ Continuing with missing dependencies - some features may not work correctly"
    echo "============================================================"
fi

ROOT_DIR=$(pwd)

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

    # vasp_common.sh: case-insensitive, keeps template comments, never leaves
    # two active copies of a tag, appends the tag if it is not in the file at all
    if [[ "$value" == "COMMENT" ]]; then
        if incar_get "$key" "$file" >/dev/null; then
            incar_comment "$key" "$file"
            echo "🔧 $key commented in $file"
        else
            echo "ℹ️ $key not found in $file, nothing to comment"
        fi
        return
    fi

    if incar_get "$key" "$file" >/dev/null || grep -qiE "^[[:space:]]*[#!]+[[:space:]]*${key}[[:space:]]*=" "$file"; then
        incar_set "$key" "$value" "$file" "$comment"
        echo "🔧 $key set to $value in $file"
    else
        incar_set "$key" "$value" "$file" "$comment"
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
        # Check if it's a line-mode KPOINTS (e.g., band structure via vaspkit 303)
        local line3=$(sed -n '3p' "$kpoints_file" | tr '[:upper:]' '[:lower:]')
        if [[ "$line3" == *"line"* ]]; then
            vasp_exe="vasp_std"
            echo "🔍 Detected line-mode KPOINTS in $kpoints_file → using vasp_std"
        else
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

    # PBS job name (-N); Slurm gets --job-name from the workflow's sbatch call
    if [ "$SCHEDULER" = pbs ]; then
        if grep -q "^#PBS -N" "$runscript_file"; then
            sed -i "s/^#PBS -N.*/#PBS -N ${PREFIX}/" "$runscript_file"
            echo "🔧 PBS job name (-N) set to ${PREFIX} in $runscript_file"
        else
            # Insert after the first line (#!/bin/bash)
            sed -i "2i#PBS -N ${PREFIX}" "$runscript_file"
            echo "➕ PBS job name (-N ${PREFIX}) added to $runscript_file"
        fi
    fi
}

# ===== User prompts (only for values not given on the command line) =====
echo "============================================================"
echo ">>> WORKFLOW CONFIGURATION ($SCHEDULER, $STYLE style)"
echo ""

if [[ -z "$PREFIX" ]]; then
    read -p "Enter prefix for workflow script name (e.g., 'BTO-s231'): " PREFIX
fi
if [[ -z "$PREFIX" ]]; then
    PREFIX="workflow"
fi
WORKFLOW_SCRIPT="${PREFIX}.sh"

if [ "$STYLE" = gadi ]; then
    # Old Gadi questions: gamma-only pre-opt y/n; every step is generated
    if [[ -z "$OPT_STEPS" ]]; then
        echo ""
        echo ">>> GAMMA-ONLY PRE-OPTIMIZATION OPTION"
        echo "Would you like to perform a gamma-only pre-optimization before step1?"
        echo "This can be useful for large systems to get a rough initial structure."
        read -p "Enter [y/n]: " -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            OPT_STEPS="0 1 2 3 4 5"; [[ -z "$OPT_RUN" ]] && OPT_RUN="0 1 2"
            echo "✅ Gamma-only pre-optimization (step0) will be included."
        else
            OPT_STEPS="1 2 3 4 5"; [[ -z "$OPT_RUN" ]] && OPT_RUN="1 2"
            echo "ℹ️ Skipping gamma-only pre-optimization."
        fi
    fi
    [[ "$JOB_OFFSET" =~ ^[0-9]+$ ]] || JOB_OFFSET=0
else
    if [[ -z "$JOB_OFFSET" ]]; then
        echo ""
        echo ">>> JOB NUMBER OFFSET (step0/1/2 only; SCF/band/DOS always 00)"
        read -p "Offset if jobs 00/01/... already exist in this directory [default: 0]: " JOB_OFFSET
    fi
    if [[ -z "$JOB_OFFSET" ]] || ! [[ "$JOB_OFFSET" =~ ^[0-9]+$ ]]; then
        JOB_OFFSET=0
    fi
    echo "✅ step0/1/2 will start from $(printf "%02d" $JOB_OFFSET)."

    if [[ -z "$OPT_STEPS" ]]; then
        echo ""
        echo ">>> SELECT STEPS TO GENERATE"
        echo "Enter step numbers separated by spaces (e.g., \"1 2\" or \"1 2 3 4 5\")."
        echo "Leave blank to generate ALL steps."
        echo ""
        echo "  [0] Gamma-only pre-optimization (step0)"
        echo "  [1] Initial optimization        (step1)"
        echo "  [2] LREAL=FALSE optimization    (step2)"
        echo "  [3] SCF calculation             (scf)"
        echo "  [4] Band structure              (band)"
        echo "  [5] DOS calculation             (dos)"
        echo ""
        read -p "Steps to generate: " OPT_STEPS
    fi
fi

# Parse steps; default = all steps
if [[ -z "$OPT_STEPS" ]]; then
    GEN_STEPS=(0 1 2 3 4 5)
    echo "ℹ️  No selection made — generating all steps."
else
    read -ra GEN_STEPS <<< "$OPT_STEPS"
fi

# Steps the workflow will RUN = the user's selection; upstream INCARs added
# below as dependencies are only generated, never run automatically
if [[ -n "$OPT_RUN" ]]; then
    read -ra USER_STEPS <<< "$OPT_RUN"
else
    USER_STEPS=("${GEN_STEPS[@]}")
fi

# Helper: check if a step is in GEN_STEPS
gen_has() { [[ " ${GEN_STEPS[*]} " =~ " $1 " ]]; }

# Derive PERFORM_STEP0 from step selection
if gen_has 0; then
    PERFORM_STEP0=true
else
    PERFORM_STEP0=false
fi

# Job numbers (JOBNAME = prefix of the backed-up files, e.g. 01_OUTCAR)
if [ "$STYLE" = gadi ]; then
    JN_STEP0=$(printf "%02d" $(( JOB_OFFSET + 0 )))
    JN_STEP1=$(printf "%02d" $(( JOB_OFFSET + 1 )))
    JN_STEP2=$(printf "%02d" $(( JOB_OFFSET + 2 )))
    JN_SCF="03"
    JN_BAND="04"
    JN_DOS="05"
else
    # step0/1/2 from the offset; SCF/band/DOS (own directories) always 00
    if [ "$PERFORM_STEP0" = true ]; then
        JN_STEP0=$(printf "%02d" $(( JOB_OFFSET + 0 )))
        JN_STEP1=$(printf "%02d" $(( JOB_OFFSET + 1 )))
        JN_STEP2=$(printf "%02d" $(( JOB_OFFSET + 2 )))
    else
        JN_STEP1=$(printf "%02d" $(( JOB_OFFSET + 0 )))
        JN_STEP2=$(printf "%02d" $(( JOB_OFFSET + 1 )))
    fi
    JN_SCF="00"
    JN_BAND="00"
    JN_DOS="00"
fi

echo ""
echo ">>> DIPOLE CORRECTION"
if [[ -n "$OPT_DIPOLE" ]]; then
    REPLY="$OPT_DIPOLE"
else
    read -p "Enable dipole correction? [y/N]: " -r
fi
echo
if [[ $REPLY =~ ^[Yy] ]]; then
    USE_DIPOL_CORR=1
    echo "✅ Dipole correction enabled."
    missing_tags=()
    for tag in LDIPOL IDIPOL DIPOL; do
        if ! incar_get "$tag" INCAR >/dev/null 2>&1; then
            missing_tags+=("$tag")
        fi
    done
    if [[ ${#missing_tags[@]} -gt 0 ]]; then
        echo "❌ INCAR is missing or has commented-out dipole tags:"
        for t in "${missing_tags[@]}"; do
            echo "   • $t"
        done
        echo "   Add/uncomment these tags in INCAR before running the generator."
        exit 1
    fi
    echo "✅ INCAR contains LDIPOL, IDIPOL, and DIPOL."
    if [ -z "$COM_SCRIPT" ]; then
        echo "⚠️  center-of-mass.py not found (script dir or PATH) — dipole correction will fail at runtime."
    else
        echo "✅ center-of-mass.py found: $COM_SCRIPT"
    fi
else
    USE_DIPOL_CORR=0
    echo "ℹ️  Dipole correction disabled."
fi

# ---- Dependency resolution (INCAR chain) ----
# scf needs step2's INCAR as base; band needs scf's; dos needs band's.
# If a downstream step is selected but its upstream INCAR won't be generated
# AND doesn't already exist on disk, auto-include the upstream generation.
ADDED_DEPS=()

if gen_has 5 && ! gen_has 4 && [ ! -f "INCAR_band" ]; then
    GEN_STEPS+=(4); ADDED_DEPS+=("4(band) required by 5(dos)")
fi
if gen_has 4 && ! gen_has 3 && [ ! -f "INCAR_scf" ]; then
    GEN_STEPS+=(3); ADDED_DEPS+=("3(scf) required by 4(band)")
fi
if gen_has 3 && ! gen_has 2 && [ ! -f "INCAR_step2" ]; then
    GEN_STEPS+=(2); ADDED_DEPS+=("2(step2) required by 3(scf)")
fi

if [ ${#ADDED_DEPS[@]} -gt 0 ]; then
    echo "⚠️  Auto-added missing upstream dependencies:"
    for dep in "${ADDED_DEPS[@]}"; do echo "    • $dep"; done
fi

echo ""
echo "✅ Will generate files for steps: ${GEN_STEPS[*]}"
echo "============================================================"

# ===== Step 0 (Optional Gamma-only pre-optimization) =====
if gen_has 0; then
    separator "STEP 0: Generating INCAR_step0 (Gamma-only pre-optimization)"
    cp INCAR INCAR_step0
    echo -e "102\n1\n0\n" | vaspkit > /dev/null 2>&1
    mv KPOINTS KPOINTS_step0
    echo "🔧 KPOINTS_step0 generated (Gamma-only)."
    cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step0"
    update_runscript "${RUNSCRIPT_BASE}_step0" "$JN_STEP0" "KPOINTS_step0"
    echo "✅ Step0 files created for gamma-only pre-optimization."
else
    echo "⏭️  Skipping step0 generation."
fi

# ===== Step 1 =====
if gen_has 1; then
separator "STEP 1: Generating INCAR_step1"
cp INCAR INCAR_step1
echo -e "102\n1\n0.04\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_step1
echo "🔧 KPOINTS_step1 generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step1"
update_runscript "${RUNSCRIPT_BASE}_step1" "$JN_STEP1" "KPOINTS_step1"
else
    echo "⏭️  Skipping step1 generation."
fi

# ===== Step 2 =====
if gen_has 2; then
separator "STEP 2: Generating INCAR_step2"
cp INCAR INCAR_step2
update_key INCAR_step2 "LREAL" "COMMENT" "Disable LREAL=Auto for second optimization"
echo -e "102\n1\n0.04\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_step2
echo "🔧 KPOINTS_step2 generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step2"
update_runscript "${RUNSCRIPT_BASE}_step2" "$JN_STEP2" "KPOINTS_step2"
else
    echo "⏭️  Skipping step2 generation."
fi

# ===== Step 3 =====
if gen_has 3; then
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

echo ">>> SCF: Checking LMAXMIX based on POSCAR elements"
if [ -f "POSCAR" ]; then
    echo "Checking elements in POSCAR for LMAXMIX adjustment..."
    case "$(lmaxmix_for_poscar POSCAR)" in
        6) update_key INCAR_scf "LMAXMIX" "6" "f-electron detected" ;;
        4) update_key INCAR_scf "LMAXMIX" "4" "d-electron detected" ;;
        *) echo "ℹ️ No d/f electrons detected, LMAXMIX unchanged." ;;
    esac
fi

echo ">>> SCF: Generating KPOINTS_scf"
echo -e "102\n1\n0.03\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_scf
echo "🔧 KPOINTS_scf generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_scf"
update_runscript "${RUNSCRIPT_BASE}_scf" "$JN_SCF" "KPOINTS_scf"
else
    echo "⏭️  Skipping scf generation."
fi

# ===== Step 4: band =====
if gen_has 4; then
separator "STEP 6: Generating INCAR_band"
cp INCAR_scf INCAR_band
update_key INCAR_band "ICHARG" "11"     "Band structure calculation"
update_key INCAR_band "LWAVE"  ".FALSE." "Disable WAVECAR"
update_key INCAR_band "LCHARG" ".FALSE." "Disable CHGCAR"
update_key INCAR_band "LAECHG" ".FALSE." "Disable AECCAR"
update_key INCAR_band "ICORELEVEL" "COMMENT" "Core energies"
update_key INCAR_band "LVHAR" "COMMENT"    "Write total local potential"
echo ">>> STEP 7: Generating KPOINTS_band"
# 2D (largest vacuum gap along c > 8 Å) -> vaspkit 302, bulk -> 303; override with KPATH_TASK=302/303
VACUUM_C=$(poscar_vacuum_c POSCAR)
kpath_task=$(kpath_task POSCAR)
echo "🔍 Largest vacuum gap along c: ${VACUUM_C} Å → vaspkit ${kpath_task} ($([ "$kpath_task" = 302 ] && echo 2D || echo bulk) k-path)"
echo -e "${kpath_task}\n" | vaspkit > /dev/null 2>&1
mv KPATH.in KPOINTS_band
echo "⚠️ KPATH.in is for vaspkit's standardised cell (PRIMCELL.vasp); check that it matches the relaxed POSCAR."
echo "🔧 KPOINTS_band generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_band"
update_runscript "${RUNSCRIPT_BASE}_band" "$JN_BAND" "KPOINTS_band"
else
    echo "⏭️  Skipping band generation."
fi

# ===== Step 5: DOS =====
if gen_has 5; then
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
update_runscript "${RUNSCRIPT_BASE}_dos" "$JN_DOS" "KPOINTS_dos"
else
    echo "⏭️  Skipping dos generation."
fi

# ===== Generate workflow execution script =====
separator "Generating workflow execution script: $WORKFLOW_SCRIPT"

{
echo '#!/bin/bash'
echo ''
echo '##############################################'
echo '# ===== USER CONFIGURATION ====='
echo '# Define which steps to run:'
gen_has 0 && echo '# 0 = Step 0 Gamma-only Pre-optimization'
cat << 'EOL'
# 1 = Step 1 Initial Optimization
# 2 = Step 2 LREAL=FALSE Optimization
# 3 = Step 3 SCF
# 4 = Step 4 Band Structure
# 5 = Step 5 DOS
#
# Example:
EOL
if gen_has 0; then
    echo '# RUN_STEPS=(0 1 2 3 4 5)   # Run all steps including gamma-only pre-opt'
    echo '# RUN_STEPS=(1 2 3 4 5)     # Skip gamma-only pre-opt, run all others'
else
    echo '# RUN_STEPS=(1 2 3 4 5)     # Run all steps'
fi
cat << 'EOL'
# RUN_STEPS=(3 4 5)         # Skip optimization, run SCF + Band + DOS
# RUN_STEPS=(4)             # Only run Band (requires SCF already done)
#
# Steps that already finished (marker .workflow_stepN.done, or a converged run in
# the SCF/BAND/DOS directory) are skipped, so after this script was killed it can
# simply be started again; a job it was waiting for is waited for again, not resubmitted.
##############################################
EOL
cat << EOL
RUN_STEPS=(${USER_STEPS[@]})
JOB_NAME="${PREFIX}_workflow"
FORCE_RERUN=0   # 1 = run the selected steps again even if they already finished

# Whether to apply dipole correction (1 = enable, 0 = disable)
USE_DIPOL_CORR=${USE_DIPOL_CORR}
COM_SCRIPT="${COM_SCRIPT}"  # center-of-mass.py (resolved by the generator; PATH used if missing)
VASP_COMMON="${VASP_COMMON}"    # vasp_common.sh (resolved by the generator; PATH used if missing)
SCHEDULER="${SCHEDULER}"           # pbs or slurm

# ===== Submission script base name (customize here) =====
RUNSCRIPT_BASE="$RUNSCRIPT_BASE"  # Change this prefix to customize submission script names
                                 # Scripts will be \${RUNSCRIPT_BASE}_step1, \${RUNSCRIPT_BASE}_scf, etc.

##############################################
# ===== PATH CONFIGURATION =====
ROOT_DIR=\$(pwd)                       # Root working directory
SCF_DIR="\$ROOT_DIR/${SCF_DIR_NAME}" # SCF output directory
BAND_DIR="\$ROOT_DIR/BAND"             # Band structure directory
DOS_DIR="\$ROOT_DIR/DOS"               # DOS directory

LOGFILE="\$ROOT_DIR/vasp_workflow_status.log"
EOL
cat << 'EOL'

# Shared helpers: submit_job, job_active, vasp_job_status, incar_set
[ -f "$VASP_COMMON" ] || VASP_COMMON=$(command -v vasp_common.sh)
if [ -z "$VASP_COMMON" ]; then
    echo "❌ vasp_common.sh not found (generator path or PATH)" | tee -a "$LOGFILE"
    exit 1
fi
source "$VASP_COMMON"
export VASP_SCHEDULER="$SCHEDULER"
SUBMIT_ARGS=()
[ "$SCHEDULER" = slurm ] && SUBMIT_ARGS=(--job-name="$JOB_NAME")

echo "=== Workflow Started at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOGFILE"
echo "Hostname: $(hostname)" >> "$LOGFILE"
echo "Selected Steps: ${RUN_STEPS[@]}" >> "$LOGFILE"

##############################################
# ===== FUNCTION: Stop the workflow =====
##############################################
fail() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ $1" >> "$LOGFILE"
    { echo "==============================================="; echo "=== WORKFLOW FAILED at $(date '+%Y-%m-%d %H:%M:%S') ==="; echo "$1"; echo "Dir: $(pwd)"; echo "==============================================="; } >> ~/vasp_workflow_fail_log
    exit 1
}

##############################################
# ===== FUNCTION: Has a step already finished? =====
# $1 → Step number, $2 → directory of its calculation
##############################################
step_finished() {
    [ "$FORCE_RERUN" = 1 ] && return 1
    [ -f "$ROOT_DIR/.workflow_step$1.done" ] && return 0
    # SCF / band / DOS have their own directory: a converged run there counts as done
    [ "$2" != "$ROOT_DIR" ] && [ -f "$2/INCAR" ] && vasp_job_status -f "$2" >/dev/null
}

##############################################
# ===== FUNCTION: Submit a step, wait for it, check convergence =====
# $1 → Step number, $2 → job script (in the current directory), $3 → directory with OUTCAR
# Convergence: vasp_job_status (same table as VASP_JOB_PARAMETERS)
##############################################
run_step() {
    local step=$1 script=$2 workdir=$3
    local idfile="$ROOT_DIR/.workflow_step$step.jobid" jobid="" status
    if [ -s "$idfile" ] && job_active "$(cat "$idfile")" "$SCHEDULER"; then
        jobid=$(cat "$idfile")
        echo "Step $step: waiting for job $jobid submitted earlier" >> "$LOGFILE"
    else
        jobid=$(submit_job -s "$SCHEDULER" "$script" "${SUBMIT_ARGS[@]}")
        [ -n "$jobid" ] || fail "Step $step: job submission failed (no job ID)."
        echo "$jobid" > "$idfile"
        echo "Step $step: job $jobid submitted" >> "$LOGFILE"
    fi
    while job_active "$jobid" "$SCHEDULER"; do
        sleep 60
    done
    status=$(vasp_job_status -f "$workdir")
    if [[ "$status" == converged* ]]; then
        echo "✅ Step $step completed successfully." >> "$LOGFILE"
        date '+%Y-%m-%d %H:%M:%S' > "$ROOT_DIR/.workflow_step$step.done"
        rm -f "$idfile"
    else
        fail "Step $step failed: ${status#*$'\t'} ($workdir)"
    fi
}

##############################################
# ===== FUNCTION: Set DIPOL from center of mass =====
# Strips VASP 6.4 species suffixes (e.g. Ti_pv/abc123) from line 6 of
# ./POSCAR, runs center-of-mass.py and writes DIPOL into ./INCAR
##############################################
set_dipol() {
    local com_script="$COM_SCRIPT"
    [ -f "$com_script" ] || com_script=$(command -v center-of-mass.py 2>/dev/null)
    [ -n "$com_script" ] || fail "center-of-mass.py not found; cannot set DIPOL in $(pwd)."
    sed -i '6s|[/_][^[:space:]]*||g' POSCAR
    local com=$(python3 "$com_script" POSCAR | awk -F'[][]' '/Center of mass/{print $2}')
    [ -n "$com" ] || fail "center-of-mass.py gave no result in $(pwd); DIPOL not set."
    incar_set DIPOL "$(echo $com)" INCAR
}

step_in() { [[ " ${RUN_STEPS[@]} " =~ " $1 " ]]; }
skipped() { echo "=== Step $1: already finished - skipped (FORCE_RERUN=1 to run again) ===" >> "$LOGFILE"; }
EOL

if gen_has 0; then
cat << 'EOL'

##############################################
# ===== STEP 0: Gamma-only Pre-optimization =====
##############################################
if step_in 0; then
  if step_finished 0 "$ROOT_DIR"; then skipped 0; else
    echo "=== Step 0: Gamma-only Pre-optimization Started ===" >> "$LOGFILE"
    cp INCAR_step0 INCAR
    cp KPOINTS_step0 KPOINTS
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        set_dipol
    fi
    run_step 0 ${RUNSCRIPT_BASE}_step0 "$ROOT_DIR"
    echo "Copying CONTCAR to POSCAR for next step..." >> "$LOGFILE"
    cp CONTCAR POSCAR
  fi
fi
EOL
fi

cat << 'EOL'

##############################################
# ===== STEP 1: Initial Optimization =====
##############################################
if step_in 1; then
  if step_finished 1 "$ROOT_DIR"; then skipped 1; else
    echo "=== Step 1: Initial Optimization Started ===" >> "$LOGFILE"
    cp INCAR_step1 INCAR
    cp KPOINTS_step1 KPOINTS
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        set_dipol
    fi
    run_step 1 ${RUNSCRIPT_BASE}_step1 "$ROOT_DIR"
    echo "Copying CONTCAR to POSCAR for next step..." >> "$LOGFILE"
    cp CONTCAR POSCAR
  fi
fi

##############################################
# ===== STEP 2: LREAL=FALSE Optimization =====
##############################################
if step_in 2; then
  if step_finished 2 "$ROOT_DIR"; then skipped 2; else
    echo "=== Step 2: LREAL=FALSE Optimization Started ===" >> "$LOGFILE"
    cp INCAR_step2 INCAR
    cp KPOINTS_step2 KPOINTS
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        set_dipol
    fi
    run_step 2 ${RUNSCRIPT_BASE}_step2 "$ROOT_DIR"
  fi
fi

##############################################
# ===== STEP 3: SCF Calculation =====
##############################################
if step_in 3; then
  if step_finished 3 "$SCF_DIR"; then skipped 3; else
    echo "=== Step 3: SCF Started ===" >> "$LOGFILE"
    mkdir -p "$SCF_DIR"
    cp ${RUNSCRIPT_BASE}_scf "$SCF_DIR/"
    cp INCAR_scf "$SCF_DIR/INCAR"
    cp KPOINTS_scf "$SCF_DIR/KPOINTS"
    cp POTCAR "$SCF_DIR/"
    if [ -s CONTCAR ]; then
        cp CONTCAR "$SCF_DIR/POSCAR"
    else
        echo "ℹ️ No CONTCAR here (no optimisation run in this directory); using POSCAR for SCF" >> "$LOGFILE"
        cp POSCAR "$SCF_DIR/POSCAR"
    fi
    cd "$SCF_DIR" || fail "cd failed: $SCF_DIR"
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        set_dipol
    fi
    run_step 3 ${RUNSCRIPT_BASE}_scf "$SCF_DIR"
    cd "$ROOT_DIR" || fail "cd failed: $ROOT_DIR"
  fi
fi

##############################################
# ===== STEP 4: Band Structure =====
##############################################
run_band() {
    if step_finished 4 "$BAND_DIR"; then skipped 4; return 0; fi
    echo "=== Step 4: Band Structure Started ===" >> "$LOGFILE"
    mkdir -p "$BAND_DIR"
    cd "$BAND_DIR" || fail "cd failed: $BAND_DIR"
    ln -sf "$SCF_DIR/CHGCAR" CHGCAR      # Link SCF charge density
    cp "$SCF_DIR/POSCAR" POSCAR          # Use SCF structure
    cp "$ROOT_DIR/POTCAR" POTCAR
    cp "$ROOT_DIR/INCAR_band" INCAR
    cp "$ROOT_DIR/KPOINTS_band" KPOINTS
    cp "$ROOT_DIR/${RUNSCRIPT_BASE}_band" ${RUNSCRIPT_BASE}_band
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        set_dipol
    fi
    run_step 4 ${RUNSCRIPT_BASE}_band "$BAND_DIR"
    cd "$ROOT_DIR" || fail "cd failed: $ROOT_DIR"
}

##############################################
# ===== STEP 5: DOS Calculation =====
##############################################
run_dos() {
    if step_finished 5 "$DOS_DIR"; then skipped 5; return 0; fi
    echo "=== Step 5: DOS Calculation Started ===" >> "$LOGFILE"
    mkdir -p "$DOS_DIR"
    cd "$DOS_DIR" || fail "cd failed: $DOS_DIR"
    ln -sf "$SCF_DIR/CHGCAR" CHGCAR      # Link SCF charge density
    cp "$SCF_DIR/POSCAR" POSCAR          # Use SCF structure
    cp "$ROOT_DIR/POTCAR" POTCAR
    cp "$ROOT_DIR/INCAR_dos" INCAR
    cp "$ROOT_DIR/KPOINTS_dos" KPOINTS
    cp "$ROOT_DIR/${RUNSCRIPT_BASE}_dos" ${RUNSCRIPT_BASE}_dos
    # Define DIPOL for dipole correction from the structure's center of mass
    if [[ $USE_DIPOL_CORR -eq 1 ]]; then
        set_dipol
    fi
    run_step 5 ${RUNSCRIPT_BASE}_dos "$DOS_DIR"
    cd "$ROOT_DIR" || fail "cd failed: $ROOT_DIR"
}

##############################################
# ===== STEP 4 & 5 Execution Logic =====
# If both 4 and 5 selected → run in parallel
# If only one selected → run that one alone
##############################################
if step_in 4 && step_in 5; then
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
    [[ $STATUS_BAND -ne 0 ]] && fail "Error: Band Structure step failed (PID=$PID_BAND)"
    [[ $STATUS_DOS -ne 0 ]] && fail "Error: DOS step failed (PID=$PID_DOS)"

    echo "$(date '+%Y-%m-%d %H:%M:%S') ✅ Step 4 & 5 completed successfully." >> "$LOGFILE"
elif step_in 4; then
    run_band
elif step_in 5; then
    run_dos
fi

echo "=== Workflow Completed at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOGFILE"
{
  echo "==============================================="
  echo "=== Workflow Completed at $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "=== $(pwd) ==="
  echo "==============================================="
} >> ~/vasp_workflow_log
EOL
} > "$WORKFLOW_SCRIPT"

chmod +x "$WORKFLOW_SCRIPT"

echo "============================================================"
echo "✅ Files generated for selected steps: ${GEN_STEPS[*]}"
echo ""
gen_has 0 && \
    echo "   - INCAR_step0, KPOINTS_step0, ${RUNSCRIPT_BASE}_step0 (JOBNAME=$JN_STEP0, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step0"))"
gen_has 1 && \
    echo "   - INCAR_step1, KPOINTS_step1, ${RUNSCRIPT_BASE}_step1 (JOBNAME=$JN_STEP1, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step1"))"
gen_has 2 && \
    echo "   - INCAR_step2, KPOINTS_step2, ${RUNSCRIPT_BASE}_step2 (JOBNAME=$JN_STEP2, VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_step2"))"
gen_has 3 && \
    echo "   - INCAR_scf,   KPOINTS_scf,   ${RUNSCRIPT_BASE}_scf   (JOBNAME=$JN_SCF,   VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_scf"))"
gen_has 4 && \
    echo "   - INCAR_band,  KPOINTS_band,  ${RUNSCRIPT_BASE}_band  (JOBNAME=$JN_BAND,  VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_band"))"
gen_has 5 && \
    echo "   - INCAR_dos,   KPOINTS_dos,   ${RUNSCRIPT_BASE}_dos   (JOBNAME=$JN_DOS,   VASP_EXE=$(get_vasp_exe "${RUNSCRIPT_BASE}_dos"))"
echo ""
echo "🎯 Generated workflow execution script: $WORKFLOW_SCRIPT (runs steps: ${USER_STEPS[*]})"
echo ""
echo "📋 To run the workflow:"
echo "   1. Edit $WORKFLOW_SCRIPT to select desired steps (RUN_STEPS array)"
echo "   2. Run \"nohup ./$WORKFLOW_SCRIPT &\" to execute the workflow"
echo "      (if it gets killed, start it again: finished steps are skipped)"
echo ""
echo "⚠️ IMPORTANT NOTES:"
echo "   • VASP_EXE is automatically set based on k-mesh in KPOINTS files:"
echo "     - vasp_gam for 1×1×1 k-mesh (gamma-only calculations)"
echo "     - vasp_std for all other k-meshes"
echo "   • For large systems, even with denser k-mesh settings, you might still get 1×1×1"
echo "   • Always check the console output above to see which VASP executable was assigned"
echo "   • Dipole correction: USE_DIPOL_CORR=${USE_DIPOL_CORR} (set during this run)"
echo ""
