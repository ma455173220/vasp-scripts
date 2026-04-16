#!/bin/bash
# wt-input-generator.sh
#
# Generates wanniertools/wt.in from an embedded template, filling in
# lattice vectors and atom positions from wannier90.wout, and Fermi
# energy from vasprun.xml (preferred) or OUTCAR.
#
# Usage (run from the calculation directory containing wannier90.wout):
#   bash wt-input-generator.sh [-i template.in] [--no-z2] [--soc 0]
#
# Options:
#   -i FILE     Use FILE as wt.in template instead of the embedded default
#   --no-z2     Set Z2_3D_calc = F  (default: T)
#   --soc N     Set SOC = N         (default: 1)

set -euo pipefail

TARGET_FOLDER="wanniertools"
TARGET_HR="wannier90_hr.dat"
TARGET_RUNSCRIPT="$HOME/wanniertools_runscript"
TEMPLATE_IN="template.in"   # default; overridden by -i

# --------------------------------------------------------------------------
# Parse flags
# --------------------------------------------------------------------------
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)
            if [[ -z "${2-}" ]]; then
                echo "Error: -i requires a file argument" >&2; exit 1
            fi
            TEMPLATE_IN="$2"; shift 2 ;;
        -i*)
            TEMPLATE_IN="${1#-i}"; shift ;;
        *)
            EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# --------------------------------------------------------------------------
# Sanity check
# --------------------------------------------------------------------------
if [ ! -f "wannier90.wout" ]; then
    echo "Error: wannier90.wout not found in $(pwd)" >&2
    exit 1
fi

if [[ "$TEMPLATE_IN" != "template.in" ]] && [ ! -f "$TEMPLATE_IN" ]; then
    echo "Error: template file '$TEMPLATE_IN' not found" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Create target folder and symlink HR file
# --------------------------------------------------------------------------
mkdir -p "$TARGET_FOLDER"

if [ -f "$TARGET_HR" ]; then
    ln -sf "../$TARGET_HR" "$TARGET_FOLDER/$TARGET_HR"
    echo "Symlinked $TARGET_HR -> $TARGET_FOLDER/"
else
    echo "Warning: $TARGET_HR not found – symlink skipped." >&2
fi

# --------------------------------------------------------------------------
# Copy run script if available
# --------------------------------------------------------------------------
if [ -f "$TARGET_RUNSCRIPT" ]; then
    cp "$TARGET_RUNSCRIPT" "$TARGET_FOLDER/"
    echo "Copied run script -> $TARGET_FOLDER/"
fi

# --------------------------------------------------------------------------
# Generate wt.in via embedded Python (written to a temp file then executed)
# --------------------------------------------------------------------------
_PY=$(mktemp /tmp/wt_gen_XXXXXX.py)
trap 'rm -f "$_PY"' EXIT

cat > "$_PY" << 'PYEOF'
import re
import sys
from pathlib import Path

