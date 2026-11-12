#!/usr/bin/env bash
#SBATCH --job-name=build_wps_ursa
#SBATCH --partition=u1-compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=03:00:00
#SBATCH --output=build_wps_%j.out
#SBATCH --error=build_wps_%j.err

set -euo pipefail

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*"
}

[[ -n "${SLURM_JOB_ID:-}" ]] ||
    die "Submit using sbatch."

# ------------------------------------------------------------
# 1. Resolve WoFS repository root
# ------------------------------------------------------------

SUBMIT_DIR="${SLURM_SUBMIT_DIR:?}"

if [[ -n "${HOMEwofs:-}" ]]; then
    :
elif [[ -f "$SUBMIT_DIR/versions/build.ver" ]]; then
    HOMEwofs="$SUBMIT_DIR"
elif [[ -f "$SUBMIT_DIR/../../versions/build.ver" ]]; then
    HOMEwofs="$SUBMIT_DIR/../.."
else
    die "Cannot determine HOMEwofs. Set HOMEwofs explicitly."
fi

HOMEwofs="$(cd "$HOMEwofs" && pwd -P)"

WPS_SOURCE_DIR="${WPS_SOURCE_DIR:-$HOMEwofs/sorc/WPS}"
WPS_SOURCE_DIR="$(cd "$WPS_SOURCE_DIR" && pwd -P)"

: "${WRF_BUILD_DIR:?Set WRF_BUILD_DIR to completed WRF build root}"

WRF_BUILD_DIR="$(cd "$WRF_BUILD_DIR" && pwd -P)"

WPS_BUILD_DIR="${WPS_BUILD_DIR:-$HOMEwofs/staging/WPS_build_${SLURM_JOB_ID}}"
WPS_BUILD_DIR="$(realpath -m "$WPS_BUILD_DIR")"

info "HOMEwofs=$HOMEwofs"
info "WPS_SOURCE_DIR=$WPS_SOURCE_DIR"
info "WRF_BUILD_DIR=$WRF_BUILD_DIR"
info "WPS_BUILD_DIR=$WPS_BUILD_DIR"

[[ -f "$WPS_SOURCE_DIR/configure" ]] ||
    die "Missing WPS configure script"

[[ -f "$WPS_SOURCE_DIR/compile" ]] ||
    die "Missing WPS compile script"

# ------------------------------------------------------------
# 2. Load centralized Ursa build environment
# ------------------------------------------------------------

BUILD_VER="$HOMEwofs/versions/build.ver"
MODULE_DIR="$HOMEwofs/modulefiles"

[[ -f "$BUILD_VER" ]] ||
    die "Missing $BUILD_VER"

[[ -f "$MODULE_DIR/ursa_wps.lua" ]] ||
    die "Missing $MODULE_DIR/ursa_wps.lua"

source "$BUILD_VER"

set +u
if [[ -f /etc/profile.d/modules.sh ]]; then
    source /etc/profile.d/modules.sh
fi

module purge
module use "$MODULE_DIR"
module load ursa_wps
set -u

for cmd in tar make ifort icc mpif90 \
           nc-config nf-config ldd timeout; do
    command -v "$cmd" >/dev/null ||
        die "Missing command: $cmd"
done

for var in NETCDF_C NETCDF_FORTRAN \
           JASPERLIB JASPERINC PNG_LIB PNG_INC; do
    [[ -n "${!var:-}" ]] ||
        die "Missing environment variable: $var"
done

# ------------------------------------------------------------
# 3. Validate previously completed WRF build
# ------------------------------------------------------------

info "Checking WRF build libraries"

for lib in \
    external/io_netcdf/libwrfio_nf.a \
    external/io_grib1/libio_grib1.a \
    external/io_grib_share/libio_grib_share.a \
    external/io_int/libwrfio_int.a
do
    [[ -s "$WRF_BUILD_DIR/$lib" ]] ||
        die "Missing WRF library: $lib"
done

[[ -s "$WRF_BUILD_DIR/configure.wrf" ]] ||
    die "Missing WRF configure.wrf"

info "WRF libraries verified"

# ------------------------------------------------------------
# 4. Create isolated WPS build directory
# ------------------------------------------------------------

[[ ! -e "$WPS_BUILD_DIR" && ! -L "$WPS_BUILD_DIR" ]] ||
    die "WPS build directory already exists: $WPS_BUILD_DIR"

# Prevent staging inside the source directory.
case "$WPS_BUILD_DIR/" in
    "$WPS_SOURCE_DIR/"*)
        die "WPS build directory cannot be inside WPS source"
        ;;
esac

