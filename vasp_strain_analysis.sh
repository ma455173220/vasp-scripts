#!/bin/bash

# This script extracts EFG Tensor eigenvalues information from VASP output files
# in all directories named as "strain_{number}" in the current directory.
# The information will be saved in a ".csv" file, with the first column representing the number in "strain_{number}"
# and the second to fourth columns representing the EFG Tensor eigenvalues.

keyword="Electric field gradients (V/A^2)"

# Get a list of directories that start with "strain_" in the current directory
directories=$(ls -d strain_*)

# Initialize the output file with a header
echo "strain ion V_xx V_yy V_zz V_xy V_xz V_yz" > output.csv

# Loop through each directory
for dir in $directories; do

    # Extract the strain number from the directory name
    strain=$(echo $dir | sed 's/strain_//')
    strain_minus_1=$(echo "$strain - 1" | bc -l)
    strain_minus_1=$(printf "%.4f" $strain_minus_1)
    
    # Check if the VASP output file exists and is not empty
    file="$dir/OUTCAR"
    if [ ! -s $file ]; then
        echo "VASP output file does not exist or is empty in directory $dir"
        continue
    fi

    # Check if the VASP run has completed
    if ! grep -q "Total CPU time used (sec):" $file; then
        echo "VASP run has not completed in directory $dir"
        continue
    fi

    # Extract the EFG Tensor eigenvalues information
    eig_values=$(grep "$keyword" $file -A 4 | tail -1)

    # Check if the information is extracted successfully
    if [ -z "$eig_values" ]; then
        echo "Failed to extract EFG Tensor eigenvalues information in directory $dir"
        continue
    fi

    # Write the information to the output file
    echo "$strain_minus_1 $eig_values " >> output.csv

done

# Sort the output file by the first column in reverse order
# sort -g -k1 output.csv output.csv
sort -g -k1 -o output.csv output.csv


# Print a message indicating the completion of the script
echo "Finished extracting EFG Tensor eigenvalues information from VASP output files in directories starting with 'strain_'. The results are saved in 'output.csv'."

