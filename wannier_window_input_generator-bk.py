#!/apps/python3/3.10.0/bin/python3
import subprocess
import os
import argparse
                       
os.chdir(os.getcwd())  

wannier_engwin_path="/home/561/hm1876/vasp_scripts_self_created/wannier_eigwin.py"

# if it is a spin-polarized calculation, the spin state must be specified
parser = argparse.ArgumentParser()
parser.add_argument("-f", "--file", default="wannier90.win", help="Specify the filename of the wannier90 input file.")
parser.add_argument("-s", "--spin_state", choices=["spinup", "spindw"], default="spinup", help="Specify the spin state of the system.")
args = parser.parse_args()

if not args.file:
    print("Error: Please specify the filename of the wannier90 input file using the -f option.")
    parser.print_help()
    exit(1)

if not os.path.isfile(args.file) or os.stat(args.file).st_size == 0:
    print(f"Error: The specified file '{args.file}' does not exist or is empty.")
    exit(1)

# check if it is a spin-polarized calculation
with open("EIGENVAL", "r") as eigenval:
    raw_content = eigenval.readlines() 
content = raw_content[8:9] 

if len(content[0].strip().split()) == 5:
    if not args.spin_state:
        print("Error: Please specify the spin state using the -s option.")
        parser.print_help()
        exit(1)
    else:
        spin_state = args.spin_state

# extract HOMO and LUMO band indices
command = ['python3', str(wannier_engwin_path), 'EIGENVAL', '-e', '1', '-s', args.spin_state]
result = subprocess.run(command, capture_output=True, text=True)
lines = result.stdout.strip().split('\n')
total_band = int(lines[0].split()[2])
homo_index = int(lines[1].split()[2])
lumo_index = int(lines[2].split()[2])
#print(f"Extracted band indices from wannier_engwin.py output:\n"
#      f"Total band: {total_band}\n"
#      f"HOMO index: {homo_index}\n"
#      f"LUMO index: {lumo_index}\n")
print(f"Extracted band indices from wannier_engwin.py output:\n"
      f"Total bands: \033[33m{total_band}\033[0m\n"
      f"HOMO index: \033[33m{homo_index}\033[0m\n"
      f"LUMO index: \033[33m{lumo_index}\033[0m")

print("-----------------------------------------------")
# extract num_wann and calculate wannier function indices
with open(args.file) as f:
    lines = f.readlines()
    num_wann = int([line.split('=')[1].strip() for line in lines if 'num_wann' in line][0])
    # Check if num_wann can be divided by 2
    if num_wann % 2 != 0:
        # Raise an error and terminate the script if num_wann cannot be divided by 2
        raise ValueError("num_wann cannot be divided by 2, program terminated")
    print(f"\033[33mnum_wann\033[0m info:\n"
          f"num_wann: {num_wann}")
homo_wannier_function_index = homo_index - num_wann // 2
lumo_wannier_function_index = lumo_index + num_wann // 2

# calculate energy window for homo wannier function if needed
if homo_wannier_function_index > 0:
    command = ['python3', str(wannier_engwin_path), 'EIGENVAL', '-e', str(homo_wannier_function_index), '-s', args.spin_state]
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stdout.strip().split('\n')
    emin = float(lines[3].split()[2])
    emax = float(lines[4].split()[2])
    dis_froz_min = emax + 0.0005
    print(f"dis_froz_min: {dis_froz_min:.6f}")
else:
    dis_froz_min = None
    print(f"dis_froz_min covers all valence bands")

# calculate energy window for lumo wannier function if needed
if lumo_wannier_function_index <= total_band:
    command = ['python3', str(wannier_engwin_path), 'EIGENVAL', '-e', str(lumo_wannier_function_index), '-s', args.spin_state]
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stdout.strip().split('\n')
    emin = float(lines[3].split()[2])
    emax = float(lines[4].split()[2])
    dis_froz_max = emin - 0.0005
    print(f"dis_froz_max: {dis_froz_max:.6f}")
else:
    dis_froz_max = None
    print(f"dis_froz_max covers all conduction bands")

print("-----------------------------------------------")
# extract num_bands and calculate total band indices
with open(args.file) as f:
    lines = f.readlines()
    num_bands = int([line.split('=')[1].strip() for line in lines if 'num_bands' in line][0])
    # Check if num_wann can be divided by 2
    if num_bands % 2 != 0:
        # Raise an error and terminate the script if num_bands cannot be divided by 2
        raise ValueError("num_bands cannot be divided by 2, program terminated")
    print(f"\033[33mnum_bands\033[0m info:\n"
          f"num_bands: {num_bands}")
homo_bands_index = homo_index - num_bands // 2 + 1
lumo_bands_index = lumo_index + num_bands // 2 - 1

# calculate energy window for homo bands if needed
if homo_bands_index > 1:
    command = ['python3', str(wannier_engwin_path), 'EIGENVAL', '-e', str(homo_bands_index), '-s', args.spin_state]
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stdout.strip().split('\n')
    emin = float(lines[3].split()[2])
    emax = float(lines[4].split()[2])
    dis_win_min = emin - 0.0005
    print(f"dis_win_min: {dis_win_min:.6f}")
else:
    dis_win_min = None
    print(f"dis_win_min covers all valence bands")

# calculate energy window for lumo bands if needed
if lumo_bands_index < total_band:
    command = ['python3', str(wannier_engwin_path), 'EIGENVAL', '-e', str(lumo_bands_index), '-s', args.spin_state]
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stdout.strip().split('\n')
    emin = float(lines[3].split()[2])
    emax = float(lines[4].split()[2])
    dis_win_max = emax + 0.0005
    print(f"dis_win_max: {dis_win_max:.6f}")
else:
    dis_win_max = None
    print(f"dis_win_max covers all conduction bands")
print("-----------------------------------------------")

# Write the variables into the wannier file
with open(args.file, "r") as f:
    content = f.readlines()
    f.close()

# Find the line numbers of variables to be modified
line_nums = {"dis_win_max": None, "dis_win_min": None, "dis_froz_max": None, "dis_froz_min": None}
for i, line in enumerate(content):
    for var_name in line_nums.keys():
        if line.startswith(var_name):
            line_nums[var_name] = i

# Modify the variables that need to be modified
for var_name, var_value in zip(["dis_win_max", "dis_win_min", "dis_froz_max", "dis_froz_min"], [dis_win_max, dis_win_min, dis_froz_max, dis_froz_min]):
    if var_value is not None:
        if line_nums[var_name] is not None:
            content[line_nums[var_name]] = "{} = {:.6f}\n".format(var_name, var_value)
        else:
            # Insert new line before the first variable definition
            insert_index = line_nums[var_name] if line_nums[var_name] is not None else 0
            content.insert(insert_index, "{} = {:.6f}\n".format(var_name, var_value))
            # Update line numbers
            for var_name in line_nums.keys():
                if line_nums[var_name] is not None and line_nums[var_name] >= insert_index:
                    line_nums[var_name] += 1
    else:
        # Delete the variable definition if the variable is not needed
        if line_nums[var_name] is not None:
            del content[line_nums[var_name]]
            # Update line numbers
            for var in line_nums.keys():
                if line_nums[var] is not None and line_nums[var] >= line_nums[var_name]:
                    line_nums[var] -= 1


with open(args.file, "w") as f:
    f.writelines(content)
    f.close()
