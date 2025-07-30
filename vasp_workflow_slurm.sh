#!/bin/bash

# ===== User-defined Job Name and Variables =====
JOB_NAME="STO_opt"
LOGFILE="vasp_workflow_status.log"
SUB_CMD="sbatch --job-name=$JOB_NAME"

echo "=== Workflow Started ===" > $LOGFILE
echo "JOB_NAME: $JOB_NAME" >> $LOGFILE
echo "Running on: $(hostname)" >> $LOGFILE
echo "Start Time: $(date '+%Y-%m-%d %H:%M:%S')" >> $LOGFILE

check_job_done() {
    local step=$1
    local jobid=$2
    local check_mode=$3   # "opt" for optimization, "scf" for SCF

    while true; do
        if squeue -j $jobid 2>/dev/null | grep -q "$jobid"; then
            sleep 60
        else
            if [[ $check_mode == "opt" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Step $step (Job $jobid) finished. Checking OUTCAR..." >> $LOGFILE
                if grep -q "Total CPU time used" OUTCAR && grep -q "reached required accuracy" OUTCAR; then
                    echo "✅ Step $step completed successfully." >> $LOGFILE
                else
                    echo "❌ Step $step finished but did not reach required accuracy." >> $LOGFILE
                    exit 1
                fi
            elif [[ $check_mode == "scf" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Step $step (Job $jobid) finished. Checking OUTCAR..." >> ../$LOGFILE
                if grep -q "Total CPU time used" OUTCAR && grep -q "EDIFF is reached" OUTCAR; then
                    echo "✅ Step $step (SCF) completed successfully." >> ../$LOGFILE
                else
                    echo "❌ Step $step (SCF) finished but EDIFF was not reached." >> ../$LOGFILE
                    exit 1
                fi
            fi
            break
        fi
    done
}

# ===== Step 1: Initial Optimization =====
echo "=== Step 1: Initial Optimization Started ===" >> $LOGFILE
cp INCAR_step1 INCAR
JOBID1=$($SUB_CMD vasp_runscript_step1 | awk '{print $NF}')
echo "Submitted Step 1 with Slurm JobID: $JOBID1" >> $LOGFILE
check_job_done 1 $JOBID1 "opt"

# ===== Step 2: Modify LREAL = FALSE, Second Optimization =====
echo "=== Step 2: Modify LREAL = FALSE and Start Second Optimization ===" >> $LOGFILE
cp INCAR_step2 INCAR
cp CONTCAR POSCAR
JOBID2=$($SUB_CMD vasp_runscript_step2 | awk '{print $NF}')
echo "Submitted Step 2 with Slurm JobID: $JOBID2" >> $LOGFILE
check_job_done 2 $JOBID2 "opt"

# ===== Step 3: NON-SC Calculation (SCF criteria) =====
echo "=== Step 3: NON-SC Calculation Started ===" >> $LOGFILE
mkdir -p NON-SC-kmesh-0.03
cp vasp_runscript_scf NON-SC-kmesh-0.03/
cp INCAR_scf NON-SC-kmesh-0.03/INCAR
cp KPOINTS_scf NON-SC-kmesh-0.03/KPOINTS
cp POTCAR NON-SC-kmesh-0.03/
cp CONTCAR NON-SC-kmesh-0.03/POSCAR
cd NON-SC-kmesh-0.03
JOBID3=$($SUB_CMD vasp_runscript_scf | awk '{print $NF}')
echo "Submitted Step 3 with Slurm JobID: $JOBID3" >> ../$LOGFILE
check_job_done 3 $JOBID3 "scf"

echo "=== Workflow Completed at $(date '+%Y-%m-%d %H:%M:%S') ===" >> ../$LOGFILE
