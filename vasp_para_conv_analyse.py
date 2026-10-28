#!/usr/bin/env python3
"""
vasp_para_conv_analyse.py - summarise a vasp_para_conv.sh parameter scan.

Usage:
  vasp_para_conv_analyse.py                     # folders with generation_info.txt here
  vasp_para_conv_analyse.py -p ENCUT            # only the ENCUT scan (or ENCUT_* folders)
  vasp_para_conv_analyse.py -p ENCUT -t 0.5 -r 600 --plot encut.png
  vasp_para_conv_analyse.py DIR1 DIR2 ...       # explicit folders, in this order

Folders: generation_info.txt written by vasp_para_conv.sh (parameter, value, generation
order); without it, PARAM_* folders. Numeric values are sorted numerically ("none" =
tag commented out comes first); anything else (MAGMOM strings ...) keeps the
generation order.

Columns per folder (OUTCAR is only read from its end / streamed, never loaded whole):
  status       converged / unconverged / running / failed (same rules as VASP_JOB_PARAMETERS)
  E0           last E0 in OSZICAR (eV);  E/atom (eV)
  dE_prev      E/atom difference to the previous row (meV/atom)
  dE_ref       E/atom difference to the reference row (meV/atom); reference = last row
               (the most accurate setting) or -r VALUE
  Fmax         largest force on free atoms in the last step (eV/A; selective dynamics
               from POSCAR/CONTCAR honoured)
  P            external pressure of the last step (kB) - converge it too for ENCUT
  mag          total magnetisation (OSZICAR)
  NELM         ionic steps whose SCF hit NELM (not converged electronically)
  time         elapsed time (s);  NKPTS  irreducible k-points

Verdict ("converged at"): for numeric scans without "none", the first value from which every later
converged row stays within the threshold (-t, default 1 meV/atom) of the reference;
the lowest-energy setting is always reported (useful for NUPDOWN / MAGMOM scans).
Also written: CSV (default para_conv_<PARAM>.csv, --csv), optional --plot PNG.
"""
import argparse
import csv
import glob
import os
import shutil
import sys

_w = shutil.which("vasp_common.py")
for _d in [os.path.dirname(os.path.realpath(__file__))] + ([os.path.dirname(os.path.realpath(_w))] if _w else []):
    if os.path.isfile(os.path.join(_d, "vasp_common.py")):
        sys.path.insert(0, _d)
        break
else:
    sys.exit("ERROR: vasp_common.py not found (next to this script or on PATH)")
from vasp_common import (job_status, oszicar_last, oszicar_scf_steps, outcar_head_search,  # noqa: E402
                         outcar_last_forces, outcar_last_match, outcar_natoms, read_incar,
                         read_poscar)

import numpy as np  # noqa: E402


def read_generation_info(d):
    path = os.path.join(d, "generation_info.txt")
    if not os.path.isfile(path):
        return None
    info = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                info[k.strip()] = v.strip()
    return info


def to_float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def find_runs(param, dirs):
    """[(dir, param, value, generation_index)]"""
    runs = []
    if dirs:
        for i, d in enumerate(dirs):
            info = read_generation_info(d) or {}
            p = info.get("modified_param", param or "")
            v = info.get("modified_value")
            if v is None:
                base = os.path.basename(os.path.normpath(d))
                v = base[len(p) + 1:] if p and base.startswith(p + "_") else base
            runs.append((d, p, v, i))
        return runs
    candidates = sorted(d for d in glob.glob("*/") if os.path.isfile(os.path.join(d, "generation_info.txt")))
    for d in candidates:
        info = read_generation_info(d)
        if param and info.get("modified_param", "").upper() != param.upper():
            continue
        idx = info.get("generation_index")
        runs.append((d.rstrip("/"), info.get("modified_param", ""), info.get("modified_value", ""),
                     int(idx) if idx and idx.isdigit() else len(runs)))
    if runs:
        params = sorted({r[1] for r in runs})
        if len(params) > 1:
            sys.exit("Several scans found (%s); choose one with -p PARAM." % ", ".join(params))
        return runs
    if not param:
        sys.exit("No folders with generation_info.txt here; give -p PARAM (PARAM_* folders) or folder names.")
    for i, d in enumerate(sorted(glob.glob(param + "_*/"))):
        runs.append((d.rstrip("/"), param, d.rstrip("/")[len(param) + 1:], i))
    if not runs:
        sys.exit("No %s_* folders found." % param)
    return runs


