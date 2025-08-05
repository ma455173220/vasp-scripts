#!/bin/bash
# =====================================================
# Auto-generate INCAR_step1, INCAR_step2, INCAR_scf, INCAR_band, INCAR_dos
# Auto-generate KPOINTS_scf, KPOINTS_band, KPOINTS_dos
# Auto-generate vasp_runscript for each step
# =====================================================

ROOT_DIR=$(pwd)

# ===== Configurable variable for runscript base name =====
RUNSCRIPT_BASE="vasp_runscript"  # Change this prefix to customize submission script names
                                 # Scripts will be ${RUNSCRIPT_BASE}_step1, ${RUNSCRIPT_BASE}_scf, etc.

# ===== Function: separator =====
separator() {
    echo "============================================================"
    echo ">>> $1"
}

# ===== Function: update_key =====
update_key() {
    local file=$1
    local key=$2
    local value=$3
    local comment=$4

    active_count=$(grep -i "^[[:space:]]*$key[[:space:]]*=" "$file" | wc -l)

    if (( active_count > 1 )); then
        echo "⚠️ Multiple active $key found in $file. Keeping first and commenting out others."
        awk -v key="$key" '
        BEGIN{IGNORECASE=1; count=0}
        {
            if ($0 ~ "^[[:space:]]*"key"[[:space:]]*=") {
                count++
                if (count > 1) {
                    sub(/^([[:space:]]*)/, "&#")
                    print $0
                } else {
                    print $0
                }
            } else {
                print $0
            }
        }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi

    if [[ "$value" == "COMMENT" ]]; then
        if grep -qi "^[[:space:]]*$key[[:space:]]*=" "$file"; then
            sed -i "0,/^[[:space:]]*$key[[:space:]]*=/s//\#&/" "$file"
            echo "🔧 $key commented in $file"
        else
            echo "ℹ️ $key not found in $file, nothing to comment"
        fi
        return
    fi

    if grep -qi "$key" "$file"; then
        sed -i "0,/^\(#\s*\)\?\s*$key\s*=.*/s//${key} = ${value}    #${comment}/" "$file"
        echo "🔧 $key set to $value in $file"
    else
        echo "${key} = ${value}    #${comment}" >> "$file"
        echo "➕ $key added as $value in $file"
    fi
}

# ===== Step 1 =====
separator "STEP 1: Generating INCAR_step1"
cp INCAR INCAR_step1
echo -e "102\n1\n0.04\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_step1
echo "🔧 KPOINTS_step1 generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step1"

# ===== Step 2 =====
separator "STEP 2: Generating INCAR_step2"
cp INCAR INCAR_step2
update_key INCAR_step2 "LREAL" "COMMENT" "Disable LREAL=Auto for second optimization"
echo -e "102\n1\n0.04\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_step2
echo "🔧 KPOINTS_step2 generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_step2"

# ===== Step 3 =====
separator "STEP 3: Generating INCAR_scf"
cp INCAR_step2 INCAR_scf
update_key INCAR_scf "LWAVE"  ".TRUE."   "Write WAVECAR"
update_key INCAR_scf "LCHARG" ".TRUE."   "Write CHGCAR"
update_key INCAR_scf "LAECHG" ".TRUE."   "Write AECCAR for Bader analysis"
update_key INCAR_scf "NSW"    "0"        "Non-SCF calculation"
update_key INCAR_scf "IBRION" "-1"       "Non-SCF calculation"
update_key INCAR_scf "IOPT"   "COMMENT"  "Disable IOPT for SCF"
update_key INCAR_scf "ICORELEVEL" "1" "Core energies"
update_key INCAR_scf "LVTOT" ".TRUE."    "Write total local potential"

# ===== Step 4 =====
echo ">>> STEP 4: LMAXMIX Adjustment based on POSCAR"
if [ -f "POSCAR" ]; then
    echo "Checking elements in POSCAR for LMAXMIX adjustment..."
    elements=$(awk 'NR==6 {for (i=1; i<=NF; i++) print $i}' POSCAR)

    d_elements=("Sc" "Ti" "V" "Cr" "Mn" "Fe" "Co" "Ni" "Cu" "Zn" "Y" "Zr" "Nb" "Mo" "Tc" "Ru" "Rh" "Pd" "Ag" "Cd" "W" "Pt" "Au" "Hg")
    lanthanides=("La" "Ce" "Pr" "Nd" "Pm" "Sm" "Eu" "Gd" "Tb" "Dy" "Ho" "Er" "Tm" "Yb" "Lu")
    actinides=("Th" "Pa" "U" "Np" "Pu" "Am" "Cm" "Bk" "Cf" "Es" "Fm" "Md" "No" "Lr")

    contains_d=false
    contains_f=false

    for e in $elements; do
        if [[ " ${d_elements[@]} " =~ " $e " ]]; then contains_d=true; fi
        if [[ " ${lanthanides[@]} " =~ " $e " || " ${actinides[@]} " =~ " $e " ]]; then contains_f=true; fi
    done

    if [ "$contains_f" = true ]; then
        update_key INCAR_scf "LMAXMIX" "6" "f-electron detected"
    elif [ "$contains_d" = true ]; then
        update_key INCAR_scf "LMAXMIX" "4" "d-electron detected"
    else
        echo "ℹ️ No d/f electrons detected, LMAXMIX unchanged."
    fi
fi

# ===== Step 5 =====
echo ">>> STEP 5: Generating KPOINTS_scf"
echo -e "102\n1\n0.03\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_scf
echo "🔧 KPOINTS_scf generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_scf"

# ===== Step 6 =====
separator "STEP 6: Generating INCAR_band"
cp INCAR_scf INCAR_band
update_key INCAR_band "ICHARG" "11"     "Band structure calculation"
update_key INCAR_band "LWAVE"  ".FALSE." "Disable WAVECAR"
update_key INCAR_band "LCHARG" ".FALSE." "Disable CHGCAR"
update_key INCAR_band "LAECHG" ".FALSE." "Disable AECCAR"
update_key INCAR_band "ICORELEVEL" "COMMENT" "Core energies"
update_key INCAR_band "LVTOT" "COMMENT"    "Write total local potential"
echo ">>> STEP 7: Generating KPOINTS_band"
echo -e "303\n" | vaspkit > /dev/null 2>&1
mv KPATH.in KPOINTS_band
echo "🔧 KPOINTS_band generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_band"

# ===== Step 8 =====
separator "STEP 8: Generating INCAR_dos"
cp INCAR_band INCAR_dos
update_key INCAR_dos "NEDOS"  "3001" "DOS calculation points"
update_key INCAR_dos "LORBIT" "11"   "Projection for DOS"
echo "⚠️ Please manually set EMIN and EMAX in INCAR_dos according to your system!"
echo ">>> STEP 9: Generating KPOINTS_dos"
echo -e "102\n1\n0.02\n" | vaspkit > /dev/null 2>&1
mv KPOINTS KPOINTS_dos
echo "🔧 KPOINTS_dos generated."
cp "$RUNSCRIPT_BASE" "${RUNSCRIPT_BASE}_dos"

echo "✅ All INCAR_xxx, KPOINTS_xxx, and ${RUNSCRIPT_BASE}_xxx generated successfully."
