#!/bin/bash


NEW_DIRECTORY="SOC"
FILES_REMOVED=""
# Shared helpers (vasp_common.sh): next to this script, else on PATH
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"; [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh || true)
[ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"

# Submission script: header-limited scan (first 4 KB), asks if there are several ($RUNSCRIPT overrides)
SUBMISSION_SCRIPT=$(find_runscript)
[ -z "$SUBMISSION_SCRIPT" ] && echo -e "\033[33mWARNING:\033[0m no #PBS/#SBATCH submission script found (or none selected) in $PWD"
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
	if [ -f "POSCAR" ]; then
	    if [ -n "$(poscar_df_elements POSCAR)" ]; then
                echo -e "\033[33mThe POSCAR contains d or f block elements, modify LMAXMIX accordingly.\033[0m"
	        exit
	    fi
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

