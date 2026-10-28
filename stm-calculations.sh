#!/bin/bash

# Check if the number of arguments is at least 2
if [ "$#" -lt 2 ]; then
    echo "Error: At least 2 arguments are required"
    echo "Usage: stm-calculations.sh <submission_script> <band_index>"
    echo "<band_index> can be (1) single integer, (2) range of integers separated by a dash (e.g., 323-328), or (3) integer-spinup/spindw (323-328-spinup)"
    exit 1
fi

# Shared INCAR helpers (incar_get / incar_set / incar_comment): next to this script, else on PATH
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_LIB_DIR/vasp_incar_lib.sh" ]; then
    source "$_LIB_DIR/vasp_incar_lib.sh"
elif command -v vasp_incar_lib.sh >/dev/null 2>&1; then
    source "$(command -v vasp_incar_lib.sh)"
else
    echo -e "\033[31mERROR:\033[0m vasp_incar_lib.sh not found (next to this script or on PATH)"
    exit 1
fi

# Check if the first argument is a file in the current directory
if [ ! -f "./$1" ]; then
    echo "Error: The first argument must be the submission script in the current directory"
    exit 1
fi

# Check if the remaining arguments are integers
# re='^[0-9]+$'
# for i in "${@:2}"; do
#     if ! [[ $i =~ $re ]]; then
#         echo "Error: All arguments after the first one must be integers"
#         exit 1
#     fi
# done


# Check if required files exist and are not empty
required_files="INCAR POSCAR POTCAR KPOINTS WAVECAR"
for i in $required_files; do
    if [ ! -s ${i} ]; then
	echo "Error: ${i} file does not exist or is empty"
      	exit 1
    fi
done

# Create folders and copy files
re='^[0-9]+$'
for i in "${@:2}"; do
    folder="STM_${i}"
    if [ -d "$folder" ]; then
        echo "Error: Folder $folder already exists"
        exit 1
    fi
    mkdir "$folder"
    cp INCAR POSCAR POTCAR KPOINTS "$1" "$folder"
    cd $folder
    ln -s ../WAVECAR .
    cd ..
    # Comment out these keywords
    incar_comment ICHARG "$folder"/INCAR
    incar_comment NEDOS "$folder"/INCAR
    incar_comment LORBIT "$folder"/INCAR
    # Read the linked WAVECAR, never write through the link
    incar_set ISTART 1 "$folder"/INCAR
    incar_set LWAVE .FALSE. "$folder"/INCAR
    incar_set LCHARG .FALSE. "$folder"/INCAR
    incar_set LPARD .TRUE. "$folder"/INCAR
    # Specify the band index
    if ! [[ $i =~ $re ]]; then
        range=`echo $i | sed 's/-/ /g'`
	if [[ $range == *"spinup"* || $range == *"spindw"* ]]; then
		num_array=($(echo "$range" | grep -oE '[0-9]+'))
		num_count=$(echo "${#num_array[@]}")

		string_array=($(echo "$range" | grep -oE '[^0-9 ]+'))
		string=$(echo "${string_array[@]}")
		if [[ $string == "spinup" ]] ; then
			column_num=2
		else
			column_num=3
		fi
		if [ $num_count -eq 1 ]; then
			band_index=$(echo "${num_array[0]}")
			EINTMAX=$(awk -v var="$band_index" -v col="$column_num" 'NR > 7 && $1 == var {print $col; exit}' EIGENVAL)
			EINTMIN=$EINTMAX
		else
			band_index=$(echo "${num_array[@]}")
			range=$(seq $band_index)
			for b in $range; do
			    # first k-point only (same as the single-band case); skip the 7 header lines
			    val=$(awk -v num=$b -v col=$column_num 'NR > 7 && $1 == num {print $col; exit}' EIGENVAL)
			    if [[ ! -z $val ]]; then
			        if [[ -z $EINTMIN ]]; then
			            EINTMIN=$val
			            EINTMAX=$val
			        else
			            if (( $(echo "$val < $EINTMIN" | bc -l) )); then
			                EINTMIN=$val
			            fi
			            if (( $(echo "$val > $EINTMAX" | bc -l) )); then
			                EINTMAX=$val
			            fi
			        fi
			    fi
			done
		fi
		eint="$(echo "$EINTMIN - 0.0001" | bc) $(echo "$EINTMAX + 0.0001" | bc)"
		incar_set NBMOD -2 "$folder"/INCAR
		incar_set EINT "$(echo $eint)" "$folder"/INCAR
		unset EINTMIN EINTMAX
	else
		iband=$(seq $range)
		incar_set IBAND "$(echo $iband)" "$folder"/INCAR
	fi
    else
        iband=$i
	incar_set IBAND "$(echo $iband)" "$folder"/INCAR
    fi

done

# Pick the submit command from the runscript header (PBS or Slurm)
if grep -q "^#SBATCH" "$1"; then
	SUB_CMD="sbatch"
elif grep -q "^#PBS" "$1"; then
	SUB_CMD=$(command -v qsub || echo /opt/pbs/default/bin/qsub)
elif command -v sbatch >/dev/null 2>&1; then
	SUB_CMD="sbatch"
else
	SUB_CMD="qsub"
fi

echo -e "Do you want to submit the jobs?\n1 YES\n2 NO"
read SUBMIT_CHOICE
if [ $SUBMIT_CHOICE -eq '1' ] ; then
        for i in "${@:2}" ; do
		folder="STM_${i}"
                cd $folder
                echo -e "\n========================================\nSubmission in process, please wait...\n..."
                echo "$SUB_CMD $1"
                $SUB_CMD $1 && echo -e "\nJob submitted!\n========================================"
                cd ..
        done
else
        echo -e "\n========================================\nDone!\n========================================"
fi

