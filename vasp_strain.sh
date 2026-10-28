#!/bin/bash

# This script is used to create directories for different strains and submit jobs (qsub or sbatch)

# Define input files
input_file="INCAR POSCAR POTCAR KPOINTS"
runscript="vasp_runscript"

# Define color codes
GREEN='\033[1;32m'
ORANGE='\033[1;33m'

# Check if input_file and runscript exist and are not empty
for i in $input_file; 
do 
	if [ ! -s "$i" ]
	then
		echo -e "${ORANGE}Error: $i does not exist or is empty"
		echo -e "${ORANGE}Please make sure you have the correct files in the current directory"
		exit 1
	fi
done

if [ ! -s "$runscript" ]
then
        echo -e "${ORANGE}Error: $runscript does not exist or is empty"
        echo -e "${ORANGE}Please make sure you have the correct files in the current directory"
        exit 1
fi


# Check if arguments are provided
if [ $# -eq 0 ]
then
	echo -e "${ORANGE}Usage: $0 arg1 arg2 ... argN"
	exit 1
fi

# Shared helpers (vasp_common.sh): next to this script, else on PATH
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"; [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh || true)
[ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"

# Locate deform_strain.sh: old install path, else next to vasp_common.sh (this repo), else PATH
deform_strain=$(find_tool /home/561/hm1876/.local/bin/deform_strain.sh)
if [ -z "$deform_strain" ]
then
	echo -e "${ORANGE}Error: deform_strain.sh not found (install path, script directory or PATH)"
	exit 1
fi

SUB_CMD=$(submit_cmd_of "$runscript")

# Choose the shear strain direction
read -p "Please select the strain direction (XX, YY, ZZ, XY, XZ, YZ): " shear_strain_direction

# Loop through the arguments and create directories
for arg in "$@"
do
	if [ -d "strain_$arg" ]
	then
		echo -e "${GREEN}Directory strain_$arg already exists, skipping..."
		continue
	fi

	mkdir "strain_$arg"
	cp INCAR POSCAR POTCAR KPOINTS $runscript "strain_$arg"
	cd "strain_$arg"

	# Run deform_strain
	echo -e "${GREEN}Running deform_strain for strain $arg..."
	new_arg=$(echo "$arg - 1" | bc)
	bash "$deform_strain" $shear_strain_direction $new_arg
	echo -e "${ORANGE}.............................................................................."

	cd ..
done


# Confirm if submit all jobs
echo -e "${ORANGE}.............................................................................."
read -p "Submit all jobs? [Y/n]" choice

if [[ $choice == "Y" || $choice == "y" ]]; then
	# Loop through the arguments and submit jobs ($SUB_CMD)
	for arg in "$@"
	do
		if [ -d "strain_$arg" ] && [ -n "$(find "strain_$arg" -maxdepth 1 -name '*OUTCAR' -print -quit)" ]; then
			echo -e "${GREEN}Directory strain_$arg already exists and has output file, skipping..."
			echo -e "${ORANGE}.............................................................................."
			continue
		fi

		cd "strain_$arg"
		echo -e "${GREEN}Submitting job for strain $arg..."
		$SUB_CMD $runscript
		echo -e "${ORANGE}.............................................................................."
		cd ..
	done
else
	echo -e "${ORANGE}Jobs not submitted."
fi

