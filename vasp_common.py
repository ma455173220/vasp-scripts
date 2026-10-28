#!/usr/bin/env python3
"""
vasp_common.py - shared helpers for the vasp-scripts Python tools (numpy; ASE optional).

Import from a script (works when the script is copied elsewhere, as long as the
repo is on PATH):

    import os, shutil, sys
    _w = shutil.which("vasp_common.py")
    for _d in [os.path.dirname(os.path.realpath(__file__))] + ([os.path.dirname(os.path.realpath(_w))] if _w else []):
        if os.path.isfile(os.path.join(_d, "vasp_common.py")):
            sys.path.insert(0, _d)
            break
    else:
        sys.exit("ERROR: vasp_common.py not found (next to this script or on PATH)")
    from vasp_common import read_poscar

Contents
    read_poscar(path)               POSCAR/CONTCAR (VASP 4/5/6, "Ti_pv/<hash>" species,
                                    selective dynamics, negative scale, Cartesian)
    write_poscar(path, ...)         Direct-coordinate POSCAR, species grouped (sort=True)
    group_order(symbols)            indices grouping equal species, first-appearance order
    strip_species(token)            "Ti_pv/abc" -> "Ti"
    mic_dists(frac, i, lattice)     minimum-image distances atom i -> i+1.. (27 images)
    neighbor_pairs(frac, lattice, cutoff)   all pairs i<j closer than cutoff
    periodic_com(frac, masses)      centre of mass, safe for slabs crossing the cell boundary
    read_incar(path)                {TAG: value} of the active tags
    outcar_tail(path, nbytes)       last bytes of an OUTCAR as text
    outcar_contains(path, text)     tail first, then a streamed scan (no full read)
    outcar_natoms(path)             NIONS
    oszicar_last(path)              last ionic line: {"E0", "F", "mag", "line"}
    job_status(dir, final=True)     ("converged"|"unconverged"|"running"|"failed", reason),
                                    same table as VASP_JOB_PARAMETERS / vasp_common.sh
    read_atoms(path)                ase.io.read, falling back to read_poscar for POSCARs
                                    an old ASE cannot parse (e.g. VASP 6.4 species)
"""
import os
import re
import time
from itertools import product

import numpy as np

SHIFTS = np.array(list(product((-1, 0, 1), repeat=3)), dtype=float)


# ---------------------------------------------------------------------------
# POSCAR
# ---------------------------------------------------------------------------
def strip_species(token):
    """POTCAR-style species token -> element symbol ("Ti_pv/abc123" -> "Ti")."""
    return token.split("/")[0].split("_")[0]


class Poscar:
    """Parsed POSCAR. lattice: rows in Angstrom (scale applied); frac: fractional
    coordinates as written (not wrapped); selective: (N, 3) bool, True = free, or None;
    species / symbols are None for a VASP4 file without a species line."""

    def __init__(self, comment, scale, lattice, species, species_raw, counts,
                 frac, selective, cartesian_input):
        self.comment = comment
        self.scale = scale
        self.lattice = lattice
        self.species = species
        self.species_raw = species_raw
        self.counts = counts
        self.frac = frac
        self.selective = selective
        self.cartesian_input = cartesian_input

    @property
    def natoms(self):
        return int(sum(self.counts))

    @property
    def symbols(self):
        if self.species is None:
            return None
        return [s for s, n in zip(self.species, self.counts) for _ in range(n)]

    @property
    def cart(self):
        return self.frac @ self.lattice


def read_poscar(path):
    with open(path) as f:
        lines = f.read().splitlines()
    scale = float(lines[1].split()[0])
    lattice = np.array([[float(x) for x in lines[i].split()[:3]] for i in (2, 3, 4)])
    if scale < 0:  # negative scale = target volume
        factor = float(np.cbrt(-scale / np.linalg.det(lattice)))
    else:
        factor = scale
    lattice = lattice * factor
    tokens = lines[5].split()
    try:  # VASP4: no species line, line 6 holds the counts
        float(tokens[0])
        species = species_raw = None
        counts = [int(x) for x in tokens]
        k = 6
    except ValueError:
        species_raw = tokens
        species = [strip_species(t) for t in tokens]
        counts = [int(x) for x in lines[6].split()[:len(tokens)]]
        k = 7
    selective = None
    has_sd = lines[k].strip()[:1] in ("s", "S")
    if has_sd:
        k += 1
    cartesian = lines[k].strip()[:1] in ("c", "C", "k", "K")
    nat = sum(counts)
    rows = [lines[k + 1 + i].split() for i in range(nat)]
    pos = np.array([[float(x) for x in r[:3]] for r in rows])
    if has_sd:
        selective = np.array([[f.upper().startswith("T") for f in r[3:6]] for r in rows], dtype=bool)
    if cartesian:
        frac = (pos * factor) @ np.linalg.inv(lattice)
    else:
        frac = pos
    p = Poscar(lines[0], scale, lattice, species, species_raw, counts,
               frac, selective, cartesian)
    p.cart_input = pos * factor if cartesian else None   # exact Cartesian values as written
    return p


