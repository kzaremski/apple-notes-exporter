#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-android}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/.build/$MODE"
PREFIX="$WORK/prefix"
SOURCES="$WORK/sources"
JOBS="${JOBS:-4}"
mkdir -p "$SOURCES" "$PREFIX" "$HERE/output/licenses"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
HOST=()

if [[ "$MODE" == android ]]; then
    : "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an installed Android NDK (r27 or newer)}"
    TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    export PATH="$TOOLCHAIN/bin:$PATH"
    export CC=aarch64-linux-android26-clang CXX=aarch64-linux-android26-clang++
    export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    HOST=(--host=aarch64-linux-android)
    export CFLAGS="$CFLAGS -D__ANDROID_API__=26"
    OUTPUT="$HERE/output/arm64-v8a"
elif [[ "$MODE" == host ]]; then
    OUTPUT="$HERE/output/host"
else
    echo "Usage: bash Maui/native/build.sh [android|host]" >&2
    exit 2
fi

fetch() {
    local name="$1" url="$2" revision="$3" version="$4"
    if [[ ! -d "$SOURCES/$name/.git" ]]; then
        git init -q "$SOURCES/$name"
        git -C "$SOURCES/$name" remote add origin "$url"
        git -C "$SOURCES/$name" fetch -q --depth 1 origin "$revision"
        git -C "$SOURCES/$name" checkout -q --detach FETCH_HEAD
    fi
    printf '%s\n' "$version" > "$SOURCES/$name/.tarball-version"
}

autobuild() {
    local name="$1"
    shift
    if [[ -f "$WORK/$name.done" ]]; then return; fi
    (
        cd "$SOURCES/$name"
        NOCONFIGURE=1 ./autogen.sh
        ./configure "${HOST[@]}" --prefix="$PREFIX" --disable-shared --enable-static "$@"
        if [[ "$name" == libimobiledevice ]]; then
            make -C common -j"$JOBS"
            make -C src -j"$JOBS"
            make -C src install
            make -C include install
        else
            make -j"$JOBS"
            make install
        fi
    )
    touch "$WORK/$name.done"
}

fetch libplist https://github.com/libimobiledevice/libplist.git e1531342fe084781124d2243ccad8d8eca5c9db5 2.7.0
fetch glue https://github.com/libimobiledevice/libimobiledevice-glue.git ecc0f1ba4fca96f3d7ef060b6c53f2e0bcfe829f 1.3.3
fetch libusbmuxd https://github.com/libimobiledevice/libusbmuxd.git adf9c22b9010490e4b55eaeb14731991db1c172c 2.1.1
fetch libtatsu https://github.com/libimobiledevice/libtatsu.git 42329cb756682535c7c0f087987b78d1dd5b16c8 1.0.5
fetch libimobiledevice https://github.com/libimobiledevice/libimobiledevice.git 149f7623c672c1fa73122c7119a12bfc0012f2ac 1.4.0
fetch usbmuxd https://github.com/libimobiledevice/usbmuxd.git 3ded00c9985a5108cfc7591a309f9a23d57a8cba 1.1.1

if [[ "$MODE" == android ]]; then
    fetch openssl https://github.com/openssl/openssl.git 06a93bceb971b28dbb42e34a1402c13597d641b5 3.5.4
    fetch curl https://github.com/curl/curl.git 72ab3e6887dc5934fd55a1ba14ffac8625cad831 8.17.0
    fetch libusb https://github.com/libusb/libusb.git 15a7ebb4d426c5ce196684347d2b7cafad862626 1.0.29
    if [[ ! -f "$WORK/openssl.done" ]]; then
        (
            cd "$SOURCES/openssl"
            ./Configure android-arm64 -D__ANDROID_API__=26 --prefix="$PREFIX" no-shared no-tests
            make -j"$JOBS"
            make install_sw
        )
        touch "$WORK/openssl.done"
    fi
    autobuild curl --with-openssl="$PREFIX" --disable-curl --without-libpsl --without-zstd \
        --without-brotli --without-libidn2 --without-librtmp --disable-ldap --disable-ldaps --without-libssh2
    autobuild libusb --disable-udev
fi

if [[ ! -f "$WORK/patched" ]]; then
    python3 "$HERE/patch_sources.py" "$SOURCES" "$MODE"
    touch "$WORK/patched"
fi
autobuild libplist --without-cython --without-tools --without-tests
autobuild glue
autobuild libusbmuxd --without-tools
autobuild libtatsu
autobuild libimobiledevice --without-cython --without-readline

if [[ ! -f "$WORK/usbmuxd.done" ]]; then
    (
        cd "$SOURCES/usbmuxd"
        NOCONFIGURE=1 ./autogen.sh
        ./configure "${HOST[@]}" --prefix="$PREFIX" --without-preflight --without-systemd
    )
    touch "$WORK/usbmuxd.done"
fi

mkdir -p "$WORK/objects" "$OUTPUT"
FLAGS="$(pkg-config --cflags libimobiledevice-1.0 libimobiledevice-glue-1.0 libplist-2.0 libusb-1.0)"
for source in client device preflight log usb utils conf; do
    ${CC:-cc} $CFLAGS $CPPFLAGS $FLAGS -DHAVE_CONFIG_H \
        -I"$SOURCES/usbmuxd" -I"$SOURCES/usbmuxd/src" \
        -c "$SOURCES/usbmuxd/src/$source.c" -o "$WORK/objects/mux-$source.o"
done
${CC:-cc} $CFLAGS $CPPFLAGS $FLAGS -DHAVE_CONFIG_H \
    -I"$SOURCES/libimobiledevice" -I"$SOURCES/libimobiledevice/include" -I"$HERE" \
    -c "$SOURCES/libimobiledevice/tools/idevicebackup2.c" -o "$WORK/objects/backup.o"
${CC:-cc} $CFLAGS $CPPFLAGS $FLAGS -I"$SOURCES/usbmuxd/src" -I"$SOURCES/usbmuxd" \
    -c "$HERE/bridge.c" -o "$WORK/objects/bridge.o"
${CC:-cc} -shared -Wl,-z,defs -Wl,-z,max-page-size=16384 -Wl,--version-script="$HERE/exports.map" \
    -o "$OUTPUT/libnotesusb.so" "$WORK/objects/"*.o \
    $(pkg-config --static --libs libimobiledevice-1.0 libimobiledevice-glue-1.0 libplist-2.0 libusb-1.0) \
    -lm

for directory in "$SOURCES/"*/; do
    name="$(basename "$directory")"
    mkdir -p "$HERE/output/licenses/$name"
    find "$directory" -maxdepth 1 -type f \( -iname 'copying*' -o -iname 'license*' \) \
        -exec cp {} "$HERE/output/licenses/$name/" \;
done
printf 'Built %s/libnotesusb.so\n' "$OUTPUT"
