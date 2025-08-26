#!/bin/bash

#===============================================================================
# VASP Strain Calculation Setup Script with Workflow Integration
# 
# Description: Generates multiple calculation folders with strained POSCAR files
#              Handles both orthogonal (90°) and hexagonal (120°) lattices
# Author: Generated for VASP strain calculations
# Usage: ./strain_generator.sh
#===============================================================================

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if file exists
check_file() {
    if [ ! -f "$1" ]; then
        print_error "File $1 not found in current directory!"
        return 1
    fi
    return 0
}

# Function to detect lattice type (90° vs 120°)
detect_lattice_type() {
    local input_file="$1"
    
    # Read lattice vectors
    local bx=$(sed -n '4p' "$input_file" | awk '{print $1}')
    local by=$(sed -n '4p' "$input_file" | awk '{print $2}')
    
    # Check if bx is negative (typical for 120° lattice)
    if (( $(echo "$bx < -1.0" | bc -l 2>/dev/null || echo "0") )); then
        echo "hexagonal_120"
    else
        echo "orthogonal_90"
    fi
}

# Function to apply uniform strain (modify scaling factor)
apply_uniform_strain() {
    local input_file="$1"
    local output_file="$2"
    local strain_value="$3"
    
    # Calculate new scaling factor: original_factor * (1 + strain)
    local original_factor=$(sed -n '2p' "$input_file" | awk '{print $1}')
    local new_factor=$(echo "$original_factor * (1 + $strain_value)" | bc -l)
    
    # Copy original file and modify scaling factor
    cp "$input_file" "$output_file"
    sed -i "2s/.*/ ${new_factor}/" "$output_file"
}

# Function to apply strain to orthogonal lattice (90°)
apply_orthogonal_strain() {
    local input_file="$1"
    local output_file="$2"
    local strain_directions="$3"
    local strain_value="$4"
    
    # Copy original file
    cp "$input_file" "$output_file"
    
    # Calculate strain factor
    local strain_factor=$(echo "1 + $strain_value" | bc -l)
    
    # Apply strain to specific directions
    if [[ "$strain_directions" == *"X"* ]]; then
        # Modify a-axis (line 3, first component)
        local ax=$(sed -n '3p' "$output_file" | awk '{print $1}')
        local new_ax=$(echo "$ax * $strain_factor" | bc -l)
        sed -i "3s/^\s*[0-9.-]*/ ${new_ax}/" "$output_file"
    fi
    
    if [[ "$strain_directions" == *"Y"* ]]; then
        # Modify b-axis (line 4, second component)
        local by=$(sed -n '4p' "$output_file" | awk '{print $2}')
        local new_by=$(echo "$by * $strain_factor" | bc -l)
        sed -i "4s/\(\s*[0-9.-]*\s*\)[0-9.-]*/\1${new_by}/" "$output_file"
    fi
    
    if [[ "$strain_directions" == *"Z"* ]]; then
        # Modify c-axis (line 5, third component)
        local cz=$(sed -n '5p' "$output_file" | awk '{print $3}')
        local new_cz=$(echo "$cz * $strain_factor" | bc -l)
        sed -i "5s/\(\s*[0-9.-]*\s*[0-9.-]*\s*\)[0-9.-]*/\1${new_cz}/" "$output_file"
    fi
}

