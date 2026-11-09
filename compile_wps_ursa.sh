#!/bin/bash
#SBATCH --job-name=compile_wps_ursa
#SBATCH --partition=u1-compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=compile_wps_%j.out
#SBATCH --error=compile_wps_%j.err

set -euo pipefail

# Resolve the same repository root as build_wps_ursa.sh.
if [[ -n "${HOMEwofs:-}" ]]; then
    HOMEwofs="$(cd "$HOMEwofs" && pwd -P)"
elif [[ -f "${SLURM_SUBMIT_DIR:-}/versions/build.ver" ]]; then
    HOMEwofs="$(cd "$SLURM_SUBMIT_DIR" && pwd -P)"
elif [[ -f "${SLURM_SUBMIT_DIR:-}/../../versions/build.ver" ]]; then
    HOMEwofs="$(cd "$SLURM_SUBMIT_DIR/../.." && pwd -P)"
else
    echo "[ERROR] Cannot determine HOMEwofs" >&2
    exit 1
fi

: "${WPS_BUILD_DIR:?Set WPS_BUILD_DIR to the prepared WPS staging directory}"
WPS_BUILD_DIR="$(cd "$WPS_BUILD_DIR" && pwd -P)"

# Load centralized WoFS build dependency versions.
BUILD_VER="$HOMEwofs/versions/build.ver"

if [[ ! -f "$BUILD_VER" ]]; then
    echo "[ERROR] Missing build version file: $BUILD_VER" >&2
    exit 1
fi

source "$BUILD_VER"
echo "[INFO] Loaded build versions: $BUILD_VER"

module purge
module use "$HOMEwofs/modulefiles"
module load ursa_wps

export NETCDF="$WPS_BUILD_DIR/netcdf_combined"

cd "$WPS_BUILD_DIR"

[[ -s configure.wps ]] || {
    echo "[ERROR] configure.wps not found"
    exit 1
}

mkdir -p logs

echo "===== WPS compilation ====="
echo "Build directory: $PWD"
echo "NetCDF: $NETCDF"

./compile wps > logs/compile.log 2>&1

echo
echo "===== Executable validation ====="

failed=0

for exe in geogrid ungrib metgrid; do
    file="$WPS_BUILD_DIR/${exe}/src/${exe}.exe"

    if [[ -x "$file" ]]; then
        echo "[OK] $exe"
        ls -lh "$file"
    else
        echo "[FAIL] $exe"
        failed=1
    fi
done

if [[ "$failed" -ne 0 ]]; then
    echo "[ERROR] One or more WPS executables are missing"
    tail -100 logs/compile.log
    exit 1
fi

echo
echo "[SUCCESS] All three WPS executables built."