def order_runs(runs):
    values = [r[2] for r in runs if r[2].lower() != "none"]
    if values and all(to_float(v) is not None for v in values):
        return sorted(runs, key=lambda r: (-np.inf if r[2].lower() == "none" else float(r[2]))), True
    return sorted(runs, key=lambda r: r[3]), False


def analyse(d):
    row = {"status": "", "reason": "", "E0": None, "natoms": None, "E_atom": None, "Fmax": None,
           "P": None, "mag": None, "NELM_hits": None, "time": None, "NKPTS": None}
    row["status"], row["reason"] = job_status(d, final=False)
    outcar = os.path.join(d, "OUTCAR")
    oszicar = os.path.join(d, "OSZICAR")
    if os.path.isfile(oszicar):
        last = oszicar_last(oszicar)
        if last:
            row["E0"], row["mag"] = last["E0"], last["mag"]
        incar = os.path.join(d, "INCAR")
        nelm = 60
        if os.path.isfile(incar):
            v = read_incar(incar).get("NELM", "").split()[:1]
            nelm = int(v[0]) if v and v[0].isdigit() else 60
        row["NELM_hits"] = sum(1 for n in oszicar_scf_steps(oszicar) if n >= nelm)
    if os.path.isfile(outcar):
        row["natoms"] = outcar_natoms(outcar)
        nk = outcar_head_search(outcar, r"NKPTS\s*=\s*(\d+)")
        row["NKPTS"] = int(nk) if nk else None
        p = outcar_last_match(outcar, r"external pressure =\s*([-\d.]+)\s*kB")
        row["P"] = to_float(p)
        t = outcar_last_match(outcar, r"Elapsed time \(sec\):\s*([\d.]+)")
        row["time"] = to_float(t)
        forces = outcar_last_forces(outcar, row["natoms"])
        if forces is not None:
            free = np.ones_like(forces, dtype=bool)   # selective dynamics: True = free
            for name in ("CONTCAR", "POSCAR"):
                path = os.path.join(d, name)
                if not os.path.isfile(path) or os.path.getsize(path) == 0:
                    continue
                try:
                    sel = read_poscar(path).selective
                except (OSError, ValueError, IndexError):
                    continue
                if sel is not None and sel.shape == forces.shape:
                    free = sel
                break
            row["Fmax"] = float(np.linalg.norm(np.where(free, forces, 0.0), axis=1).max())
    if row["E0"] is not None and row["natoms"]:
        row["E_atom"] = row["E0"] / row["natoms"]
    return row


