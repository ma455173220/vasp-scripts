#!/bin/bash

##############################################
# ===== USER CONFIGURATION =====
# Define which steps to run:
# 1 = Step 1 Initial Optimization
# 2 = Step 2 LREAL=FALSE Optimization
# 3 = Step 3 SCF
# 4 = Step 4 Band Structure
# 5 = Step 5 DOS
#
# Example:
# RUN_STEPS=(1 2 3 4 5)   # Run all steps
# RUN_STEPS=(3 4 5)       # Skip optimization, run SCF + Band + DOS
# RUN_STEPS=(4)           # Only run Band (requires SCF already done)
##############################################
RUN_STEPS=(1 2 3)
JOB_NAME="STO-s431_opt"

# Whether to apply dipole correction (true/false)
# 1 = enable dipole correction, 0 = disable
USE_DIPOL_CORR=0

# ===== Submission script base name (customize here) =====
RUNSCRIPT_BASE="vasp_runscript"  # Change this prefix to customize submission script names
                                 # Scripts will be ${RUNSCRIPT_BASE}_step1, ${RUNSCRIPT_BASE}_scf, etc.

##############################################
# ===== PATH CONFIGURATION =====
ROOT_DIR=$(pwd)                       # Root working directory
SCF_DIR="$ROOT_DIR/NON-SC-kmesh-0.03" # SCF output directory
BAND_DIR="$ROOT_DIR/BAND"             # Band structure directory
DOS_DIR="$ROOT_DIR/DOS"               # DOS directory

LOGFILE="$ROOT_DIR/vasp_workflow_status.log"
SUB_CMD="sbatch --job-name=$JOB_NAME" # Command to submit jobs

echo "=== Workflow Started ===" > "$LOGFILE"
echo "Selected Steps: ${RUN_STEPS[@]}" >> "$LOGFILE"

##############################################
# ===== FUNCTION: Check Job Completion =====
# Waits for a submitted job to finish and checks OUTCAR for convergence
# $1 → Step number
# $2 → Job ID
# $3 → Mode ("opt" or "scf")
# $4 → Directory containing OUTCAR
##############################################
check_job_done() {
    local step=$1
    local jobid=$2
    local check_mode=$3
    local workdir=$4

    while true; do
        # Wait while job is still in queue
        if squeue -j $jobid 2>/dev/null | grep -q "$jobid"; then
            sleep 60
        else
            OUTCAR_FILE="$workdir/OUTCAR"
            # Check convergence conditions
            if [[ $check_mode == "opt" ]]; then
                grep -q "Total CPU time used" "$OUTCAR_FILE" && grep -q "reached required accuracy" "$OUTCAR_FILE" \
                    && echo "✅ Step $step completed successfully." >> "$LOGFILE" \
                    || { echo "❌ Step $step failed." >> "$LOGFILE"; exit 1; }
            elif [[ $check_mode == "scf" ]]; then
                grep -q "Total CPU time used" "$OUTCAR_FILE" && grep -q "EDIFF is reached" "$OUTCAR_FILE" \
                    && echo "✅ Step $step completed successfully." >> "$LOGFILE" \
                    || { echo "❌ Step $step failed." >> "$LOGFILE"; exit 1; }
            fi
            break
        fi
    done
}

##############################################
# ===== STEP 1: Initial Optimization =====
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 1 " ]]; then
    echo "=== Step 1: Initial Optimization Started ===" >> "$LOGFILE"
    cp INCAR_step1 INCAR
    cp KPOINTS_step1 KPOINTS
    JOBID1=$($SUB_CMD ${RUNSCRIPT_BASE}_step1 | awk '{print $NF}')
    check_job_done 1 $JOBID1 "opt" "$ROOT_DIR"
fi

##############################################
# ===== STEP 2: LREAL=FALSE Optimization =====
##############################################
if [[ " ${RUN_STEPS[@]} " =~ " 2 " ]]; then
    echo "=== Step 2: LREAL=FALSE Optimization Started ===" >> "$LOGFILE"
    cp INCAR_step2 INCAR
    cp KPOINTS_step2 KPOINTS
    cp CONTCAR POSCAR
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