# Function to apply strain to hexagonal lattice (120°)
apply_hexagonal_strain() {
    local input_file="$1"
    local output_file="$2"
    local strain_directions="$3"
    local strain_value="$4"
    
    # Copy original file
    cp "$input_file" "$output_file"
    
    # Calculate strain factor
    local strain_factor=$(echo "1 + $strain_value" | bc -l)
    
    # For hexagonal lattice with 120° angle:
    # a = (a, 0, 0)
    # b = (-a/2, a*sqrt(3)/2, 0)
    # c = (0, 0, c)
    
    if [[ "$strain_directions" == *"X"* ]] || [[ "$strain_directions" == *"Y"* ]]; then
        # For X or Y strain in hexagonal, both a and b vectors need to be modified
        # to maintain the 120° angle
        
        # Get current values
        local ax=$(sed -n '3p' "$output_file" | awk '{print $1}')
        local bx=$(sed -n '4p' "$output_file" | awk '{print $1}')
        local by=$(sed -n '4p' "$output_file" | awk '{print $2}')
        
        # Apply strain to both vectors
        local new_ax=$(echo "$ax * $strain_factor" | bc -l)
        local new_bx=$(echo "$bx * $strain_factor" | bc -l)
        local new_by=$(echo "$by * $strain_factor" | bc -l)
        
        # Update POSCAR
        sed -i "3s/^\s*[0-9.-]*/ ${new_ax}/" "$output_file"
        sed -i "4s/^\s*[0-9.-]*/ ${new_bx}/" "$output_file"
        sed -i "4s/\(\s*[0-9.-]*\s*\)[0-9.-]*/\1${new_by}/" "$output_file"
        
    elif [[ "$strain_directions" == *"Z"* ]]; then
        # Z strain only affects c-axis
        local cz=$(sed -n '5p' "$output_file" | awk '{print $3}')
        local new_cz=$(echo "$cz * $strain_factor" | bc -l)
        sed -i "5s/\(\s*[0-9.-]*\s*[0-9.-]*\s*\)[0-9.-]*/\1${new_cz}/" "$output_file"
    fi
}

# Function to apply directional strain
apply_directional_strain() {
    local input_file="$1"
    local output_file="$2"
    local strain_directions="$3"
    local strain_value="$4"
    local lattice_type="$5"
    
    if [ "$lattice_type" = "orthogonal_90" ]; then
        apply_orthogonal_strain "$input_file" "$output_file" "$strain_directions" "$strain_value"
    else
        apply_hexagonal_strain "$input_file" "$output_file" "$strain_directions" "$strain_value"
    fi
}

# Function to copy VASP input files
copy_vasp_files() {
    local target_dir="$1"
    local files_copied=0
    
    # Essential VASP files
    local essential_files=("INCAR" "POTCAR" "KPOINTS")
    
    for file in "${essential_files[@]}"; do
        if [ -f "$file" ]; then
            cp "$file" "$target_dir/"
            print_info "  Copied $file"
            ((files_copied++))
        else
            print_warning "  $file not found"
        fi
    done
    
    # Look for run scripts with common names
    local script_names=("vasp_runscript" "run_vasp.sh" "submit.sh" "vasp.sh" "run.sh" "job.sh")
    local script_found=false
    
    for script in "${script_names[@]}"; do
        if [ -f "$script" ]; then
            cp "$script" "$target_dir/"
            print_info "  Copied $script"
            script_found=true
            ((files_copied++))
            break
        fi
    done
    
    if [ "$script_found" = false ]; then
        print_warning "  No run script found (searched for common script names)"
    fi
    
    # Copy workflow generator script if it exists
    if [ -f "vasp_workflow_input_generator.sh" ]; then
        cp "vasp_workflow_input_generator.sh" "$target_dir/"
        print_info "  Copied vasp_workflow_input_generator.sh"
        ((files_copied++))
    else
        print_warning "  vasp_workflow_input_generator.sh not found"
    fi
    
    return 0
}

