#!/bin/sh
# Added by Li on 2026-10-11. The unmodified publisher recipe is retained in
# libsndfile's release-build directory. This companion uses bundled archives
# exclusively, builds static codec inputs, and supplies their exact locations.
# Run from ASR-audio; pass a NEW absolute build directory as the only argument.
set -eu
source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_root=${1:?Usage: offline-rebuild.sh NEW_ABSOLUTE_BUILD_DIRECTORY}
case "$build_root" in /*) ;; *) echo "An absolute build directory is required." >&2; exit 1;; esac
if [ -e "$build_root" ] || [ -L "$build_root" ]; then
    echo "The build directory must be new." >&2; exit 1
fi
mkdir -p "$build_root"
cd "$build_root"
for archive in "$source_root"/CorrespondingSource/libogg-1.3.5.tar.gz \
    "$source_root"/CorrespondingSource/libvorbis-1.3.7.tar.gz \
    "$source_root"/CorrespondingSource/flac-1.4.3.tar.xz \
    "$source_root"/CorrespondingSource/opus-1.4.tar.gz \
    "$source_root"/CorrespondingSource/mpg123-1.32.3.tar.bz2 \
    "$source_root"/CorrespondingSource/lame-3.100.tar.gz \
    "$source_root"/CorrespondingSource/libsndfile-1.2.2.tar.xz; do
    tar -xf "$archive"
done
prefix="$build_root/local-prefix"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
for component in libogg-1.3.5 libvorbis-1.3.7 flac-1.4.3 opus-1.4 mpg123-1.32.3 lame-3.100; do
    (cd "$component"
     configuration=./configure
     if [ "$component" = libvorbis-1.3.7 ]; then
         # The publisher recipe removes this obsolete Darwin linker flag too.
         # Keep the original configure untouched; use a generated companion.
         sed 's/-force_cpusubtype_ALL//g' configure > configure-portable
         configuration=./configure-portable
     fi
     /bin/sh "$configuration" --enable-static --disable-shared --prefix="$prefix"
     make -j2; make install)
done
cmake -S libsndfile-1.2.2 -B sndfile-build \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_PREFIX_PATH="$prefix" -DBUILD_SHARED_LIBS=ON \
    -DENABLE_EXTERNAL_LIBS=ON -DENABLE_MPEG=ON -DBUILD_TESTING=OFF \
    -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
    -DOGG_INCLUDE_DIR="$prefix/include" -DOGG_LIBRARY="$prefix/lib/libogg.a" \
    -DFLAC_INCLUDE_DIR="$prefix/include" -DFLAC_LIBRARY="$prefix/lib/libFLAC.a" \
    -DVorbis_Vorbis_INCLUDE_DIR="$prefix/include" -DVorbis_Vorbis_LIBRARY="$prefix/lib/libvorbis.a" \
    -DVorbis_Enc_INCLUDE_DIR="$prefix/include" -DVorbis_Enc_LIBRARY="$prefix/lib/libvorbisenc.a" \
    -DOPUS_INCLUDE_DIR="$prefix/include" -DOPUS_LIBRARY="$prefix/lib/libopus.a" \
    -DMP3LAME_INCLUDE_DIR="$prefix/include" -DMP3LAME_LIBRARY="$prefix/lib/libmp3lame.a" \
    -Dmpg123_INCLUDE_DIR="$prefix/include" -Dmpg123_LIBRARY="$prefix/lib/libmpg123.a"
cmake --build sndfile-build --parallel 2