def group_order(symbols):
    """Indices that group equal species together, species in first-appearance order."""
    seen = []
    for s in symbols:
        if s not in seen:
            seen.append(s)
    return sorted(range(len(symbols)), key=lambda i: seen.index(symbols[i]))


def write_poscar(path, lattice, symbols, frac, comment="", selective=None, sort=True):
    """Write a Direct-coordinate VASP5 POSCAR (scale 1.0)."""
    symbols = list(symbols)
    frac = np.asarray(frac, dtype=float)
    idx = group_order(symbols) if sort else list(range(len(symbols)))
    symbols = [symbols[i] for i in idx]
    frac = frac[idx]
    if selective is not None:
        selective = np.asarray(selective)[idx]
    species, counts = [], []
    for s in symbols:
        if species and species[-1] == s:
            counts[-1] += 1
        else:
            species.append(s)
            counts.append(1)
    out = [comment or " ".join(species), "   1.0"]
    out += ["  %20.12f %20.12f %20.12f" % tuple(v) for v in np.asarray(lattice, dtype=float)]
    out.append("   " + "  ".join(species))
    out.append("   " + "  ".join(str(c) for c in counts))
    if selective is not None:
        out.append("Selective dynamics")
    out.append("Direct")
    for i, r in enumerate(frac):
        line = "  %18.12f %18.12f %18.12f" % tuple(r)
        if selective is not None:
            line += " " + " ".join("T" if f else "F" for f in selective[i])
        out.append(line)
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def mic_dists(frac, i, lattice):
    """True minimum-image distances from atom i to atoms i+1..N-1 (fractional input).
    Differences are reduced to [-0.5, 0.5) and the shortest of the 27 neighbouring
    images is taken, which is also correct for oblique (hexagonal, monoclinic) cells."""
    diff = frac[i + 1:] - frac[i]
    diff -= np.round(diff)
    cart = (diff[:, None, :] + SHIFTS[None, :, :]) @ lattice   # (n, 27, 3)
    return np.sqrt((cart ** 2).sum(axis=-1)).min(axis=1)


def neighbor_pairs(frac, lattice, cutoff):
    """[(i, j, d)] for all pairs i < j with minimum-image distance d < cutoff."""
    frac = np.asarray(frac, dtype=float)
    pairs = []
    for i in range(len(frac) - 1):
        d = mic_dists(frac, i, lattice)
        for k in np.nonzero(d < cutoff)[0]:
            pairs.append((i, i + 1 + int(k), float(d[k])))
    return pairs


def periodic_com(frac, masses):
    """Centre of mass in fractional coordinates, safe across the cell boundary.

    Per axis the atoms are unwrapped by cutting at the middle of the largest empty
    interval (for a slab: the vacuum gap), the mass-weighted mean is taken and wrapped
    to [0, 1). On a tie the cell boundary is kept, which gives the plain mean for
    anything that does not cross the boundary."""
    frac = np.asarray(frac, dtype=float)
    masses = np.asarray(masses, dtype=float)
    com = np.zeros(3)
    for ax in range(3):
        s = np.sort(frac[:, ax] % 1.0)
        gaps = np.diff(np.append(s, s[0] + 1.0))  # last entry: gap across the boundary
        i = int(np.argmax(gaps))
        if gaps[-1] >= gaps[i] - 1e-6:            # tie: keep the cell boundary (= plain mean)
            i = len(gaps) - 1
        cut = (s[i] + gaps[i] / 2.0) % 1.0        # middle of the largest empty interval
        unwrapped = (frac[:, ax] - cut) % 1.0 + cut
        com[ax] = (np.sum(masses * unwrapped) / np.sum(masses)) % 1.0
    return com


# ---------------------------------------------------------------------------
# INCAR / OUTCAR / OSZICAR
# ---------------------------------------------------------------------------
def read_incar(path):
    """Active tags of an INCAR as {TAG: value}; first occurrence wins, '#'/'!' comments
    and ';'-separated tags handled, multi-line "..." strings skipped."""
    tags = {}
    in_quote = False
    with open(path, errors="replace") as f:
        for line in f:
            if in_quote:
                if line.count('"') % 2:
                    in_quote = False
                continue
            code = re.split(r"[#!]", line, maxsplit=1)[0]
            if code.count('"') % 2:
                in_quote = True
            for part in code.split(";"):
                if "=" in part:
                    key, val = part.split("=", 1)
                    key = key.strip().upper()
                    if key and key not in tags:
                        tags[key] = val.strip()
    return tags


