#!/bin/bash


NEW_DIRECTORY="SOC"
FILES_REMOVED=""
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

# Submission script(s): files whose first 4 KB contain #PBS / #SBATCH (big outputs are not read)
SUBMISSION_SCRIPT=""
for f in *; do
    [ -f "$f" ] || continue
    case "$f" in CHGCAR|CHG|WAVECAR|vasprun.xml|vaspout.h5|PROCAR|POTCAR|DOSCAR|OUTCAR|*_OUTCAR|XDATCAR|AECCAR*|LOCPOT|ELFCAR) continue ;; esac
    runscript_scheduler "$f" >/dev/null && SUBMISSION_SCRIPT="${SUBMISSION_SCRIPT:+$SUBMISSION_SCRIPT }$f"
done
[ -z "$SUBMISSION_SCRIPT" ] && echo -e "\033[33mWARNING:\033[0m no #PBS/#SBATCH submission script found in $PWD"
FILES_NEEDED="INCAR CONTCAR POTCAR KPOINTS $SUBMISSION_SCRIPT"
LN_FILES_NEEDED="CHGCAR"
echo $FILES_NEEDED $LN_FILES_NEEDED

echo "---------------------------------------------------------"
CONVERGENCE_TEST=`grep 'EDIFF is reached' $PWD/OUTCAR`
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

    for files in $LN_FILES_NEEDED ; do
        if [ -s $files ] ; then
            cd $NEW_DIRECTORY
            ln -s ../$files .
            cd ..
            echo "link '$files' -> '$NEW_DIRECTORY/$files'"
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
	    elements=$(poscar_species POSCAR)   # Ti_pv/<hash> -> Ti
	
	    # Define lists of d-block and f-block elements
        # Group 3-12 elements
        d_elements=("Sc" "Ti" "V" "Cr" "Mn" "Fe" "Co" "Ni" "Cu" "Zn" "Y" "Zr" "Nb" "Mo" "Tc" "Ru" "Rh" "Pd" "Ag" "Cd" "Hf" "Ta" "W" "Re" "Os" "Ir" "Pt" "Au" "Hg")
        
        # Lanthanides
        lanthanides=("La" "Ce" "Pr" "Nd" "Pm" "Sm" "Eu" "Gd" "Tb" "Dy" "Ho" "Er" "Tm" "Yb" "Lu")
        
        # Actinides
        actinides=("Ac" "Th" "Pa" "U" "Np" "Pu" "Am" "Cm" "Bk" "Cf" "Es" "Fm" "Md" "No" "Lr")
        
        # Combine all transition elements
        transition_elements=("${d_elements[@]}" "${lanthanides[@]}" "${actinides[@]}")
        
	    # Check if the elements contain any d-block or f-block elements
	    for element in "${transition_elements[@]}"; do
	        if [[ " $(echo $elements) " == *" $element "* ]]; then
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

file_editor (){
    NBANDS_COLLINEAR=$(grep -m1 'NBANDS=' OUTCAR | awk '{print $NF}')
    cd $NEW_DIRECTORY
    sed  -i 's/VASP_EXE="[^"]*"/VASP_EXE="vasp_ncl"/' $SUBMISSION_SCRIPT
    incar_set NSW 0
    incar_set IBRION -1
    incar_comment NELMIN
    incar_set LWAVE .FALSE. INCAR "(Write WAVCAR or not)"
    incar_set LCHARG .FALSE. INCAR "(Write CHGCAR or not)"
    incar_set LAECHG .FALSE. INCAR "(Bader charge analysis)"
    incar_set LSORBIT .TRUE. INCAR "(Activate SOC)"
    incar_set GGA_COMPAT .FALSE. INCAR "(Apply spherical cutoff on gradient field)"
    incar_set ISYM -1
    incar_set ICHARG 11
    if [[ "$NBANDS_COLLINEAR" =~ ^[0-9]+$ ]]; then
        incar_set NBANDS $(( NBANDS_COLLINEAR * 2 )) INCAR "(2 * number of bands of collinear-run)"
    else
        echo -e "\033[33mWARNING:\033[0m NBANDS not found in OUTCAR; set NBANDS (2 x collinear) manually."
    fi
    # Collinear MAGMOM (N values, n*m allowed) -> non-collinear "0 0 m" per atom (along SAXIS)
    local natoms=$(awk 'NR==6 && $1 ~ /^[0-9]+$/ {l = 6} NR==7 && !l {l = 7} NR==l {s = 0; for (i = 1; i <= NF; i++) s += $i; print s; exit}' POSCAR)
    local magmom=$(incar_get MAGMOM)
    if [[ -n "$magmom" ]]; then
        local expanded=$(echo "$magmom" | awk '{ for (i = 1; i <= NF; i++) if (index($i, "*")) { split($i, a, "*"); for (j = 0; j < a[1]; j++) printf "%s ", a[2] } else printf "%s ", $i }')
        local nmag=$(echo $expanded | wc -w)
        if [[ "$nmag" -eq "$natoms" ]]; then
            incar_set MAGMOM "$(echo $expanded | awk '{ for (i = 1; i <= NF; i++) printf "0 0 %s%s", $i, (i < NF ? "  " : "") }')"
            echo "MAGMOM converted to non-collinear form (0 0 m per atom, ${natoms} atoms)"
        elif [[ "$nmag" -ne $(( 3 * natoms )) ]]; then
            echo -e "\033[33mWARNING:\033[0m MAGMOM has $nmag values for $natoms atoms; check it (3 x NIONS needed)."
        fi
    fi
    if ! incar_get SAXIS >/dev/null; then
        incar_set SAXIS "0 0 1" INCAR "(quantisation axis; collinear CHGCAR magnetisation is put along SAXIS)"
        echo "SAXIS was not set: added SAXIS = 0 0 1"
    fi
    # echo -e "102\n2\n0.03\n" | vaspkit > /dev/null
    grep -iE "^[[:space:]]*(ICHARG|NSW|IBRION|NBANDS|SAXIS)[[:space:]]*=" INCAR | awk -F "#" '{print $1}'
    if [[ "$(incar_get ICHARG)" != "11" || "$(incar_get NSW)" != "0" ]]; then
        echo -e "\033[31mERROR:\033[0m INCAR in $NEW_DIRECTORY does not have ICHARG = 11 / NSW = 0 after editing. Aborting."
        exit 1
    fi
    cd ..
}


echo "---------------------------------------------------------"
file_editor
check_d_f_elements
echo "---------------------------------------------------------"

