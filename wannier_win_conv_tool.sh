#!/bin/bash

# ========== USER CONFIGURATION ==========
seedname="wannier90"  # file prefix
target_param="dis_froz_max"  # Set this to dis_froz_max, dis_win_max, dis_froz_min, dis_win_min, etc.
template_win="${seedname}.win"
template_script="wannier90_runscript"
files_to_link=("${seedname}.mmn" "${seedname}.amn" "${seedname}.eig")
band_data="${seedname}_band.dat"
submit_cmd="sbatch --qos=high"  # customize this for your HPC system
reference_band="bands.dat.gnu"
clean_band="bands_clean.dat"
pyw90_bnd_dat="bnd.dat"          # required by pyw90 cmp band (VASP bnd.dat)
# ========================================

# === Function: Clean reference band file ===
function clean_band_file() {
  awk '{
    if ($1 ~ /^[-+0-9.eE]+$/ && $2 ~ /^[-+0-9.eE]+$/) {
      print $1, $2;
    } else {
      print "";
    }
  }' "$reference_band" > "$clean_band"
  echo "ℹ️  Cleaned $reference_band → $clean_band with blank lines for missing bands"
}

# === Function: Check pyw90 is installed ===
function check_pyw90() {
  if ! command -v pyw90 &>/dev/null; then
    echo "❌ pyw90 is not installed or not in PATH."
    echo "   Install it with:  pip install pyw90"
    echo "   Then verify with: pyw90 --help"
    return 1
  fi
  return 0
}

# === Function: Prompt user for optional yrange ===
function prompt_yrange() {
  echo "Set energy (y-axis) range? (y/n) [default: auto]:"
  read use_yrange
  ymin=""
  ymax=""
  if [[ "$use_yrange" == "y" ]]; then
    echo "Enter ymin and ymax separated by space (e.g., -4.5 2.0):"
    read ymin ymax
    if [[ -z "$ymin" || -z "$ymax" ]]; then
      echo "⚠️  Invalid input, falling back to auto yrange."
      ymin=""
      ymax=""
    else
      echo "ℹ️  yrange set to [$ymin : $ymax]"
    fi
  fi
}

# === Function 1: Set up folders & optionally submit jobs ===
function generate_dirs_and_inputs() {
  echo "Enter start, end, and step (e.g., 1 10 0.1):"
  read start end step

  echo "Submit jobs automatically after setup? (y/n):"
  read submit_choice

  values=$(awk -v s=$start -v e=$end -v st=$step 'BEGIN { for (i = s; i <= e+1e-8; i += st) printf "%.4f\n", i }')

  for val in $values; do
    folder="${target_param}_${val}"
    if [[ -d "$folder" ]]; then
      echo "⚠️  $folder exists, clearing content..."
      rm -rf "$folder"/*
    else
      mkdir -p "$folder"
    fi

    cp "$template_win" "$folder/"
    cp "$template_script" "$folder/"

    sed -i "s/^$target_param.*/$target_param = $val/" "$folder/$template_win"

    for file in "${files_to_link[@]}"; do
      ln -s ../"$file" "$folder/$file"
    done

    echo "✅ Prepared $folder with $target_param = $val"

    if [[ "$submit_choice" == "y" ]]; then
      (
        cd "$folder" || exit
        $submit_cmd "$template_script"
      )
      echo "🚀 Job submitted in $folder"
    fi
  done
}

# === Function 2: Plot band structure comparison (gnuplot) ===
function plot_band_gnuplot() {
  echo "Enter start, end, and step (e.g., 1 10 0.1):"
  read start end step

  # Prefer bnd.dat if present, otherwise fall back to bands.dat.gnu
  if [[ -f "$pyw90_bnd_dat" ]]; then
    reference_band="$pyw90_bnd_dat"
    echo "ℹ️  Using $pyw90_bnd_dat as reference band file."
  elif [[ -f "$reference_band" ]]; then
    echo "ℹ️  Using $reference_band as reference band file."
  else
    echo "❌ Error: neither '$pyw90_bnd_dat' nor '$reference_band' found in current directory."
    return
  fi

  prompt_yrange
  clean_band_file
  max_col=$(awk '{if (NF > max) max=NF} END {print max}' "$clean_band")
  values=$(awk -v s=$start -v e=$end -v st=$step 'BEGIN { for (i = s; i <= e+1e-8; i += st) printf "%.4f\n", i }')

  echo "🎨 Plotting Wannier vs DFT reference band using gnuplot..."

  # Build optional yrange line for gnuplot
  if [[ -n "$ymin" && -n "$ymax" ]]; then
    yrange_cmd="set yrange [$ymin:$ymax]"
  else
    yrange_cmd="# yrange: auto"
  fi

  for val in $values; do
    folder="${target_param}_${val}"
    file="$folder/$band_data"
    out_png="${target_param}_${val}_compare-gnu.png"

    if [[ -f "$file" ]]; then
      plotcmd="\"$file\" using 1:2 with points pointtype 7 pointsize 1.0 lc rgb 'blue' title 'Wannier band'"
      for ((i=2; i<=max_col; i++)); do
        plotcmd+=", \"$clean_band\" using 1:$i with lines lw 2 lc rgb 'black' notitle"
      done

      gnuplot -persist <<EOF
set terminal pngcairo size 1600,1200 enhanced font 'Arial,14'
set output "$out_png"
set title "${target_param} = $val vs DFT reference" noenhanced
set xlabel "k-path"
set ylabel "Energy (eV)"
$yrange_cmd
set grid
plot $plotcmd
EOF
      echo "✅ Generated plot: $out_png"
    else
      echo "⚠️  Skipped $folder: file '$band_data' not found"
    fi
  done
}