TEMPLATE = """\
&TB_FILE
Hrfile = 'wannier90_hr.dat'
Package = 'QE'
/


&CONTROL
!-------- topology --------
Z2_3D_calc            = T    ! Z2 topological invariant (3D)
!-------- bulk --------
BulkBand_calc         = F    ! bulk band structure
BulkFS_calc           = F    ! bulk Fermi surface
BulkGap_cube_calc     = F    ! bulk gap in 3D k-cube
BulkGap_plane_calc    = F    ! bulk gap on a k-plane
!-------- surface / slab --------
SlabBand_calc         = F    ! slab band structure
SlabSS_calc           = F    ! surface states
SlabArc_calc          = F    ! Fermi arc
SlabSpintexture_calc  = F    ! spin texture
WireBand_calc         = F    ! wire band structure
!-------- response --------
AHC_calc              = F    ! anomalous Hall conductivity
BerryPhase_calc       = F    ! Berry phase
BerryCurvature_calc   = F    ! Berry curvature
wanniercenter_calc    = F    ! Wannier charge centres
/

&SYSTEM
! NSLAB        = 10          ! number of layers for slab calculation
! NumOccupied  = 20          ! number of occupied bands (needed for Z2, AHC ...)
SOC            = 1           ! 1 = SOC included, 0 = no SOC
E_FERMI        = <<<E_FERMI>>>
! Bx= 0, By= 0, Bz= 0       ! external magnetic field (Tesla)
! surf_onsite  = 0.0         ! onsite energy shift for surface layer
/

&PARAMETERS
Eta_Arc        = 0.01        ! broadening for spectral function (eV)
! E_arc        = 0.00        ! energy for Fermi arc (eV, relative to E_FERMI)
OmegaNum       = 251         ! number of energy points for DOS / optics
OmegaMin       = -2.0        ! energy window minimum (eV)
OmegaMax       =  0.5        ! energy window maximum (eV)
Nk1            = 101         ! k-mesh along b1 (bulk / Z2 cube)
Nk2            = 101         ! k-mesh along b2
Nk3            = 101         ! k-mesh along b3
! NP           = 4           ! number of principal layers for surface Green's function
! Gap_threshold = 0.002      ! threshold for BulkGap output (eV)
/

LATTICE
Angstrom
<<<LATTICE>>>

ATOM_POSITIONS
<<<N_ATOMS>>>
Direct
<<<ATOM_COORDS>>>

<<<PROJECTORS>>>

! SURFACE            ! Miller indices defining the surface (default: 001)
!  1  0  0
!  0  1  0
!  0  0  1

! KPATH_BULK         ! high-symmetry k-path for bulk band structure
! 4                  ! number of line segments
! G   0.00000  0.00000  0.00000   T   0.50000  0.50000  0.50000
! T   0.50000  0.50000  0.50000   F   0.50000  0.00000  0.50000
! F   0.50000  0.00000  0.50000   G   0.00000  0.00000  0.00000
! G   0.00000  0.00000  0.00000   L   0.50000  0.00000  0.00000

! KPATH_SLAB         ! k-path for slab band / surface-state calculation
! 2                  ! number of line segments
! K  -0.5  0.0   G   0.0  0.0
! G   0.0  0.0   K   0.5  0.0

! KPLANE_SLAB        ! 2D k-plane for Fermi arc / spin-texture plots
! -0.5 -0.5          ! origin (2D reduced coordinates)
!  1.0  0.0          ! first spanning vector
!  0.0  1.0          ! second spanning vector

! KPLANE_BULK        ! k-plane for bulk Berry curvature / gap plane
! -0.50 -0.50  0.00  ! origin
!  1.00  0.00  0.00  ! first spanning vector
!  0.00  1.00  0.00  ! second spanning vector

KCUBE_BULK           ! k-cube for Z2_3D_calc and BulkGap_cube_calc
-0.5  -0.5  -0.5     ! origin (covers the full BZ)
 1.0   0.0   0.0     ! first spanning vector
 0.0   1.0   0.0     ! second spanning vector
 0.0   0.0   1.0     ! third spanning vector

! WANNIER_CENTRES    ! paste Wannier centres from wannier90.wout if needed
! Cartesian
!   x1  y1  z1
"""


def read_lattice(wout_path):
    vectors = []
    for line in wout_path.read_text().splitlines():
        m = re.match(r'\s+a_\d\s+([\-\d.]+)\s+([\-\d.]+)\s+([\-\d.]+)', line)
        if m:
            vectors.append(f"  {m.group(1)}  {m.group(2)}  {m.group(3)}")
        if len(vectors) == 3:
            break
    if len(vectors) != 3:
        raise RuntimeError(f"Could not parse 3 lattice vectors from {wout_path}")
    return vectors


def read_atoms(wout_path):
    atoms = []
    in_table = False
    for line in wout_path.read_text().splitlines():
        if "Fractional Coordinate" in line:
            in_table = True
            continue
        if in_table:
            m = re.match(
                r'\s*\|\s*([A-Za-z]+)\s+\d+\s+'
                r'([\-\d.]+)\s+([\-\d.]+)\s+([\-\d.]+)',
                line
            )
            if m:
                atoms.append(
                    f"{m.group(1)}  {m.group(2)}  {m.group(3)}  {m.group(4)}"
                )
            elif atoms and re.match(r'\s*\*[-*]+\*', line):
                break
    if not atoms:
        raise RuntimeError(f"Could not parse atom positions from {wout_path}")
    return len(atoms), atoms


