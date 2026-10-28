#!/bin/bash
# Old name kept: vasp_workflow_input_generator.sh for Slurm (Setonix) (--scheduler slurm); options and piped answers pass through
_impl="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_workflow_input_generator.sh"; [ -f "$_impl" ] || _impl=$(command -v vasp_workflow_input_generator.sh)
[ -n "$_impl" ] || { echo "❌ vasp_workflow_input_generator.sh not found (next to $0 or on PATH)" >&2; exit 1; }
exec bash "$_impl" --scheduler slurm "$@"