# Function to run workflow generator automatically
run_workflow_generator() {
    local target_dir="$1"
    local strain_name="$2"
    local user_prefix="$3"
    
    print_info "    Running workflow generator..."
    
    # Change to target directory
    cd "$target_dir" || return 1
    
    # Create input for the workflow generator
    local workflow_prefix="${user_prefix}_${strain_name}"
    
    # Run the workflow generator with automatic inputs
    {
        echo "$workflow_prefix"  # Enter prefix
        echo "y"                 # Choose gamma-only pre-optimization
    } | sh ./vasp_workflow_input_generator.sh > workflow_generator.log 2>&1
    
    # Check if workflow script was generated
    local workflow_script="${workflow_prefix}.sh"
    if [ -f "$workflow_script" ]; then
        print_success "    Workflow script generated: $workflow_script"
        
        # Make it executable
        chmod +x "$workflow_script"
        
        # Run the workflow script in background
        print_info "    Starting workflow execution..."
        nohup ./"$workflow_script" > "${workflow_prefix}.out" 2>&1 &
        local workflow_pid=$!
        print_success "    Workflow started in background (PID: $workflow_pid)"
        
        # Save PID for tracking
        echo "$workflow_pid" > "${workflow_prefix}.pid"
        
    else
        print_error "    Failed to generate workflow script"
        cd ..
        return 1
    fi
    
    # Return to parent directory
    cd ..
    return 0
}

# Function to generate strain values
generate_strain_values() {
    local min_strain="$1"
    local max_strain="$2"
    local step_strain="$3"
    local strain_list=""
    
    # Convert percentages to decimals and generate sequence
    local current=$(echo "scale=6; $min_strain / 100" | bc -l)
    local max_decimal=$(echo "scale=6; $max_strain / 100" | bc -l)
    local step_decimal=$(echo "scale=6; $step_strain / 100" | bc -l)
    
    while (( $(echo "$current <= $max_decimal" | bc -l) )); do
        strain_list="$strain_list $current"
        current=$(echo "scale=6; $current + $step_decimal" | bc -l)
    done
    
    echo "$strain_list"
}

# Function to create folder name from strain value
create_folder_name() {
    local strain_directions="$1"
    local strain_decimal="$2"
    
    # Convert to percentage and format
    local strain_percent=$(echo "scale=2; $strain_decimal * 100" | bc -l)
    
    # Format with proper sign handling
    if (( $(echo "$strain_decimal >= 0" | bc -l) )); then
        # For positive values, add 'p' prefix
        strain_percent=$(printf "%.1f" "$strain_percent")
        local folder_name="strain_${strain_directions}_p${strain_percent}%"
    else
        # For negative values, use 'm' prefix and remove the minus sign
        strain_percent=$(printf "%.1f" "${strain_percent#-}")  # Remove minus sign
        local folder_name="strain_${strain_directions}_m${strain_percent}%"
    fi
    
    echo "$folder_name"
}

# Function to create strain name for workflow prefix
create_strain_name() {
    local strain_decimal="$1"
    
    # Convert to percentage and format
    local strain_percent=$(echo "scale=2; $strain_decimal * 100" | bc -l)
    
    # Format with proper sign handling
    if (( $(echo "$strain_decimal >= 0" | bc -l) )); then
        strain_percent=$(printf "%.1f" "$strain_percent")
        echo "p${strain_percent}"
    else
        strain_percent=$(printf "%.1f" "${strain_percent#-}")
        echo "m${strain_percent}"
    fi
}

#===============================================================================
# Main Script
#===============================================================================

# Print header
echo "=============================================================="
echo "     VASP Strain Calculation Setup Script with Workflow"
echo "=============================================================="

# Check if required files exist
if ! check_file "POSCAR"; then
    exit 1
fi

if ! check_file "vasp_workflow_input_generator.sh"; then
    print_error "vasp_workflow_input_generator.sh not found!"
    print_info "This script is required for automatic workflow setup."
    exit 1
fi

# Detect lattice type
lattice_type=$(detect_lattice_type "POSCAR")

print_info "Lattice analysis:"
echo "  Lattice type: $lattice_type"
if [ "$lattice_type" = "hexagonal_120" ]; then
    print_info "  Detected 120° hexagonal lattice (X/Y strains will maintain angle)"
else
    print_info "  Detected 90° orthogonal lattice (standard strain method)"
fi

