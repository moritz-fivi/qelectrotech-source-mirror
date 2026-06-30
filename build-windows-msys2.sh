#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Local MSYS2 build script for Windows
# Intended to be run inside: MSYS2 UCRT64
# -----------------------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
NSIS_ROOT="$ROOT_DIR/nsis_root"
FILES_DIR="$NSIS_ROOT/files"
BIN_DIR="$FILES_DIR/bin"

# -----------------------------------------------------------------------------
# Install required packages
# -----------------------------------------------------------------------------
echo "=== Installing required MSYS2 packages ==="

PACMAN_PACKAGES=(
  git
  zip
  mingw-w64-ucrt-x86_64-ccache
  mingw-w64-ucrt-x86_64-gcc
  mingw-w64-ucrt-x86_64-cmake
  mingw-w64-ucrt-x86_64-ninja
  mingw-w64-ucrt-x86_64-qt5-base
  mingw-w64-ucrt-x86_64-qt5-svg
  mingw-w64-ucrt-x86_64-qt5-tools
  mingw-w64-ucrt-x86_64-qt5-translations
  mingw-w64-ucrt-x86_64-sqlite3
  mingw-w64-ucrt-x86_64-kwidgetsaddons
  mingw-w64-ucrt-x86_64-kcoreaddons
  mingw-w64-ucrt-x86_64-extra-cmake-modules
  mingw-w64-ucrt-x86_64-nsis
  mingw-w64-ucrt-x86_64-angleproject
)

pacman -S --needed --noconfirm "${PACMAN_PACKAGES[@]}"

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
if [[ "${MSYSTEM:-}" != "UCRT64" ]]; then
  echo "ERROR: Please run this script inside MSYS2 UCRT64 shell."
  echo "Current MSYSTEM=${MSYSTEM:-<unset>}"
  exit 1
fi

for cmd in git cmake ninja python3 sed grep find ldd zip; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Missing command: $cmd"
    exit 1
  }
done

mkdir -p "$BUILD_DIR" "$DIST_DIR" "$BIN_DIR"

# -----------------------------------------------------------------------------
# Update submodules
# -----------------------------------------------------------------------------
echo "=== Updating submodules ==="
git -C "$ROOT_DIR" submodule update --init --recursive

# -----------------------------------------------------------------------------
# Configure ccache
# -----------------------------------------------------------------------------
if command -v /ucrt64/bin/ccache >/dev/null 2>&1; then
  echo "=== Configuring ccache ==="
  /ucrt64/bin/ccache --set-config=max_size=500M || true
  /ucrt64/bin/ccache --set-config=compression=true || true
  /ucrt64/bin/ccache -z || true
  /ucrt64/bin/ccache -p || true
fi

# -----------------------------------------------------------------------------
# Patch NSIS Welcome / Finish page fonts
# -----------------------------------------------------------------------------
echo "=== Patching NSIS font size ==="

WELCOME_NSH="$(find /ucrt64 -path "*/Modern UI 2/Pages/Welcome.nsh" | head -1 || true)"
if [[ -n "${WELCOME_NSH:-}" ]]; then
  sed -i '/WelcomePage\.Title\.Font/s/"[0-9]\+" "700"/"10" "700"/' "$WELCOME_NSH"
  grep 'WelcomePage.Title.Font' "$WELCOME_NSH" || true
else
  echo "WARNING: Welcome.nsh not found"
fi

FINISH_NSH="$(find /ucrt64 -path "*/Modern UI 2/Pages/Finish.nsh" | head -1 || true)"
if [[ -n "${FINISH_NSH:-}" ]]; then
  sed -i '/FinishPage\.Title\.Font/s/"[0-9]\+" "700"/"10" "700"/' "$FINISH_NSH"
  grep 'FinishPage.Title.Font' "$FINISH_NSH" || true
else
  echo "WARNING: Finish.nsh not found"
fi

# -----------------------------------------------------------------------------
# Force Qt5
# -----------------------------------------------------------------------------
echo "=== Forcing Qt5 ==="
rm -rf /ucrt64/lib/cmake/Qt6 || true
pacman -R --noconfirm mingw-w64-ucrt-x86_64-qt6-tools >/dev/null 2>&1 || true
ls /ucrt64/bin/windeployqt* || true

# -----------------------------------------------------------------------------
# Configure and build
# -----------------------------------------------------------------------------
echo "=== Configure build ==="
cd "$BUILD_DIR"

