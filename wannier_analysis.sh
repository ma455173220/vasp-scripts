#!/bin/bash

# This script is used to analyze the wannier90 output files
# check if $1 is exist

if [ -z "$1" ]; then
    echo "Usage: wannier_analysis.sh <wannier90 output file>"
    exit 1
fi

grep "<-- CONV" $1 | awk '{print $1,$2,$4}' > convergence.txt
# grep "Cycle:" $1 | paste - <(grep "<-- SPRD" $1 | tail -n +2 | awk '{print $(NF-3),$(NF-2),$(NF-1),$NF}' ) | paste - <(grep "<-- DLTA" $1| awk  '{print $(NF-3),$(NF-2),$(NF-1),$NF}' ) > convergence.txt

echo -e "\n\e[32mResults written to convergence.txt.\e[0m"
echo -e "\nTo plot the data, use \e[1mgnuplot\e[0m with the following command:"
echo -e "\e[36mplot 'convergence.txt' using 1:3 with points\e[0m\n"
