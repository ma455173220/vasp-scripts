#!/bin/bash

TARGET_FOLDER="wanniertools"
TARGET_INPUT="$HOME/wt.in"
TARGET_RUNSCRIPT="$HOME/wanniertools_runscript"
TARGET_HR="wannier90_hr.dat"

# Check if the target folder exists; create it if it doesn't
if [ ! -d "$TARGET_FOLDER" ]; then
    mkdir "$TARGET_FOLDER"
else
    echo "Target folder $TARGET_FOLDER already exists, no need to create."
fi

# Check if the target files already exist in the target folder
if [ -f "$TARGET_FOLDER/wt.in" ] && [ -f "$TARGET_FOLDER/wanniertools_runscript" ]; then
    echo "Files wt.in and wanniertools_runscript already exist in $TARGET_FOLDER, not copying."
else
    # Copy the target files to the target folder
    if [ -f "$TARGET_INPUT" ]; then
        cp "$TARGET_INPUT" "$TARGET_FOLDER/"
        echo "Copied $TARGET_INPUT to $TARGET_FOLDER."
    else
        echo "Warning: File $TARGET_INPUT does not exist, copy operation not performed."
    fi

    if [ -f "$TARGET_RUNSCRIPT" ]; then
        cp "$TARGET_RUNSCRIPT" "$TARGET_FOLDER/"
        echo "Copied $TARGET_RUNSCRIPT to $TARGET_FOLDER."
    else
        echo "Warning: File $TARGET_RUNSCRIPT does not exist, copy operation not performed."
    fi
fi

# Link the TARGET_HR file to the target folder
if [ -f "$TARGET_HR" ]; then
    cd $TARGET_FOLDER
    ln -s ../$TARGET_HR .
    cd ..
    echo "Link $TARGET_HR to $TARGET_FOLDER."
else
    echo "Warning: File $TARGET_HR does not exist, copy operation not performed."
fi


# Write lattice parameters in wt.in
sed -i '/Angstrom/{n;N;N;d}' ${TARGET_FOLDER}/wt.in
# sed -n '3,5p' POSCAR > temp_lattice_para.txt
# sed -i '/Angstrom/r temp_lattice_para.txt' ${TARGET_FOLDER}/wt.in
grep -A 3 "Lattice Vectors" wannier90.wout | tail -3 | awk '{print $2, $3, $4}' >> temp_lattice_para.txt
sed -i '/Angstrom/r temp_lattice_para.txt' ${TARGET_FOLDER}/wt.in
rm temp_lattice_para.txt

# Write atomic coordinates in wt.in
NUMBER_OF_ATOMS=`sed -n '7p' POSCAR | awk -F ' ' '{sum = 0; for (i=1; i<=NF; i++) sum += $i} END {print sum}'`
echo $NUMBER_OF_ATOMS > temp_atom_coordinates.txt
echo "Direct" >> temp_atom_coordinates.txt
# Extract atom coordinates
grep -A $(( $NUMBER_OF_ATOMS + 1 )) "Site" wannier90.wout | tail -$NUMBER_OF_ATOMS | awk '{print $2, $4, $5, $6}' >> temp_atom_coordinates.txt
sed -i '/ATOM_POSITIONS/{n;N;N;d}' ${TARGET_FOLDER}/wt.in
sed -i '/ATOM_POSITIONS/r temp_atom_coordinates.txt' ${TARGET_FOLDER}/wt.in
rm temp_atom_coordinates.txt

# Write Fermi Energy
E_Fermi=`grep Fermi OUTCAR | tail -1 | awk -F ":" '{print $NF}' | tr -d ' '`
sed -i "s/E_FERMI = .*/E_FERMI = $E_Fermi/" ${TARGET_FOLDER}/wt.in
