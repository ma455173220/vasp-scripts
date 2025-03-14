#!/bin/sh


NEW_DIRECTORY="NON-SC-kmesh-0.03"
FILES_REMOVED="WAVECAR CHG* vasprun.xml PROCAR LOCPOT DOSCAR vaspout.h5"
SUBMISSION_SCRIPT=$(grep -l "#PBS -P " --exclude=CHGCAR --exclude=WAVECAR --exclude=vasprun.xml --exclude=PROCAR --exclude=POTCAR --exclude=DOSCAR --exclude=OUTCAR * -d skip)
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
    exit 1
fi

check_d_f_elements (){

	# Check if the POSCAR file exists
	if [ -f "POSCAR" ]; then
	    # Extract all element symbols from the POSCAR file
	    elements=$(awk 'NR==6 {for (i=1; i<=NF; i++) print $i}' POSCAR)
	
	    # Define lists of d-block and f-block elements
        # Group 3-12 elements
        d_elements=("Sc" "Ti" "V" "Cr" "Mn" "Fe" "Co" "Ni" "Cu" "Zn" "Y" "Zr" "Nb" "Mo" "Tc" "Ru" "Rh" "Pd" "Ag" "Cd" "W" "Pt" "Au" "Hg")
        
        # Lanthanides
        lanthanides=("La" "Ce" "Pr" "Nd" "Pm" "Sm" "Eu" "Gd" "Tb" "Dy" "Ho" "Er" "Tm" "Yb" "Lu")
        
        # Actinides
        actinides=("Th" "Pa" "U" "Np" "Pu" "Am" "Cm" "Bk" "Cf" "Es" "Fm" "Md" "No" "Lr")
        
        # Combine all transition elements
        transition_elements=("${d_elements[@]}" "${lanthanides[@]}" "${actinides[@]}")
        
	    # Check if the elements contain any d-block or f-block elements
	    for element in "${transition_elements[@]}"; do
	        if [[ "$elements" == *"$element"* ]]; then
	            # Run echo, or replace with any other command you want to execute
                echo -e "\033[33mThe POSCAR contains d or f block elements, modify LMAXMIX accordingly.\033[0m"
	            exit
	        fi
	    done
	
	    echo "POSCAR does not contain d-block or f-block elements"
	else
	    echo "POSCAR file does not exist"
	fi

}

read_kpoints(){

    # Read the content of the fourth line and split it into individual numbers 
	line=$(sed -n '4p' KPOINTS)                                                
	read -ra numbers <<< "$line"                                               
	                                                                           
	# Check if each number is equal to 1                                       
	vasp_mod="vasp_gam"                                                        
	for number in "${numbers[@]}"; do                                          
	    if [ "$number" != "1" ]; then                                          
	        vasp_mod="vasp_std"                                                
	        break                                                              
	    fi                                                                     
	done                                                                       

}

file_editor (){
    cd $NEW_DIRECTORY
    sed  -i '/^NSW/ s/=.*/=  0       #(Non SCF calculation)/' INCAR
    sed  -i '/^IBRION/ s/=.*/=  -1         #(Non SCF calculation)/' INCAR
    sed  -i '/^NELMIN/s/^/# /' INCAR
    sed  -i 's/\(#\|\)\s*LWAVE\s*=.*/LWAVE=  .TRUE.   #(Write WAVCAR or not)/' INCAR
    sed  -i 's/\(#\|\)\s*LCHARG\s*=.*/LCHARG=  .TRUE.   #(Write CHGCAR or not)/' INCAR
    sed  -i 's/\(#\|\)\s*LAECHG\s*=.*/LAECHG=  .TRUE.   #(Bader charge analysis)/' INCAR
    echo "LORBIT =  11       #(PAW radii for projected DOS)" >> INCAR
    echo "NEDOS  =  2001         #(DOSCAR points)" >> INCAR
    # Generate denser kmesh
    echo -e "102\n2\n0.03\n" | vaspkit > /dev/null
    read_kpoints
    sed -i "s/VASP_EXE=\"[^\"]*\"/VASP_EXE=\"$vasp_mod\"/" "$SUBMISSION_SCRIPT"
    grep -E "^NSW|^IBRION" INCAR | awk -F "#" '{print $1}'
    cd ..
}


echo "---------------------------------------------------------"
file_editor
check_d_f_elements
echo "---------------------------------------------------------"