NPROC="$(nproc)"
echo "Available CPUs: $NPROC"

cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/ucrt64 \
  -DQt5_DIR=/ucrt64/lib/cmake/Qt5 \
  -DQT_VERSION_MAJOR=5 \
  -DCMAKE_DISABLE_FIND_PACKAGE_Qt6=ON \
  -DBUILD_TESTING=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_CXX_FLAGS="-DQET_EXPORT_PROJECT_DB" \
  -DCMAKE_C_COMPILER_LAUNCHER=/ucrt64/bin/ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=/ucrt64/bin/ccache \
  -DSQLite3_INCLUDE_DIR=/ucrt64/include \
  -DSQLite3_LIBRARY=/ucrt64/lib/libsqlite3.dll.a \
  "$ROOT_DIR"

echo "=== Build ==="
ninja -j"$NPROC"

# -----------------------------------------------------------------------------
# ccache stats
# -----------------------------------------------------------------------------
if command -v /ucrt64/bin/ccache >/dev/null 2>&1; then
  echo "=== ccache statistics ==="
  /ucrt64/bin/ccache -s || true
fi

# -----------------------------------------------------------------------------
# Verify EXE
# -----------------------------------------------------------------------------
echo "=== Verify exe ==="
EXE="$(find "$BUILD_DIR" -maxdepth 3 -iname "qelectrotech.exe" | head -1 || true)"
if [[ -z "${EXE:-}" ]]; then
  echo "ERROR: qelectrotech.exe not found"
  find "$BUILD_DIR" -maxdepth 3 -iname "*.exe" || true
  exit 1
fi

SIZE="$(stat -c%s "$EXE")"
echo "Exe found: $EXE ($SIZE bytes)"
if [[ "$SIZE" -le 100000 ]]; then
  echo "ERROR: exe too small"
  exit 1
fi

# -----------------------------------------------------------------------------
# Prepare portable directory
# -----------------------------------------------------------------------------
echo "=== Preparing portable structure ==="
cp "$EXE" "$BIN_DIR/QElectroTech.exe"

cd "$BIN_DIR"
/ucrt64/bin/windeployqt-qt5 \
  --release \
  --no-translations \
  --no-compiler-runtime \
  ./QElectroTech.exe || true

