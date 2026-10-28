#!/bin/bash

# Define variables for remote machine and paths (override with environment variables)
REMOTE_MACHINE="${REMOTE_MACHINE:-hm1876@gadi.nci.org.au}"
REMOTE_PATH="${REMOTE_PATH:-/scratch/g46/hm1876/jahan/doped/MgO_exercise/SnB}"
SUBMISSION_SCRIPT="${SUBMISSION_SCRIPT:-vasp_runscript}"
LOCAL_DIR="SnB/"

# Submit command for snb-run: $SUBMIT_COMMAND if set, else from the job script
# header (#PBS -> qsub, #SBATCH -> sbatch), else the scheduler found on PATH, else qsub
if [ -z "$SUBMIT_COMMAND" ]; then
    if grep -q "^#SBATCH" "$SUBMISSION_SCRIPT" 2>/dev/null; then
        SUBMIT_COMMAND="sbatch"
    elif grep -q "^#PBS" "$SUBMISSION_SCRIPT" 2>/dev/null; then
        SUBMIT_COMMAND="qsub"
    elif command -v sbatch >/dev/null 2>&1; then
        SUBMIT_COMMAND="sbatch"
    else
        SUBMIT_COMMAND="qsub"
    fi
fi

# Function to display messages in orange color
orange_text() {
    echo -e "\033[33m$1\033[0m"
}

# Function to display separators
print_separator() {
    echo "-------------------------------------------------------"
}

# Function to display Step 1 instructions
step1_instructions() {
    print_separator
    echo -n "Step 1: Upload files to the remote root directory "
    orange_text "(Run this command on your local computer)"
    echo -n "Command: "
    orange_text "rsync -av --include='*/' $LOCAL_DIR $REMOTE_MACHINE:$REMOTE_PATH"
    echo "Explanation: This command uploads the contents of the SnB directory to the remote machine at the specified path."
    print_separator
}

# Function to display Step 2 instructions
step2_instructions() {
    print_separator
    echo -n "Step 2: Submit jobs "
    orange_text "(Run this command on the remote machine)"
    echo -n "Before running this step, activate the Python virtual environment with: "
    orange_text "conda activate doped"
    echo "Remember to use vasp_gam in runscript"
    echo -n "Command: "
    orange_text "for defect in */; do cp $SUBMISSION_SCRIPT \$defect; cd \$defect; snb-run --submit-command $SUBMIT_COMMAND --job-script $SUBMISSION_SCRIPT; cd ..; done"
    echo "Explanation: This command copies the job script to each defect directory, navigates into it, submits the job using snb-run, and then navigates back to the parent directory."
    print_separator
}

# Function to display Step 3 instructions
step3_instructions() {
    print_separator
    echo -n "Step 3: Parse data "
    orange_text "(Run this command on the remote machine)"
    echo -n "Before running this step, activate the Python virtual environment with: "
    orange_text "conda activate doped"
    echo -n "Command: "
    orange_text "snb-parse -a"
    echo "Explanation: This command parses all relevant data files in the root directory to gather and summarize results."
    print_separator
}

# Function to display Step 4 instructions
step4_instructions() {
    print_separator
    echo -n "Step 4: Download files and relaxed structures to the local machine "
    orange_text "(Run this command on your local computer)"
    echo -n "Command: "
    orange_text "rsync -av --include='*/' --include='*.yaml' --include='CONTCAR' --exclude='*' $REMOTE_MACHINE:$REMOTE_PATH ./"
    echo "Explanation: This command downloads .yaml files and CONTCAR files from the remote directory to the local machine while preserving the directory structure."
    print_separator
}

# Display menu for user to select step
while true; do
    echo "Select a step to view instructions:"
    echo "1) Upload files to remote root directory"
    echo "2) Submit jobs"
    echo "3) Parse data"
    echo "4) Download files and relaxed structures to local machine"
    echo "5) Exit"
    read -rp "Enter your choice: " choice

    case $choice in
        1)
            step1_instructions
            exit 0
            ;;
        2)
            step2_instructions
            exit 0
            ;;
        3)
            step3_instructions
            exit 0
            ;;
        4)
            step4_instructions
            exit 0
            ;;
        5)
            echo "Exiting. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
done

