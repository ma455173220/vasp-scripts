#!/bin/bash

#############################################
# Function: Dependency check
#############################################
check_dependencies() {
    echo ">>> Checking dependencies..."
    for cmd in supercell atomkit sbatch; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ Missing dependency: $cmd"
            echo "Please install or load module for $cmd before running."
            exit 1
        fi
    done
    echo "✅ All dependencies OK."
}

#############################################
# Ask prefix once at start
#############################################
read -p "Enter material prefix (e.g., BSTO, MgO, ZrS2): " prefix

#############################################
# Function: Generate supercells
#############################################
generate_supercells() {
    read -p "Enter input CIF file name (e.g., ${prefix}.cif): " cif_file
    read -p "Enter supercell size (e.g., 2x3x2): " supercell_size
    read -p "Enter output folder (default: geo): " out_dir
    out_dir=${out_dir:-geo}

    mkdir -p "$out_dir"
    echo ">>> Running supercell generation..."
    supercell -s "$supercell_size" -i "$cif_file" -m -o "$out_dir/${prefix}"
    echo "✅ Supercell generation completed. Files saved in $out_dir"
}

#############################################
# Function: Convert CIF to VASP
#############################################
convert_cif_to_vasp() {
    read -p "Enter folder containing CIF files (default: geo): " cif_dir
    cif_dir=${cif_dir:-geo}
    cd $cif_dir

    echo ">>> Converting CIF to VASP format..."
    for cif in *.cif; do
        base=${cif%.cif}
        echo -e "1\n175\n113 $cif\n" | atomkit > /dev/null
        rm $cif
        echo "Converted $cif -> ${base}.vasp"
    done
    cd ..
    echo "✅ Conversion completed."
}

#############################################
# Function: Submit VASP jobs
#############################################
submit_vasp_jobs() {
    read -p "Enter folder containing *.vasp files (default: geo): " vasp_dir
    vasp_dir=${vasp_dir:-geo}

    echo ">>> Submitting VASP jobs..."
    for vaspfile in "$vasp_dir"/*.vasp; do
        [ -e "$vaspfile" ] || continue
        name=$(basename "$vaspfile" .vasp)

        mkdir -p "$name"
        cp "$vaspfile" "$name/POSCAR"
        cp INCAR POTCAR KPOINTS vasp_runscript "$name/"
        cd "$name" || exit
        sbatch vasp_runscript
        cd ..
    done
    echo "✅ VASP jobs submitted."
}

#############################################
# Function: Extract energies
#############################################
extract_energies() {
    output_file="${prefix}_energy_summary.csv"
    echo "Directory,Energy(eV)" > $output_file

    echo ">>> Extracting energies..."
    for dir in ${prefix}_*; do
        if [ -d "$dir" ]; then
            outcar="$dir/OUTCAR"
            oszicar="$dir/OSZICAR"

            if grep -q "reached required accuracy" "$outcar" 2>/dev/null && \
               grep -q "Total CPU time used" "$outcar" 2>/dev/null; then

                energy=$(grep "E0=" "$oszicar" | tail -1 | awk '{print $5}')
                if [ -n "$energy" ]; then
                    echo "$dir,$energy" >> $output_file
                    echo "✅ $dir converged: Energy = $energy eV"
                else
                    echo "⚠️ $dir converged but energy not found"
                fi
            else
                echo "❌ $dir did not converge"
            fi
        fi
    done
    echo "Results written to $output_file"
}

#############################################
# Main Menu
#############################################
check_dependencies

while true; do
    echo "==============================="
    echo "    VASP Automation Pipeline"
    echo "Prefix: $prefix"
    echo "==============================="
    echo "1) Generate supercells"
    echo "2) Convert CIF to VASP"
    echo "3) Submit VASP jobs"
    echo "4) Extract energies"
    echo "5) Exit"
    read -p "Choose an option: " choice

    case $choice in
        1) generate_supercells ;;
        2) convert_cif_to_vasp ;;
        3) submit_vasp_jobs ;;
        4) extract_energies ;;
        5) echo "Exiting..."; break ;;
        *) echo "Invalid choice." ;;
    esac
done
