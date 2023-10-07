#!/bin/bash

# Check if the number of arguments is at least 2
if [ "$#" -lt 2 ]; then
    echo "Error: At least 2 arguments are required"
    echo "Usage: stm-calculations.sh <submission_script> <band_index>"
    echo "<band_index> can be (1) single integer, (2) range of integers separated by a dash (e.g., 323-328), or (3) integer-spinup/spindw (323-328-spinup)"
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
    # Add # in front of these keywords
    sed -i '/^ICHARG\|^NEDOS\|^LORBIT/s/^/# /' "$folder"/INCAR
    # Remove # in front of these keywords
    sed -i '/^\s*#\s*ISTART/s/^#\s*//' "$folder"/INCAR
    sed -i '/^\s*#\s*LWAVE/s/^#\s*//' "$folder"/INCAR
    sed -i '/^\s*#\s*LCHARG/s/^#\s*//' "$folder"/INCAR
    sed -i '/^\s*#\s*LPARD/s/^#\s*//' "$folder"/INCAR
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
			EINTMAX=$(awk -v var="$band_index" -v col="$column_num" '$1 == var {print $col; exit}' EIGENVAL)
			EINTMIN=$EINTMAX
		else
			band_index=$(echo "${num_array[@]}")
			range=$(seq $band_index)
			for i in $range; do
			    val=$(awk -v num=$i -v col=$column_num '$1 == num {print $col}' EIGENVAL)
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
		sed -i '/^\s*#\s*EINT/s/^#\s*//' "$folder"/INCAR
		sed -i '/^\s*#\s*NBMOD/s/^#\s*//' "$folder"/INCAR
		sed -i "s/^NBMOD = .*/NBMOD = -2 #/" $folder/INCAR
		sed -i "s/^EINT = .*/EINT = $(echo $eint) #/" $folder/INCAR
		unset EINTMIN EINTMAX
	else
		iband=$(seq $range)
		sed -i '/^\s*#\s*IBAND/s/^#\s*//' "$folder"/INCAR
		sed -i "s/^IBAND = .*/IBAND = $(echo $iband) #/" $folder/INCAR
	fi
    else
        iband=$i
	sed -i '/^\s*#\s*IBAND/s/^#\s*//' "$folder"/INCAR
	sed -i "s/^IBAND = .*/IBAND = $(echo $iband) #/" $folder/INCAR
    fi

done

echo -e "Do you want to submit the jobs?\n1 YES\n2 NO"
read SUBMIT_CHOICE
if [ $SUBMIT_CHOICE -eq '1' ] ; then
        for i in "${@:2}" ; do
		folder="STM_${i}"
                cd $folder
                echo -e "\n========================================\nSubmission in process, please wait...\n..."
                echo "qsub $1"
                /opt/pbs/default/bin/qsub $1 && echo -e "\nJob submitted!\n========================================"
                cd ..
        done
else
        echo -e "\n========================================\nDone!\n========================================"
fi