def outcar_tail(path, nbytes=2_000_000):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - nbytes))
        return f.read().decode(errors="replace")


def outcar_contains(path, text, nbytes=2_000_000):
    """True if text occurs in the file: the tail is checked first, then the whole
    file is streamed line by line (never read into memory at once)."""
    if text in outcar_tail(path, nbytes):
        return True
    if os.path.getsize(path) <= nbytes:
        return False
    with open(path, errors="replace") as f:
        return any(text in line for line in f)


def outcar_natoms(path):
    with open(path, errors="replace") as f:
        for line in f:
            if "NIONS" in line:
                m = re.search(r"NIONS\s*=\s*(\d+)", line)
                if m:
                    return int(m.group(1))
    return None


def oszicar_last(path):
    """Last line with E0= of an OSZICAR: {"E0", "F", "mag", "line"} (missing -> None)."""
    last = None
    with open(path, errors="replace") as f:
        for line in f:
            if "E0=" in line:
                last = line
    if last is None:
        return None

    def num(key):
        m = re.search(key + r"=\s*([-\d.E+]+)", last)
        return float(m.group(1)) if m else None

    return {"E0": num("E0"), "F": num("F"), "mag": num("mag"), "line": last.rstrip("\n")}


def job_status(dirpath, final=True, running_minutes=60):
    """(status, reason) of the VASP run in dirpath; same table as vasp_common.sh:
      NSW missing or <= 0                        -> static: "EDIFF is reached"
      IBRION 1/2/3/44                            -> also "reached required accuracy"
      IBRION 0/5/6/7/8, none with NSW > 0, other -> "EDIFF is reached"
    final=False: an incomplete OUTCAR written to recently counts as "running"."""
    outcar = os.path.join(dirpath, "OUTCAR")
    if not os.path.isfile(outcar):
        return "failed", "OUTCAR not found"
    if "Total CPU time used" not in outcar_tail(outcar, 200_000):
        if not final and time.time() - os.path.getmtime(outcar) < running_minutes * 60:
            return "running", "OUTCAR updated in the last %d min" % running_minutes
        return "failed", "Job did not complete normally"
    incar = os.path.join(dirpath, "INCAR")
    tags = read_incar(incar) if os.path.isfile(incar) else {}
    nsw = tags.get("NSW", "").split()[:1]
    ibrion = tags.get("IBRION", "").split()[:1]
    nsw = nsw[0] if nsw else ""
    ibrion = ibrion[0] if ibrion else ""
    ediff = outcar_contains(outcar, "EDIFF is reached")
    if nsw == "" or (re.fullmatch(r"-?\d+", nsw) and int(nsw) <= 0):
        return ("converged", "static run") if ediff else ("unconverged", "SCF did not converge")
    if ibrion in ("1", "2", "3", "44"):
        if ediff and outcar_contains(outcar, "reached required accuracy"):
            return "converged", "optimisation (IBRION=%s)" % ibrion
        return "unconverged", "Optimization did not converge"
    if ediff:
        return "converged", "IBRION=%s NSW=%s" % (ibrion or "default", nsw)
    return "unconverged", "IBRION=%s (NSW=%s) did not meet criteria" % (ibrion or "default", nsw)


# ---------------------------------------------------------------------------
# ASE bridge
# ---------------------------------------------------------------------------
def poscar_to_atoms(p):
    """ASE Atoms from a Poscar, with the same constraints ASE's own reader sets."""
    from ase import Atoms
    from ase.constraints import FixAtoms, FixScaled
    if p.cartesian_input:
        atoms = Atoms(p.symbols, cell=p.lattice, positions=p.cart_input, pbc=True)
    else:
        atoms = Atoms(p.symbols, cell=p.lattice, scaled_positions=p.frac, pbc=True)
    if p.selective is not None:
        fixed = ~p.selective
        constraints, indices = [], []
        for ind, sflags in enumerate(fixed):
            if sflags.any() and not sflags.all():
                constraints.append(FixScaled(ind, sflags, atoms.get_cell()))
            elif sflags.all():
                indices.append(ind)
        if indices:
            constraints.append(FixAtoms(indices))
        if constraints:
            atoms.set_constraint(constraints)
    return atoms


def read_atoms(path, **kwargs):
    """ase.io.read(path); if that fails on a POSCAR-like file (e.g. VASP 6.4 species
    "Ti_pv/<hash>" with ASE < 3.24), parse it with read_poscar instead."""
    from ase.io import read
    try:
        return read(path, **kwargs)
    except Exception as err:
        try:
            p = read_poscar(path)
        except Exception:
            raise err
        if p.species is None:
            raise err
        return poscar_to_atoms(p)
