#!/bin/bash

SUBMISSION_SCRIPT=$(grep -l "#PBS -P ad73" * -d skip)
COPY_FILES_NEEDED="INCAR POSCAR POTCAR $SUBMISSION_SCRIPT"
LN_FILES_NEEDED="CHGCAR"
NEW_DIRECTORY="DOS"

echo "---------------------------------------------------------"

if [ ! -d $NEW_DIRECTORY ] ; then
	mkdir $NEW_DIRECTORY 
	echo -e "$NEW_DIRECTORY directory created!"
	echo "---------------------------------------------------------"
fi

for files in $COPY_FILES_NEEDED ; do
	if [ -s $files ] ; then
		cp $files $NEW_DIRECTORY 
		echo "'$files' -> '$NEW_DIRECTORY/$files'"
	else
		echo -e "\033[31mERROR:\033[0m $files does not exist or is an empty file!"
		echo "---------------------------------------------------------"
		exit
	fi
done

# Define the ln_file function
ln_file() {
	file="CHGCAR"

    # Check if the file variable is a non-empty file in the current directory
    if [[ ! -s "$file" ]]; then
        echo -e "\033[31mERROR:\033[0m $file does not exist or is an empty file!"
    fi
    cd $NEW_DIRECTORY && ln -s ../"$file" . 
    echo "'$file' -> '$NEW_DIRECTORY/$file'"
    cd ..
}

# Call the ln_file function
# ln_file

file_editor (){ 
	cd $NEW_DIRECTORY
	sed  -i '0,/# ICHARG/ s/# ICHARG/ICHARG/' INCAR
    sed  -i '0,/LAECHG/ s/LAECHG/# LAECHG/' INCAR
	sed  -i '/^ICHARG/ s/=.*#/=  11            #/' INCAR
	sed  -i '/^NSW/ s/=.*#/=  0            #/' INCAR
	sed  -i '/^IBRION/ s/=.*#/=  -1            #/' INCAR
	sed  -i '0,/# LWAVE/ s/# LWAVE/LWAVE/' INCAR
	sed  -i '/^LWAVE/ s/=.*#/=  .FALSE.            #/' INCAR
	sed  -i '0,/# LCHARG/ s/# LCHARG/LCHARG/' INCAR
	sed  -i '/^LCHARG/ s/=.*#/=  .FALSE.            #/' INCAR
	sed  -i '0,/# LORBIT/ s/# LORBIT/LORBIT/' INCAR
	sed  -i '/^LORBIT/ s/=.*#/=  11            #/' INCAR
    sed  -i '0,/# NEDOS/ s/# NEDOS/NEDOS/' INCAR
    sed  -i '/^NEDOS/ s/=.*#/=  3000            #/' INCAR
	grep -E "^NSW|^LORBIT|^IBRION|^LCHARG|^LWAVE|^ICHARG" INCAR | awk -F "#" '{print $1}'
    cd ..
}

kpoints_vaspkit_generation (){
    cd $NEW_DIRECTORY
	echo -e "102\n2\n0.02\n"| vaspkit 1>/dev/null
	echo -e "'Kmesh_0.02' generated by vaspkit!"
	# cp PRIMCELL.vasp POSCAR
	# echo -e "'PRIMCELL.vasp' -> 'POSCAR'"
    cd ..
}


echo "---------------------------------------------------------"
file_editor
echo "---------------------------------------------------------"
kpoints_vaspkit_generation
ln_file
echo "---------------------------------------------------------"