def read_fermi(outcar_path):
    """Try vasprun.xml first (same dir as OUTCAR), then fall back to OUTCAR."""
    xml_path = outcar_path.parent / 'vasprun.xml'
    if xml_path.exists():
        # Match lowercase 'efermi' only – 'EFERMI' in vasprun.xml is a
        # different tag (initial guess) and is typically 0.0.
        m = re.search(r'<i\s+name="efermi"\s*>\s*([\-\d.]+)',
                      xml_path.read_text())
        if m:
            print(f"  Fermi energy    : {m.group(1)} eV  (from {xml_path})")
            return m.group(1)

    if outcar_path.exists():
        m = re.search(r'^[ \t]*E-fermi\s*:\s*([\-\d.]+)',
                      outcar_path.read_text(), re.MULTILINE)
        if m:
            print(f"  Fermi energy    : {m.group(1)} eV  (from {outcar_path})")
            return m.group(1)

    return None


# Orbital expansion table (order matches Wannier90 convention, per the screenshot)
ORBITAL_EXPAND = {
    's':  ['s'],
    'p':  ['pz', 'px', 'py'],
    'd':  ['dz2', 'dxz', 'dyz', 'dx2-y2', 'dxy'],
    'f':  ['fz3', 'fxz2', 'fyz2', 'fz(x2-y2)', 'fxyz', 'fx(x2-3y2)', 'fy(3x2-y2)'],
    # explicit single orbitals pass through unchanged
    'pz': ['pz'], 'px': ['px'], 'py': ['py'],
    'dz2': ['dz2'], 'dxz': ['dxz'], 'dyz': ['dyz'],
    'dx2-y2': ['dx2-y2'], 'dxy': ['dxy'],
    'fz3': ['fz3'], 'fxz2': ['fxz2'], 'fyz2': ['fyz2'],
    'fz(x2-y2)': ['fz(x2-y2)'], 'fxyz': ['fxyz'],
    'fx(x2-3y2)': ['fx(x2-3y2)'], 'fy(3x2-y2)': ['fy(3x2-y2)'],
    # l= syntax
    'l=0': ['s'],
    'l=1': ['pz', 'px', 'py'],
    'l=2': ['dz2', 'dxz', 'dyz', 'dx2-y2', 'dxy'],
    'l=3': ['fz3', 'fxz2', 'fyz2', 'fz(x2-y2)', 'fxyz', 'fx(x2-3y2)', 'fy(3x2-y2)'],
}


def expand_orbitals(spec):
    """
    Expand a single orbital specifier to a list of orbital names.
    e.g. 'p' -> ['pz','px','py'],  's' -> ['s'],  'l=2' -> ['dz2',...]
    Unknown specifiers are passed through as-is with a warning.
    """
    key = spec.strip().lower()
    if key in ORBITAL_EXPAND:
        return ORBITAL_EXPAND[key]
    print(f"  Warning: unknown orbital specifier '{spec}', keeping as-is.")
    return [spec.strip()]


