#!/bin/bash

# This script monitors the progress of a VASP calculation and stops it if it is not converging.

# Set the path to the directory where VASP calculations are running
cd $PBS_O_WORKDIR

# Set the path to the OSZICAR file
OSZICAR_FILE="OSZICAR"

# Set the path to the OUTCAR file
OUTCAR_FILE="OUTCAR"

# Set the path to the STOPCAR file
STOPCAR_FILE="STOPCAR"

# Set the maximum number of SCF steps to allow
MAX_SCF_STEPS=100

# Set the maximum dE value to allow
MAX_DE=-01

# Wait for 1 minute before entering the while loop
sleep 60

# Sleep time after each loop
sleep_time=60

# Loop indefinitely
while true; do

    # Check if the VASP calculation has finished
    job_check=$(grep "Total CPU time used (sec)" "$OUTCAR_FILE")
    if [[ -n $job_check ]] ; then
	    echo "VASP calculation has finished"
	    break
    fi

    # Check if the STOPCAR file exists
    if [ -f "$STOPCAR_FILE" ]; then
	    echo "VASP calculation has been stopped"
	    break
    fi

    # Check if the OSZICAR file exists
    if [ -f "$OSZICAR_FILE" ]; then

	# Get the current SCF step
	scf_step=$(tail -n 1 "$OSZICAR_FILE" | awk '{print $2}')

	# Check if the SCF step is an integer
	if ! [[ "$scf_step" =~ ^[0-9]+$ ]]; then
		echo "SCF step is not an integer, skipping this loop iteration"
		sleep $sleep_time
		continue
	fi

	# Get the current dE value
	de=$(tail -n 1 "$OSZICAR_FILE" | awk '{print $4}' | awk -F "E" '{print $NF}')

	# Check if the SCF step is greater than the maximum allowed
	if [ "$scf_step" -gt "$MAX_SCF_STEPS" ]; then

	    # Check if the dE value is still high
	    de_E=$(echo $de | sed 's/[+]//')
	    if [ "$(echo "$de_E > $MAX_DE" | bc)" -eq 1 ]; then
		    echo "SCF step $scf_step: dE=$de is still too high, stopping VASP calculation..."
		    echo "LABORT = .TRUE." > "$STOPCAR_FILE"
		    echo "Stopping monitoring script..."
		    exit 0
	    fi
	fi
    fi

    # Wait for a few seconds before checking again
    sleep $sleep_time
done

