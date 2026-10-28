#!/bin/bash
# Disordered-structure pipeline: supercell -> CIF to VASP -> submit -> energies (PBS or Slurm).
#
# Usage: superfrac_slurm.sh                         (menu)
#        superfrac_slurm.sh [options] ACTION...     (no menu; asks only for missing values)
#   ACTION: 1|generate  2|convert  3|submit  4|extract   (run in the order given)
#   -p PREFIX     material prefix (e.g. BSTO)
#   -i CIF        input CIF for "generate"
#   -s SIZE       supercell size for "generate" (e.g. 2x3x2)
#   -d DIR        folder for the CIF / *.vasp files (default: geo)
#   -r SCRIPT     job script copied into each structure folder (default: vasp_runscript)
# Example: superfrac_slurm.sh -p BSTO -i BSTO.cif -s 2x2x2 generate convert submit

# Shared helpers (vasp_common.sh): next to this script, else on PATH
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_common.sh"; [ -f "$_lib" ] || _lib=$(command -v vasp_common.sh || true)
[ -n "$_lib" ] || { echo "ERROR: vasp_common.sh not found (next to this script or on PATH)" >&2; exit 1; }
source "$_lib"

prefix=""
cif_file=""
supercell_size=""
work_dir=""
runscript="vasp_runscript"
while getopts ":p:i:s:d:r:h" opt; do
    case $opt in
        p) prefix="$OPTARG" ;;
        i) cif_file="$OPTARG" ;;
        s) supercell_size="$OPTARG" ;;
        d) work_dir="$OPTARG" ;;
        r) runscript="$OPTARG" ;;
        h) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "Unknown option (use -h)"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
ACTIONS=("$@")

#############################################
# Function: Dependency check
#############################################
check_dependencies() {
    echo ">>> Checking dependencies..."
    for cmd in supercell atomkit; do
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
[ -n "$prefix" ] || read -p "Enter material prefix (e.g., BSTO, MgO, ZrS2): " prefix

#############################################
# Function: Generate supercells
#############################################
generate_supercells() {
    [ -n "$cif_file" ] || read -p "Enter input CIF file name (e.g., ${prefix}.cif): " cif_file
    [ -n "$supercell_size" ] || read -p "Enter supercell size (e.g., 2x3x2): " supercell_size
    local out_dir="$work_dir"
    [ -n "$out_dir" ] || [ ${#ACTIONS[@]} -gt 0 ] || read -p "Enter output folder (default: geo): " out_dir
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
    local cif_dir="$work_dir"
    [ -n "$cif_dir" ] || [ ${#ACTIONS[@]} -gt 0 ] || read -p "Enter folder containing CIF files (default: geo): " cif_dir
    cif_dir=${cif_dir:-geo}
    cd "$cif_dir" || { echo "❌ Cannot enter folder: $cif_dir"; return 1; }

    echo ">>> Converting CIF to VASP format..."
    for cif in *.cif; do
        [ -e "$cif" ] || continue
        base=${cif%.cif}
        echo -e "1\n175\n113 $cif\n" | atomkit > /dev/null
        if [ -s "${base}.vasp" ]; then
            rm "$cif"
            echo "Converted $cif -> ${base}.vasp"
        else
            echo "⚠️ ${base}.vasp not written by atomkit; $cif kept"
        fi
    done
    cd - > /dev/null
    echo "✅ Conversion completed."
}

#############################################
# Function: Submit VASP jobs
#############################################
submit_vasp_jobs() {
    local vasp_dir="$work_dir"
    [ -n "$vasp_dir" ] || [ ${#ACTIONS[@]} -gt 0 ] || read -p "Enter folder containing *.vasp files (default: geo): " vasp_dir
    vasp_dir=${vasp_dir:-geo}

    local sub_cmd=$(submit_cmd_of "$runscript")
    if ! command -v "$sub_cmd" &> /dev/null; then
        echo "❌ $sub_cmd not found; load the scheduler module first."
        return 1
    fi
    echo ">>> Submitting VASP jobs ($sub_cmd)..."
    for vaspfile in "$vasp_dir"/*.vasp; do
        [ -e "$vaspfile" ] || continue
        name=$(basename "$vaspfile" .vasp)

        mkdir -p "$name"
        cp "$vaspfile" "$name/POSCAR"
        cp INCAR POTCAR KPOINTS "$runscript" "$name/"
        cd "$name" || exit
        $sub_cmd "$runscript"
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
            oszicar="$dir/OSZICAR"

            # converged by the same rules as VASP_JOB_PARAMETERS (vasp_common.sh)
            if vasp_job_status -f "$dir" > /dev/null; then

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

run_action() {
    case $1 in
        1|generate) generate_supercells ;;
        2|convert) convert_cif_to_vasp ;;
        3|submit) submit_vasp_jobs ;;
        4|extract) extract_energies ;;
        *) echo "Invalid choice: $1"; return 1 ;;
    esac
}

#############################################
# Actions from the command line: no menu
#############################################
if [ ${#ACTIONS[@]} -gt 0 ]; then
    for a in "${ACTIONS[@]}"; do
        case $a in 1|generate|2|convert) check_dependencies; break ;; esac
    done
    for a in "${ACTIONS[@]}"; do
        run_action "$a" || exit 1
    done
    exit 0
fi

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
        1|2|3|4) run_action "$choice" ;;
        5) echo "Exiting..."; break ;;
        *) echo "Invalid choice." ;;
    esac
done