mkdir -p "$WPS_BUILD_DIR/logs"
mkdir -p "$WPS_BUILD_DIR/netcdf_combined/include"
mkdir -p "$WPS_BUILD_DIR/netcdf_combined/lib"

info "Copying WPS source"

tar -C "$WPS_SOURCE_DIR" \
    --exclude=.git \
    --exclude=configure.wps \
    --exclude=compile.log \
    --exclude=build_logs \
    --exclude='*.exe' \
    --exclude='*.o' \
    --exclude='*.a' \
    --exclude='*.mod' \
    --exclude='*.log' \
    -cf - . |
tar -C "$WPS_BUILD_DIR" -xf -

# ------------------------------------------------------------
# 5. Prepare combined NetCDF interface
# ------------------------------------------------------------

for prefix in "$NETCDF_C" "$NETCDF_FORTRAN"; do
    for file in "$prefix"/include/*; do
        [[ -e "$file" ]] || continue
        ln -s "$file" \
            "$WPS_BUILD_DIR/netcdf_combined/include/$(basename "$file")" \
            2>/dev/null || true
    done

    for file in "$prefix"/lib/libnetcdf*; do
        [[ -e "$file" ]] || continue
        ln -s "$file" \
            "$WPS_BUILD_DIR/netcdf_combined/lib/$(basename "$file")" \
            2>/dev/null || true
    done
done

export NETCDF="$WPS_BUILD_DIR/netcdf_combined"
export WRF_DIR="$WRF_BUILD_DIR"
export JASPERLIB JASPERINC

cd "$WPS_BUILD_DIR"

{
    echo "Date: $(date)"
    echo "Job: $SLURM_JOB_ID"
    echo "WoFS root: $HOMEwofs"
    echo "WPS source: $WPS_SOURCE_DIR"
    echo "WRF build: $WRF_BUILD_DIR"
    echo "NetCDF-C: $NETCDF_C"
    echo "NetCDF-Fortran: $NETCDF_FORTRAN"
    echo "Jasper: $JASPERLIB"
    echo "PNG: $PNG_LIB"
    git -C "$WPS_SOURCE_DIR" rev-parse HEAD || true
    module list
} > logs/build_environment.log 2>&1

# ------------------------------------------------------------
# 6. Configure WPS
# ------------------------------------------------------------

WPS_CONFIG_OPTION="${WPS_CONFIG_OPTION:-19}"

info "Configuring WPS: option $WPS_CONFIG_OPTION"

if ! printf '%s\n' "$WPS_CONFIG_OPTION" |
    timeout 120 ./configure > logs/configure.log 2>&1; then
    tail -100 logs/configure.log
    die "WPS configuration failed"
fi

[[ -s configure.wps ]] || {
    tail -100 logs/configure.log
    die "configure.wps not generated"
}

sed -i \
    "s|^WRF_DIR[[:space:]]*=.*|WRF_DIR = ${WRF_BUILD_DIR}|" \
    configure.wps

sed -i \
    "s|^COMPRESSION_LIBS[[:space:]]*=.*|COMPRESSION_LIBS = -L${JASPERLIB} -ljasper -L${PNG_LIB} -lpng -lz|" \
    configure.wps

sed -i \
    "s|^COMPRESSION_INC[[:space:]]*=.*|COMPRESSION_INC = -I${JASPERINC} -I${PNG_INC}|" \
    configure.wps

cp configure.wps logs/configure.wps.verified

info "WPS configuration completed"

# ------------------------------------------------------------
# 7. Compile WPS
# ------------------------------------------------------------

info "Starting WPS compilation"

export J="-j ${SLURM_CPUS_PER_TASK:-8}"

if ! ./compile > logs/compile.log 2>&1; then
    tail -150 logs/compile.log
    die "WPS compilation failed"
fi

info "WPS compilation finished"

# ------------------------------------------------------------
# 8. Validate executables
# ------------------------------------------------------------

FAILED=0

for exe in geogrid ungrib metgrid; do
    FILE="$WPS_BUILD_DIR/$exe/src/$exe.exe"

    if [[ ! -x "$FILE" ]]; then
        echo "[FAIL] Missing executable: $FILE"
        FAILED=1
        continue
    fi

    if ldd "$FILE" | grep -q "not found"; then
        echo "[FAIL] Missing shared libraries: $FILE"
        ldd "$FILE"
        FAILED=1
        continue
    fi

    echo "[PASS] $exe"
    ls -lh "$FILE"
done

[[ "$FAILED" -eq 0 ]] ||
    die "WPS executable validation failed"

echo
echo "=========================================="
echo "[PASS] WPS build completed successfully"
echo "WRF: $WRF_BUILD_DIR"
echo "WPS: $WPS_BUILD_DIR"
echo "=========================================="
