#!/bin/bash
#SBATCH --job-name=build_wps_ursa
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=build_wps_%j.out
#SBATCH --error=build_wps_%j.err

set -euo pipefail

# Resolve the repository root from HOMEwofs or the submission directory.
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

WPS_SOURCE_DIR="${WPS_SOURCE_DIR:-$HOMEwofs/sorc/WPS}"
WRF_BUILD_DIR="${WRF_BUILD_DIR:-$HOMEwofs/staging/WRF_build_nco_test_20261108_v2}"
: "${WPS_BUILD_DIR:?Set WPS_BUILD_DIR to a new staging directory}"

WPS_SOURCE_DIR="$(cd "$WPS_SOURCE_DIR" && pwd -P)"
WRF_BUILD_DIR="$(cd "$WRF_BUILD_DIR" && pwd -P)"
WPS_BUILD_DIR="$(realpath -m "$WPS_BUILD_DIR")"

SCRIPT_DIR="$WPS_SOURCE_DIR"

echo "===== WPS build paths ====="
echo "SLURM_SUBMIT_DIR=${SLURM_SUBMIT_DIR:-N/A}"
echo "SCRIPT_DIR=$SCRIPT_DIR"
echo "HOMEwofs=$HOMEwofs"
echo "WPS_SOURCE_DIR=$WPS_SOURCE_DIR"
echo "WRF_BUILD_DIR=$WRF_BUILD_DIR"
echo "WPS_BUILD_DIR=$WPS_BUILD_DIR"

echo
echo "===== Verify WRF build ====="

if [[ ! -f "$WRF_BUILD_DIR/external/io_netcdf/libwrfio_nf.a" ]]; then
    echo "[ERROR] WRF NetCDF I/O library not found"
    exit 1
fi


# Avoid modifying an existing staging build.
if [[ -e "$WPS_BUILD_DIR" || -L "$WPS_BUILD_DIR" ]]; then
    echo "[ERROR] Build directory already exists: $WPS_BUILD_DIR"
    exit 1
fi

# Load the reproducible build environment.
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

for var in NETCDF_C NETCDF_FORTRAN JASPERLIB JASPERINC PNG_LIB PNG_INC; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Missing environment variable: $var"
        exit 1
    fi
done

for lib in \
    external/io_netcdf/libwrfio_nf.a \
    external/io_grib1/libio_grib1.a \
    external/io_grib_share/libio_grib_share.a \
    external/io_int/libwrfio_int.a
do
    [[ -f "$WRF_BUILD_DIR/$lib" ]] || {
        echo "[ERROR] Missing WRF library: $lib"
        exit 1
    }
done

mkdir -p "$WPS_BUILD_DIR"/{logs,netcdf_combined/include,netcdf_combined/lib}

# Copy the current source tree, including the uncommitted Ursa fixes.
# Exclude generated binaries, objects, and prior configuration.
tar -C "$WPS_SOURCE_DIR" \
    --exclude=.git \
    --exclude=configure.wps \
    --exclude=compile.log \
    --exclude='*.exe' \
    --exclude='*.o' \
    --exclude='*.a' \
    --exclude='*.mod' \
    --exclude='*.log' \
    --exclude='*.log.*' \
    -cf - . | tar -C "$WPS_BUILD_DIR" -xf -

# WPS expects WRF_DIR relative to its build directory.

# Create a combined NetCDF interface using symbolic links.
for prefix in "$NETCDF_C" "$NETCDF_FORTRAN"; do
    for file in "$prefix"/include/*; do
        [[ -e "$file" ]] || continue
        ln -s "$file" "$WPS_BUILD_DIR/netcdf_combined/include/$(basename "$file")" 2>/dev/null || true
    done

    for file in "$prefix"/lib/libnetcdf*; do
        [[ -e "$file" ]] || continue
        ln -s "$file" "$WPS_BUILD_DIR/netcdf_combined/lib/$(basename "$file")" 2>/dev/null || true
    done
done

export NETCDF="$WPS_BUILD_DIR/netcdf_combined"
export WRF_DIR="$WRF_BUILD_DIR"
export JASPERLIB JASPERINC

cd "$WPS_BUILD_DIR"

{
    echo "WPS source: $WPS_SOURCE_DIR"
    echo "WRF build: $WRF_BUILD_DIR"
    echo "NetCDF-C: $NETCDF_C"
    echo "NetCDF-Fortran: $NETCDF_FORTRAN"
    echo "Jasper: $JASPERLIB"
    echo "PNG: $PNG_LIB"
    git -C "$WPS_SOURCE_DIR" rev-parse HEAD
    module list
} > logs/build_environment.log 2>&1

# Select the Intel dmpar architecture with GRIB2 enabled.
# Determine its menu number dynamically from the architecture listing.

# ============================================================
# Configure WPS using Intel MPI with GRIB2 support
# ============================================================

echo "[INFO] Configuring WPS with Intel dmpar (option 19)"

printf '19\n' | timeout 120 ./configure > logs/configure.log 2>&1

if [[ ! -s configure.wps ]]; then
    echo "[ERROR] WPS configure.wps was not generated."
    tail -50 logs/configure.log
    exit 1
fi

# ============================================================
# Step 3: Correct the WRF and compression library paths
# ============================================================

# Use the validated WRF build.
sed -i \
    "s|^WRF_DIR[[:space:]]*=.*|WRF_DIR = ${WRF_BUILD_DIR}|" \
    configure.wps

# Set Jasper and PNG libraries.
sed -i \
    "s|^COMPRESSION_LIBS[[:space:]]*=.*|COMPRESSION_LIBS = -L${JASPERLIB} -ljasper -L${PNG_LIB} -lpng -lz|" \
    configure.wps

# Set Jasper and PNG headers.
sed -i \
    "s|^COMPRESSION_INC[[:space:]]*=.*|COMPRESSION_INC = -I${JASPERINC} -I${PNG_INC}|" \
    configure.wps

# ============================================================
# Step 4: Verify generated WPS configuration
# ============================================================

echo "===== WPS configuration ====="

grep -E \
    '^(WRF_DIR|COMPRESSION_LIBS|COMPRESSION_INC|SFC|SCC|DM_FC|DM_CC|FDEFS)[[:space:]]*=' \
    configure.wps

echo
echo "[INFO] WPS configuration completed successfully."
echo "[INFO] Build directory: $WPS_BUILD_DIR"