def read_projectors(win_path, atom_list):
    """
    Parse the 'begin projections … end projections' block from wannier90.win
    and return a formatted PROJECTORS block string for wt.in.

    win format examples:
        Bi : s;p
        Se : s;p
        f=0.5,0.5,0.5 : d        (site-specific – element ignored, uses wout order)

    atom_list: list of element strings in the same order as ATOM_POSITIONS
               e.g. ['Se','Se','Se','Bi','Bi']

    Returns the full PROJECTORS block as a string, or None if not parseable.
    """
    if not win_path.exists():
        return None

    # Extract projections block
    text = win_path.read_text()
    m = re.search(r'begin\s+projections\s*\n(.*?)\nend\s+projections',
                  text, re.IGNORECASE | re.DOTALL)
    if not m:
        return None

    block = m.group(1)

    # Parse each line: "Element : orb1;orb2;..."
    # Also handle "Element : l=N" syntax
    proj_per_element = {}   # element -> [orbital, orbital, ...]
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('!'):
            continue
        # Split on ':' to get site spec and orbital spec
        if ':' not in line:
            continue
        site_part, orb_part = line.split(':', 1)
        site_part = site_part.strip()
        orb_part  = orb_part.strip()

        # Determine element – skip coordinate-based site specs (contain digits/commas)
        # e.g. "f=0.5,0.5,0.5" → skip (can't map to wout atom order easily)
        if re.search(r'[\d,=]', site_part):
            print(f"  Warning: site-specific projection '{line}' skipped "
                  f"(coordinate-based sites not supported – edit PROJECTORS manually).")
            continue
        element = site_part.split()[0]  # take first token, ignore c= options

        # Expand orbital specifiers (split on ';')
        orbitals = []
        for spec in orb_part.split(';'):
            orbitals.extend(expand_orbitals(spec.strip()))

        proj_per_element[element] = orbitals

    if not proj_per_element:
        return None

    # Build per-atom orbital lists following the order of atom_list (from wout)
    per_atom = []
    for el in atom_list:
        if el not in proj_per_element:
            print(f"  Warning: element '{el}' in ATOM_POSITIONS has no projection "
                  f"in wannier90.win – PROJECTORS block may be incomplete.")
            per_atom.append((el, []))
        else:
            per_atom.append((el, proj_per_element[el]))

    # Format the PROJECTORS block
    num_orbs_per_atom = [len(orbs) for _, orbs in per_atom]
    lines = ['PROJECTORS']
    lines.append('  ' + '  '.join(str(n) for n in num_orbs_per_atom)
                 + '   ! orbitals per site')
    for el, orbs in per_atom:
        if orbs:
            lines.append(f'{el}  ' + '  '.join(orbs))
        else:
            lines.append(f'! {el}  <-- no projection found, fill manually')

    return '\n'.join(lines)


# =============================================================================
# Section-based replacement (for custom templates without placeholders)
# Each function finds the relevant section by its keyword and replaces the
# data lines that follow it, stopping at the next blank line.
# =============================================================================

def _replace_section_data(content, anchor, new_data_lines, stop_keywords=()):
    """
    Find the line matching `anchor` (stripped), then replace all non-blank
    lines that follow it (up to the first blank line or a stop_keyword line)
    with new_data_lines.
    """
    lines = content.splitlines(keepends=True)
    out = []
    i = 0
    while i < len(lines):
        out.append(lines[i])
        if lines[i].strip() == anchor:
            i += 1
            # skip old data lines
            while i < len(lines):
                s = lines[i].strip()
                if s == '' or any(s.startswith(kw) for kw in stop_keywords):
                    break
                i += 1
            # insert new data
            for dl in new_data_lines:
                out.append(dl + '\n')
            continue
        i += 1
    return ''.join(out)


def replace_lattice(content, vectors):
    """Replace the 3 lines after 'Angstrom'."""
    return _replace_section_data(content, 'Angstrom', vectors)


def replace_atom_positions(content, n_atoms, atoms):
    """
    Replace everything after 'ATOM_POSITIONS' up to the next blank line.
    The block is: <n_atoms>\nDirect\n<atom lines...>
    """
    new_lines = [str(n_atoms), 'Direct'] + atoms
    return _replace_section_data(content, 'ATOM_POSITIONS', new_lines)


def replace_fermi(content, e_fermi):
    """Replace E_FERMI = <anything> with the new value."""
    return re.sub(r'(E_FERMI\s*=\s*).*', rf'\g<1>{e_fermi}', content)