# === Function 3: Plot band structure comparison (pyw90 cmp band) ===
function plot_band_pyw90() {
  # Pre-flight checks
  check_pyw90 || return

  # bnd.dat must exist in the current (parent) directory
  bnd_abs="$(pwd)/$pyw90_bnd_dat"
  if [[ ! -f "$bnd_abs" ]]; then
    echo "❌ Error: '$pyw90_bnd_dat' not found in the current directory."
    echo ""
    echo "   pyw90 cmp band requires a VASP band file in p4vasp format (default name: bnd.dat)."
    echo "   Typical ways to obtain it:"
    echo ""
    echo "   Option A — via pyw90 itself (recommended):"
    echo "     pyw90 pre bnd         # extracts bnd.dat from EIGENVAL in the current dir"
    echo ""
    echo "   Option B — via vaspkit:"
    echo "     vaspkit -task 211     # produces REFORMATTED_BAND.dat"
    echo "     mv REFORMATTED_BAND.dat bnd.dat"
    echo ""
    echo "   Place bnd.dat in the same directory as this script, then re-run."
    return
  fi

  echo "Enter start, end, and step (e.g., 1 10 0.1):"
  read start end step

  sys_name="$seedname"

  # Check vasprun.xml exists in current dir for symlinking
  vasprun_abs="$(pwd)/vasprun.xml"
  if [[ ! -f "$vasprun_abs" ]]; then
    echo "⚠️  vasprun.xml not found in current directory."
    echo "   pyw90 needs it to read the Fermi level automatically."
    echo "   Please copy or symlink it here, or provide --efermi manually."
    echo "   Alternatively, enter the Fermi level now (or press Enter to abort):"
    echo "   Tip: grep 'E-fermi' OUTCAR | tail -1"
    read efermi
    if [[ -z "$efermi" ]]; then
      echo "❌ Aborted: no vasprun.xml and no Fermi level provided."
      return
    fi
    efermi_arg="--efermi $efermi"
  else
    efermi_arg=""  # pyw90 will read vasprun.xml via symlink
  fi

  prompt_yrange

  # Build --ylim args
  ylim_args=""
  if [[ -n "$ymin" && -n "$ymax" ]]; then
    ylim_args="--ylim $ymin $ymax"
  fi

  values=$(awk -v s=$start -v e=$end -v st=$step \
    'BEGIN { for (i = s; i <= e+1e-8; i += st) printf "%.4f\n", i }')

  echo "🎨 Plotting Wannier vs DFT reference band using pyw90 cmp band..."

  for val in $values; do
    folder="${target_param}_${val}"

    if [[ ! -f "$folder/$band_data" ]]; then
      echo "⚠️  Skipped $folder: '$band_data' not found"
      continue
    fi

    echo "ℹ️  Processing $folder ..."

    # Soft-link bnd.dat into the subfolder so pyw90 can find it via --path
    if [[ ! -e "$folder/$pyw90_bnd_dat" ]]; then
      ln -s "$bnd_abs" "$folder/$pyw90_bnd_dat"
    fi

    # Run pyw90 cmp band from the parent dir, pointing it at the subfolder
    # --path sets the working dir (where .win/.wout and bnd.dat live)
    # --vasp overrides the bnd.dat filename if needed (here it's the default)
    # --seedname sets the w90 seedname
    # Symlink vasprun.xml into subfolder if available
    if [[ -n "$vasprun_abs" && -f "$vasprun_abs" && ! -e "$folder/vasprun.xml" ]]; then
      ln -s "$vasprun_abs" "$folder/vasprun.xml"
    fi

    pyw90 cmp \
      --path "$folder" \
      --seedname "$seedname" \
      --vasp "$pyw90_bnd_dat" \
      $efermi_arg \
      $ylim_args \
      "$sys_name"

    if [[ $? -eq 0 ]]; then
      # pyw90 writes output inside --path; rename/move to parent with descriptive name
      # The default output filename produced by pyw90 is: <name>_cmp.png  (or similar)
      # Adjust the glob pattern below if your version uses a different naming convention
      # pyw90 outputs: <sys_name>_VASP_W90_cmp.pdf inside --path dir
      src="$folder/${sys_name}_VASP_W90_cmp.pdf"
      dest="${target_param}_${val}_compare-pyw90.pdf"
      if [[ -f "$src" ]]; then
        mv "$src" "$dest"
        echo "✅ Generated plot: $dest"
      else
        echo "⚠️  Expected output '$src' not found. Check pyw90 output above."
      fi
    else
      echo "❌ pyw90 cmp band failed for $folder. Check the output above for details."
    fi
  done
}

# === MAIN MENU ===
echo "============================================"
echo "  Wannier90 Convergence Tool"
echo "============================================"
echo "Select a function:"
echo "  1. Setup calculation folders and optionally submit jobs"
echo "  2. Plot band structure comparisons — gnuplot"
echo "  3. Plot band structure comparisons — pyw90 cmp band"
read -p "Enter choice (1/2/3): " choice

if [[ "$choice" == "1" ]]; then
  generate_dirs_and_inputs
elif [[ "$choice" == "2" ]]; then
  plot_band_gnuplot
elif [[ "$choice" == "3" ]]; then
  plot_band_pyw90
else
  echo "❌ Invalid choice. Exiting."
fi