def fmt(v, spec, width):
    return ("%" + spec) % v if v is not None else "-".rjust(width)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("dirs", nargs="*", help="folders to compare (default: found automatically)")
    ap.add_argument("-p", "--param", help="INCAR tag of the scan (e.g. ENCUT)")
    ap.add_argument("-r", "--ref", help="reference value (default: last row = most accurate)")
    ap.add_argument("-t", "--threshold", type=float, default=1.0, help="meV/atom (default 1)")
    ap.add_argument("--csv", help="CSV file (default para_conv_<PARAM>.csv)")
    ap.add_argument("--plot", help="write a PNG plot of dE_ref and pressure")
    args = ap.parse_args()

    runs, numeric = order_runs(find_runs(args.param, args.dirs))
    param = args.param or runs[0][1] or "scan"
    rows = []
    for d, _, value, _ in runs:
        r = analyse(d)
        r["dir"], r["value"] = d, value
        rows.append(r)

    good = [r for r in rows if r["status"] == "converged" and r["E_atom"] is not None]
    ref = None
    if args.ref is not None:
        ref = next((r for r in rows if r["value"] == args.ref or
                    (to_float(r["value"]) is not None and to_float(r["value"]) == to_float(args.ref))), None)
        if ref is None:
            sys.exit("Reference value %s not found among: %s" % (args.ref, " ".join(r["value"] for r in rows)))
    elif good:
        ref = good[-1]
    prev = None
    for r in rows:
        r["dE_ref"] = r["dE_prev"] = None
        if r["E_atom"] is None:
            continue
        if ref is not None and ref["E_atom"] is not None:
            r["dE_ref"] = (r["E_atom"] - ref["E_atom"]) * 1000
        if prev is not None:
            r["dE_prev"] = (r["E_atom"] - prev["E_atom"]) * 1000
        prev = r

    # ---- table ----
    head = ("%-10s %-12s %15s %6s %13s %10s %10s %8s %9s %8s %5s %9s %6s"
            % (param, "status", "E0 (eV)", "atoms", "E/atom (eV)", "dE_prev", "dE_ref",
               "Fmax", "P (kB)", "mag", "NELM", "time (s)", "NKPTS"))
    print(head)
    print("%-10s %-12s %15s %6s %13s %10s %10s %8s %9s %8s %5s %9s %6s"
          % ("", "", "", "", "", "meV/atom", "meV/atom", "eV/A", "", "", "hits", "", ""))
    print("-" * len(head))
    for r in rows:
        print("%-10s %-12s %15s %6s %13s %10s %10s %8s %9s %8s %5s %9s %6s" % (
            r["value"][:10], r["status"], fmt(r["E0"], ".6f", 15), fmt(r["natoms"], "d", 6),
            fmt(r["E_atom"], ".6f", 13), fmt(r["dE_prev"], "+.2f", 10), fmt(r["dE_ref"], "+.2f", 10),
            fmt(r["Fmax"], ".3f", 8), fmt(r["P"], ".2f", 9), fmt(r["mag"], ".3f", 8),
            fmt(r["NELM_hits"], "d", 5), fmt(r["time"], ".0f", 9), fmt(r["NKPTS"], "d", 6)))
    print("-" * len(head))
    for r in rows:
        if r["status"] != "converged":
            print("  %s: %s (%s)" % (r["dir"], r["status"], r["reason"]))
        if r["NELM_hits"]:
            print("  %s: %d ionic step(s) hit NELM - electronic SCF not converged there" % (r["dir"], r["NELM_hits"]))
    if ref is not None:
        print("Reference: %s = %s (%s)" % (param, ref["value"], ref["dir"]))

    # ---- verdict ----
    has_none = any(r["value"].lower() == "none" for r in rows)
    if numeric and not has_none and ref is not None and good:
        conv = None
        for i, r in enumerate(good):
            if all(abs(g["dE_ref"]) < args.threshold for g in good[i:]):
                conv = r
                break
        if conv is ref and good[-1] is ref:
            print("Not converged within %g meV/atom below the reference %s = %s (extend the scan)"
                  % (args.threshold, param, ref["value"]))
        elif conv is not None:
            print("Converged at %s = %s (|dE| < %g meV/atom vs reference for this and all later values)"
                  % (param, conv["value"], args.threshold))
        else:
            print("Not converged within %g meV/atom" % args.threshold)
        if param.upper() == "ENCUT" and any(r["P"] is not None for r in good):
            print("  (check the pressure column too: for ENCUT the pressure should also be converged)")
    if good:
        best = min(good, key=lambda r: r["E_atom"])
        print("Lowest E/atom: %s = %s (%s)" % (param, best["value"], best["dir"]))

    # ---- CSV ----
    csv_path = args.csv or "para_conv_%s.csv" % param
    keys = ["value", "dir", "status", "reason", "E0", "natoms", "E_atom", "dE_prev", "dE_ref",
            "Fmax", "P", "mag", "NELM_hits", "time", "NKPTS"]
    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([param if k == "value" else k for k in keys])
        for r in rows:
            w.writerow(["" if r[k] is None else round(r[k], 6) if isinstance(r[k], float) else r[k]
                        for k in keys])
    print("CSV written: %s" % csv_path)

    # ---- plot ----
    if args.plot:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
        except ImportError:
            sys.exit("matplotlib not available: no plot written")
        pts = [r for r in rows if r["dE_ref"] is not None]
        x = [to_float(r["value"]) for r in pts] if numeric and all(r["value"].lower() != "none" for r in pts) \
            else list(range(len(pts)))
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.plot(x, [r["dE_ref"] for r in pts], "o-", color="black", label="dE vs reference")
        ax.axhspan(-args.threshold, args.threshold, color="0.85", label="±%g meV/atom" % args.threshold)
        ax.set_xlabel(param)
        ax.set_ylabel("dE (meV/atom)")
        if not (numeric and all(r["value"].lower() != "none" for r in pts)):
            ax.set_xticks(x)
            ax.set_xticklabels([r["value"] for r in pts], rotation=30)
        if any(r["P"] is not None for r in pts):
            ax2 = ax.twinx()
            ax2.plot(x, [r["P"] if r["P"] is not None else np.nan for r in pts], "s--", color="tab:red")
            ax2.set_ylabel("pressure (kB)", color="tab:red")
        ax.legend(loc="best")
        fig.tight_layout()
        fig.savefig(args.plot, dpi=150)
        print("Plot written: %s" % args.plot)


if __name__ == "__main__":
    main()