def replace_projectors(content, projectors_block):
    """
    Replace the PROJECTORS block (from the PROJECTORS line up to the next
    blank line) with the new block.  If no PROJECTORS line exists, do nothing.
    """
    if 'PROJECTORS' not in content:
        return content
    # projectors_block already starts with 'PROJECTORS\n...'
    # so we replace from the PROJECTORS line to the next blank line
    new_lines = projectors_block.splitlines()[1:]  # skip the leading 'PROJECTORS' line
    return _replace_section_data(
        content, 'PROJECTORS', new_lines,
        stop_keywords=['!', 'SURFACE', 'KPATH', 'KPLANE', 'KCUBE', 'WANNIER']
    )


def main():
    wtin_path     = Path(sys.argv[1])
    wout_path     = Path(sys.argv[2])
    outcar_path   = Path(sys.argv[3])
    template_path = Path(sys.argv[4])
    extra         = sys.argv[5:]

    z2  = '--no-z2' not in extra
    soc = 1
    if '--soc' in extra:
        soc = int(extra[extra.index('--soc') + 1])

    # Load template: prefer template.in in the calc dir, fall back to embedded
    if template_path.exists():
        content = template_path.read_text()
        print(f'Using template    : {template_path}')
    else:
        content = TEMPLATE
        print('Using template    : <embedded default>')

    # wannier90.win is expected alongside wannier90.wout
    win_path = wout_path.with_suffix('.win')

    print(f"Reading {wout_path} ...")
    vectors        = read_lattice(wout_path)
    n_atoms, atoms = read_atoms(wout_path)
    atom_elements  = [a.split()[0] for a in atoms]
    print(f"  Lattice vectors : 3 found")
    print(f"  Atoms           : {n_atoms}  ({', '.join(atom_elements)})")

    e_fermi = read_fermi(outcar_path)
    if not e_fermi:
        e_fermi = "0.0000   ! <-- SET THIS MANUALLY"
        print("  Warning: vasprun.xml / OUTCAR not found or Fermi energy not parseable.")
        print("           E_FERMI left as placeholder – please update manually.")

    print(f"Reading {win_path} ...")
    projectors_block = read_projectors(win_path, atom_elements)
    if projectors_block:
        print(f"  Projectors      : parsed OK")
    else:
        projectors_block = (
            "! PROJECTORS\n"
            "! Could not parse from wannier90.win – fill in manually.\n"
            "! Format:\n"
            "!   <num_orbitals per site, space-separated>\n"
            "!   <element>  <orbital> [<orbital> ...]"
        )
        print(f"  Warning: could not parse projectors from {win_path} – "
              f"left as comment placeholder.")

    # Apply parsed data to the template.
    # Two strategies:
    #   1. Placeholder substitution  – works when <<<...>>> markers are present
    #      (always true for the embedded default template)
    #   2. Section-based replacement – used as fallback when a custom template
    #      has no placeholders (i.e. the user supplied a real wt.in)
    use_placeholders = '<<<LATTICE>>>' in content

    if use_placeholders:
        content = content.replace('<<<LATTICE>>>',     '\n'.join(vectors))
        content = content.replace('<<<N_ATOMS>>>',     str(n_atoms))
        content = content.replace('<<<ATOM_COORDS>>>', '\n'.join(atoms))
        content = content.replace('<<<E_FERMI>>>',     e_fermi)
        content = content.replace('<<<PROJECTORS>>>', projectors_block)
    else:
        content = replace_lattice(content, vectors)
        content = replace_atom_positions(content, n_atoms, atoms)
        content = replace_fermi(content, e_fermi)
        content = replace_projectors(content, projectors_block)

    if not z2:
        content = content.replace('Z2_3D_calc            = T',
                                  'Z2_3D_calc            = F')
    if soc != 1:
        content = re.sub(r'(SOC\s*=\s*)\d', rf'\g<1>{soc}', content)

    wtin_path.parent.mkdir(parents=True, exist_ok=True)
    wtin_path.write_text(content)
    print(f"\nWritten : {wtin_path}")
    print("Next    : review NumOccupied and k-path before running WannierTools.")


main()
PYEOF

python3 "$_PY" "$TARGET_FOLDER/wt.in" "wannier90.wout" "OUTCAR" "$TEMPLATE_IN" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
