#!/bin/bash

FILES_NEEDED="INCAR POSCAR POTCAR KPOINTS WAVECAR CHGCAR"
NEW_DIRECTORY="DOS"

echo "---------------------------------------------------------"
CONVERGENCE_TEST=`grep 'aborting loop because EDIFF is reached' $PWD/OUTCAR`
if [ "$CONVERGENCE_TEST" ] ;  then
	source $PWD/VASP_AUTO_SUBMISSION
	if [ ! -d $NEW_DIRECTORY ] ; then
		mkdir $NEW_DIRECTORY 
		echo -e "\033[32m$NEW_DIRECTORY\033[0m directory created!"
		echo "---------------------------------------------------------"
	else
		mv $NEW_DIRECTORY ${NEW_DIRECTORY}_bk
		echo -e "\033[32m$NEW_DIRECTORY\033[0m exits and has been backed up as \033[32m${NEW_DIRECTORY}_bk\033[0m!"
		mkdir $NEW_DIRECTORY
		echo "---------------------------------------------------------"
	fi
else
	echo -e "\033[31mERROR:\033[0m Job has not finished!"
	echo "---------------------------------------------------------"
	exit
fi

for files in $FILES_NEEDED ; do
	if [ -s $files ] ; then
		cp $files $NEW_DIRECTORY 
		cp $SUBMISSION_FILE_NAME $NEW_DIRECTORY
		echo "'$files' -> '$NEW_DIRECTORY/$files'"
	else
		echo -e "\033[31mERROR:\033[0m $files does not exist or is an empty file!"
		echo "---------------------------------------------------------"
		exit
	fi
done

file_editor (){ 
	cd $NEW_DIRECTORY
	sed  -i '/^NSW/ s/=.*#/=  0            #/' INCAR
	sed  -i '/^IBRION/ s/=.*#/=  -1            #/' INCAR
	sed  -i '/^ISMEAR/ s/=.*#/=  -5            #/' INCAR
	sed  -i '0,/# LCHARG/ s/# LCHARG/LCHARG/' INCAR
	sed  -i '/^LCHARG/ s/=.*#/=  .FALSE.            #/' INCAR
	sed  -i '0,/# LWAVE/ s/# LWAVE/LWAVE/' INCAR
	sed  -i '/^LWAVE/ s/=.*#/=  .FALSE.            #/' INCAR
	sed  -i '0,/# ICHARG/ s/# ICHARG/ICHARG/' INCAR
	sed  -i '/^ICHARG/ s/=.*#/=  11            #/' INCAR
	sed  -i '0,/# LORBIT/ s/# LORBIT/LORBIT/' INCAR
	sed  -i '/^LORBIT/ s/=.*#/=  11            #/' INCAR
	sed  -i '0,/# NEDOS/ s/# NEDOS/NEDOS/' INCAR
	sed  -i '/^NEDOS/ s/=.*#/=  3000            #/' INCAR
	grep -E "^NSW|^LORBIT|^IBRION|^LCHARG|^LWAVE|^ICHARG|^NEDOS|^ISMEAR" INCAR | awk -F "#" '{print $1}' 
	cd ..
}

kpoints_vaspkit_generation (){

	echo -e "\033[32mKPOINTS\033[0m should be denser: k*a~45!"
	cd $NEW_DIRECTORY
	echo -e "102\n2\n0.02\n" | vaspkit 1>/dev/null
	echo -e "A denser 0.02 KPOINTS has been automatically created by vaspkit!"
	cd ..

}

job_submission (){
	
	cd $NEW_DIRECTORY	
	/opt/pbs/default/bin/qsub $SUBMISSION_FILE_NAME
	cd ..

}

echo "---------------------------------------------------------"
file_editor
echo "---------------------------------------------------------"
kpoints_vaspkit_generation
echo "---------------------------------------------------------"
job_submission
echo "---------------------------------------------------------"
