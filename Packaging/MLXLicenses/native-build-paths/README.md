# Native build path modifications

Contributor: Li. Date: 2026-10-12.

The packaging tool `Scripts/native_build_paths.py` changes only newly prepared
copies. It strips nonessential debug symbol entries, remaps Rust and Cython
diagnostic source prefixes to relative strings of the same byte length, and
replaces MLX's build-machine-only last metallib fallback with an empty string.
All file-backed sections except the diagnosed `__TEXT,__cstring` must retain
their bytes. Executable instructions, exported functions and load commands are
checked statically; these checks do not establish runtime acceptance.

MLX's existing explicit override and four preceding colocated or bundle resource
lookups are retained. The packaged `mlx/lib/mlx.metallib` is still required.
The last fallback would previously refer to the builder's temporary directory.
For a clean source build, retain the existing MLX source and change only its
`mlx/backend/metal/CMakeLists.txt` compile definition to `METAL_PATH=""`.
The `MLX_METAL_PATH` variable must still select the build output of the Metal
compiler; it is separate from the embedded runtime fallback constant.

For clean Rust/Cython source builds, use the compiler's source-prefix remapping
options for the source and Cargo/build environment roots. The diagnostic suffix
and line information are retained. Existing upstream source and license texts
are unchanged. Each prepared runtime's `MODIFICATIONS.json` records the actual
input hash, changed byte ranges and final hash; ad-hoc signing, if required for
host imports, must update that final hash. No byte-identical rebuild is claimed.