# Display strain direction options
echo
print_info "Available strain directions:"
echo "  XYZ - Uniform strain in all directions (recommended for volume changes)"
echo "  X   - Strain only in x-direction"
echo "  Y   - Strain only in y-direction"
echo "  Z   - Strain only in z-direction"
echo "  XY  - Strain in x and y directions"
echo "  XZ  - Strain in x and z directions"
echo "  YZ  - Strain in y and z directions"
if [ "$lattice_type" = "hexagonal_120" ]; then
    print_warning "  Note: For 120° lattice, X and Y strains will both affect the hexagonal plane"
fi
echo

# Get user input for strain directions
while true; do
    read -p "Enter strain directions (e.g., XYZ, X, XY): " strain_directions
    strain_directions=$(echo "$strain_directions" | tr '[:lower:]' '[:upper:]')
    
    if [[ -n "$strain_directions" ]]; then
        break
    else
        print_error "Strain direction cannot be empty!"
    fi
done

# Get strain range parameters
echo
print_info "Strain range setup:"

while true; do
    read -p "Minimum strain (%, e.g., -2 for -2%): " min_strain
    if [[ "$min_strain" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        break
    else
        print_error "Please enter a valid number!"
    fi
done

while true; do
    read -p "Maximum strain (%, e.g., 2 for 2%): " max_strain
    if [[ "$max_strain" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        break
    else
        print_error "Please enter a valid number!"
    fi
done

while true; do
    read -p "Strain step (%, e.g., 0.5 for 0.5%): " step_strain
    if [[ "$step_strain" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$step_strain > 0" | bc -l) )); then
        break
    else
        print_error "Please enter a valid positive number!"
    fi
done

# Option to enable/disable automatic workflow execution
echo
print_info "Workflow automation options:"

# Get user-defined prefix for workflow
workflow_prefix=""
while true; do
    read -p "Enter prefix for workflow scripts (e.g., 'BTO', 'STO', 'PTO'): " workflow_prefix
    if [[ -n "$workflow_prefix" ]]; then
        break
    else
        print_error "Prefix cannot be empty!"
    fi
done

while true; do
    read -p "Auto-run workflow generator and start calculations? (y/N): " auto_workflow
    case "$auto_workflow" in
        [Yy]* ) auto_workflow=true; break;;
        [Nn]* | "" ) auto_workflow=false; break;;
        * ) echo "Please answer y or n.";;
    esac
done

# Generate strain values
print_info "Generating strain values..."
strain_values=$(generate_strain_values "$min_strain" "$max_strain" "$step_strain")
strain_array=($strain_values)

# Display summary
echo
print_info "Summary:"
echo "  Strain directions: $strain_directions"
echo "  Strain range: ${min_strain}% to ${max_strain}% (step: ${step_strain}%)"
echo "  Number of calculations: ${#strain_array[@]}"
echo "  Workflow prefix: $workflow_prefix"
echo "  Auto-run workflows: $auto_workflow"
echo
print_info "Folders to be created:"
for strain in "${strain_array[@]}"; do
    folder_name=$(create_folder_name "$strain_directions" "$strain")
    strain_percent=$(echo "scale=2; $strain * 100" | bc -l)
    printf "  %-30s (strain: %+.2f%%)\n" "$folder_name" "$strain_percent"
done

# Confirmation
echo
while true; do
    read -p "Proceed with folder generation? (y/N): " confirm
    case "$confirm" in
        [Yy]* ) break;;
        [Nn]* | "" ) print_info "Operation cancelled."; exit 0;;
        * ) echo "Please answer y or n.";;
    esac
done

# Start generation process
echo
print_info "Starting folder generation and workflow setup..."
echo "=========================================="

