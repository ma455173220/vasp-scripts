#!/bin/sh


NEW_DIRECTORY="NON-SC-kmesh-0.03"
FILES_REMOVED="WAVECAR CHG* vasprun.xml PROCAR LOCPOT DOSCAR vaspout.h5"
SUBMISSION_SCRIPT=$(grep -l "#PBS -P ad73" * -d skip)
FILES_NEEDED="INCAR CONTCAR POTCAR KPOINTS $SUBMISSION_SCRIPT"
echo $FILES_NEEDED

echo "---------------------------------------------------------"
CONVERGENCE_TEST=`grep 'reached required accuracy' $PWD/OUTCAR`
if [ "$CONVERGENCE_TEST" ] ;  then
	if [ ! -d $NEW_DIRECTORY ] ; then
		mkdir $NEW_DIRECTORY
		echo -e "\033[32m$NEW_DIRECTORY\033[0m directory created!"
		echo "---------------------------------------------------------"
	fi

	for files_remo in $FILES_REMOVED ; do
		if [ -s $files_remo ] ; then
			rm -rf $PWD/$files_remo
			echo "'$files_remo' removed"
		fi
	done

	for files in $FILES_NEEDED ; do
		if [ -s $files ] ; then
			if [ "$files" = "CONTCAR" ]; then
				cp $files $NEW_DIRECTORY/POSCAR
				echo "'$files' -> '$NEW_DIRECTORY/POSCAR'"
			else
				cp $files $NEW_DIRECTORY
				echo "'$files' -> '$NEW_DIRECTORY/$files'"
			fi
		else
			echo -e "\033[31mERROR:\033[0m $files does not exist or is an empty file!"
			echo "---------------------------------------------------------"
			exit
		fi
	done

else
	echo "Calculation not converged, no auto_submission proceeded."
fi

check_d_f_elements (){

    # Check for d and f elements in POSCAR
    if grep -qiE 'Sc|Ti|V|Cr|Mn|Fe|Co|Ni|Cu|Zn|Y|Zr|Nb|Mo|Tc|Ru|Rh|Pd|Ag|Cd|La|Ce|Pr|Nd|Pm|Sm|Eu|Gd|Tb|Dy|Ho|Er|Tm|Yb|Lu' POSCAR ||
       grep -qiE 'Ac|Th|Pa|U|Np|Pu|Am|Cm|Bk|Cf|Es|Fm|Md|No|Lr' POSCAR; then
       echo -e "\033[33mThe POSCAR contains d or f block elements, modify LMAXMIX accordingly.\033[0m"
    fi

}

file_editor (){
	cd $NEW_DIRECTORY
	sed  -i '/^NSW/ s/=.*#/=  0            #/' INCAR
	sed  -i '/^IBRION/ s/=.*#/=  -1            #/' INCAR
	sed  -i '/^NELMIN/s/^/# /' INCAR
    sed  -i '/^LWAVE/ s/=.*#/=  .TRUE.            #/' INCAR
    sed  -i '/^LCHARG/ s/=.*#/=  .TRUE.            #/' INCAR
	sed  -i '0,/# LAECHG/ s/# LAECHG/LAECHG/' INCAR
    echo -e "102\n2\n0.03\n" | vaspkit > /dev/null
	grep -E "^NSW|^IBRION" INCAR | awk -F "#" '{print $1}'
	cd ..
}


echo "---------------------------------------------------------"
file_editor
check_d_f_elements
echo "---------------------------------------------------------"