echo "=== 3-pass transitive DLL scan ==="
set +e
for PASS in 1 2 3; do
  echo "-- Pass $PASS --"
  for bin_file in \
    "$BIN_DIR"/*.dll \
    "$BIN_DIR"/*.exe \
    "$BIN_DIR"/sqldrivers/*.dll \
    "$BIN_DIR"/platforms/*.dll \
    "$BIN_DIR"/imageformats/*.dll
  do
    [[ -f "$bin_file" ]] || continue
    while IFS= read -r line; do
      dll_path="$(echo "$line" | awk '{print $3}')"
      [[ -f "$dll_path" ]] || continue
      dll_name="$(basename "$dll_path")"
      dst="$BIN_DIR/$dll_name"
      if [[ ! -f "$dst" ]]; then
        cp "$dll_path" "$dst"
        echo "  Copied (pass $PASS): $dll_name"
      fi
    done < <(ldd "$bin_file" 2>/dev/null | grep -i '/ucrt64/bin/')
  done
done
set -e

cp /ucrt64/bin/libgcc_s_seh-1.dll "$BIN_DIR/" || true
cp /ucrt64/bin/libstdc++-6.dll "$BIN_DIR/" || true
cp /ucrt64/bin/libwinpthread-1.dll "$BIN_DIR/" || true

SQLITE="$(find /ucrt64/bin -iname "libsqlite3*.dll" | head -1 || true)"
if [[ -n "${SQLITE:-}" ]]; then
  cp "$SQLITE" "$BIN_DIR/"
fi

# -----------------------------------------------------------------------------
# Copy resources
# -----------------------------------------------------------------------------
echo "=== Copying resources ==="
mkdir -p "$FILES_DIR/lang"

cp "$ROOT_DIR/build-aux/windows/QET64.nsi"              "$NSIS_ROOT/" || true
cp "$ROOT_DIR/build-aux/windows/lang_extra.nsh"         "$NSIS_ROOT/" || true
cp "$ROOT_DIR/build-aux/windows/lang_extra_fr.nsh"      "$NSIS_ROOT/" || true
cp "$ROOT_DIR/build-aux/windows/lang_extra_missing.nsh" "$NSIS_ROOT/" || true
cp -r "$ROOT_DIR/build-aux/windows/nsis_base/." "$NSIS_ROOT/" || true

cp -r "$ROOT_DIR/elements"    "$FILES_DIR/elements"    2>/dev/null || true
cp -r "$ROOT_DIR/titleblocks" "$FILES_DIR/titleblocks" 2>/dev/null || true
cp -r "$ROOT_DIR/examples"    "$FILES_DIR/examples"    2>/dev/null || true
cp -r "$ROOT_DIR/fonts"       "$FILES_DIR/fonts"       2>/dev/null || true
cp -r "$ROOT_DIR/lang"        "$FILES_DIR/lang"        2>/dev/null || true

find "$BUILD_DIR" -iname "*.qm" -exec cp {} "$FILES_DIR/lang/" \; 2>/dev/null || true

for f in LICENSE ChangeLog CREDIT README ELEMENTS.LICENSE; do
  cp "$ROOT_DIR/$f" "$FILES_DIR/$f" 2>/dev/null || true
done

# Optional: local fallback instead of curl
if [[ -f "$ROOT_DIR/build-aux/windows/Lancer QET.bat" ]]; then
  cp "$ROOT_DIR/build-aux/windows/Lancer QET.bat" "$FILES_DIR/Lancer QET.bat"
fi

# -----------------------------------------------------------------------------
# Version naming
# -----------------------------------------------------------------------------
echo "=== Detecting version ==="

GITCOMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
A="$(git -C "$ROOT_DIR" rev-list HEAD --count)"
HEAD_REV="$((A + 473))"

VERSION="$(
  grep 'return QVersionNumber{' "$ROOT_DIR/sources/qetversion.cpp" \
  | head -1 \
  | awk -F '{' '{ print $2 }' \
  | awk -F '}' '{ print $1 }' \
  | sed -e 's/,/./g' -e 's/ //g'
)"
[[ -z "${VERSION:-}" ]] && VERSION="dev"

FULL_VERSION="${VERSION}-r${HEAD_REV}-${GITCOMMIT}_x86_64-win64"
ZIP_NAME="qelectrotech-${VERSION}+git${HEAD_REV}-x86-win64-readytouse.zip"

echo "VERSION      : $VERSION"
echo "GITCOMMIT    : $GITCOMMIT"
echo "HEAD_REV     : $HEAD_REV"
echo "FULL_VERSION : $FULL_VERSION"
echo "ZIP_NAME     : $ZIP_NAME"

# -----------------------------------------------------------------------------
# Patch NSIS script
# -----------------------------------------------------------------------------
if [[ -f "$NSIS_ROOT/QET64.nsi" && -f "$ROOT_DIR/build-aux/windows/patch_nsi.py" ]]; then
  echo "=== Patching QET64.nsi ==="
  FILES_WIN="$(cygpath -w "$FILES_DIR")"
  python3 "$ROOT_DIR/build-aux/windows/patch_nsi.py" \
    "$NSIS_ROOT/QET64.nsi" \
    "$FULL_VERSION" \
    "$FILES_WIN"
fi

# -----------------------------------------------------------------------------
# Build NSIS installer
# -----------------------------------------------------------------------------
if [[ -f "$NSIS_ROOT/QET64.nsi" ]]; then
  echo "=== Building NSIS installer ==="
  cd "$NSIS_ROOT"
  MSYS2_ARG_CONV_EXCL="*" makensis /V4 QET64.nsi
fi

# -----------------------------------------------------------------------------
# Move installer to dist
# -----------------------------------------------------------------------------
echo "=== Moving installer ==="
INSTALLER="$(find "$NSIS_ROOT" -maxdepth 1 -iname "installer_*.exe" | head -1 || true)"
if [[ -n "${INSTALLER:-}" ]]; then
  mv "$INSTALLER" "$DIST_DIR/"
fi

# -----------------------------------------------------------------------------
# Zip portable
# -----------------------------------------------------------------------------
echo "=== Creating portable zip ==="
cd "$FILES_DIR"
zip -r "$DIST_DIR/$ZIP_NAME" .

echo "=== Done ==="
echo "Portable folder : $FILES_DIR"
echo "Portable zip    : $DIST_DIR/$ZIP_NAME"
echo "Installer dir   : $DIST_DIR"