total_folders=${#strain_array[@]}
success_count=0
workflow_success=0

for i in "${!strain_array[@]}"; do
    strain=${strain_array[$i]}
    folder_name=$(create_folder_name "$strain_directions" "$strain")
    strain_name=$(create_strain_name "$strain")
    
    printf "\n%2d/%d. Processing: %s\n" $((i+1)) $total_folders "$folder_name"
    
    # Create directory (remove if exists)
    if [ -d "$folder_name" ]; then
        rm -rf "$folder_name"
        print_warning "    Removed existing folder"
    fi
    
    mkdir -p "$folder_name"
    
    # Generate strained POSCAR
    if [[ "$strain_directions" == "XYZ" ]]; then
        apply_uniform_strain "POSCAR" "$folder_name/POSCAR" "$strain"
        print_info "    Applied uniform strain: $(echo "scale=2; $strain * 100" | bc -l)%"
    else
        apply_directional_strain "POSCAR" "$folder_name/POSCAR" "$strain_directions" "$strain" "$lattice_type"
        if [ "$lattice_type" = "hexagonal_120" ]; then
            print_info "    Applied hexagonal strain ($strain_directions): $(echo "scale=2; $strain * 100" | bc -l)%"
        else
            print_info "    Applied orthogonal strain ($strain_directions): $(echo "scale=2; $strain * 100" | bc -l)%"
        fi
    fi
    
    # Copy other VASP files
    copy_vasp_files "$folder_name"
    ((success_count++))
    
    # Run workflow generator if enabled
    if [ "$auto_workflow" = true ]; then
        if run_workflow_generator "$folder_name" "$strain_name" "$workflow_prefix"; then
            ((workflow_success++))
        fi
    fi
    
    print_success "    Folder setup complete"
done

# Final summary
echo
echo "=========================================="
print_success "All $total_folders folders created successfully!"

if [ "$auto_workflow" = true ]; then
    print_info "Workflow execution summary:"
    echo "  Successfully started workflows: $workflow_success/$total_folders"
    
    if [ $workflow_success -gt 0 ]; then
        echo
        print_info "Monitoring commands:"
        echo "  Check all running jobs: ps aux | grep '${workflow_prefix}_'"
        echo "  Monitor specific job: tail -f strain_*/${workflow_prefix}_*.out"
        echo "  Check job status: ls strain_*/${workflow_prefix}_*.pid"
        echo "  Kill all jobs: pkill -f '${workflow_prefix}_'"
    fi
fi

echo
print_info "Next steps:"
if [ "$auto_workflow" = true ]; then
    echo "  1. Monitor running calculations with: ls strain_*/${workflow_prefix}_*.out"
    echo "  2. Check progress with: tail -f strain_*/${workflow_prefix}_*.out"
    echo "  3. All calculations are running in background"
else
    echo "  1. Enter each folder: cd strain_*/"
    echo "  2. Run workflow generator: sh ./vasp_workflow_input_generator.sh"
    echo "  3. Start calculation: nohup ./${workflow_prefix}_*.sh &"
fi
echo "  4. Use 'ls strain_*/' to check all generated folders"

print_success "Script completed!"

# Save execution summary
cat > strain_setup_summary.txt << EOF
VASP Strain Calculation Setup Summary
====================================
Date: $(date)
Lattice type: $lattice_type
Strain directions: $strain_directions
Strain range: ${min_strain}% to ${max_strain}% (step: ${step_strain}%)
Total folders: $total_folders
Workflow prefix: $workflow_prefix
Auto-workflow: $auto_workflow

Folders created:
EOF

for strain in "${strain_array[@]}"; do
    folder_name=$(create_folder_name "$strain_directions" "$strain")
    strain_percent=$(echo "scale=2; $strain * 100" | bc -l)
    printf "  %-30s (strain: %+.2f%%)\n" "$folder_name" "$strain_percent" >> strain_setup_summary.txt
done

if [ "$auto_workflow" = true ]; then
    echo "" >> strain_setup_summary.txt
    echo "Workflows started: $workflow_success/$total_folders" >> strain_setup_summary.txt
fi

print_info "Setup summary saved to: strain_setup_summary.txt"
