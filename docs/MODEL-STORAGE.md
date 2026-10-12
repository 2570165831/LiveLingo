# Model data storage (0.3.0 preparation, 0.3.1 interface)

0.3.0 keeps every runtime loader on `Contents/Resources/Models`. A separate
background task prepares independent APFS clones for a later upgrade. Neither a
successful preclone nor its receipt changes the active model or loader path.

## Signed inventory and stable versions

`Scripts/model_storage_manifest.py --app <newly assembled app>` reads the final
packaged model files after licenses/notices are installed and before signing.
`bundle-mlx-app.py` invokes it automatically. Other assemblers must invoke the
same function/CLI at that point. Plain Xcode development/test apps have no
models/inventory; preclone diagnoses this and leaves runtime behavior alone.

The App resource seal includes `Contents/Resources/model-storage-manifest.json`:

```json
{
  "schemaVersion": 1,
  "sampleAlgorithm": "first-middle-last-64KiB-v1",
  "fullHashMaxBytes": 1048576,
  "models": [{
    "name": "Qwen3.5-4B-MLX-8bit",
    "version": "sha256-<64 lowercase hex digits>",
    "sourceRelativePath": "mlx-community/Qwen3.5-4B-MLX-8bit",
    "files": [{
      "path": "config.json",
      "size": 123,
      "sha256": "<complete file SHA-256>",
      "sampleSHA256": "<bounded verification SHA-256>"
    }]
  }]
}
```

Example values above describe the schema, not actual model bytes. Paths are
relative, ordinary files only; traversal, symlinks, hard links, duplicate names,
file/directory collisions and unsupported schemas are rejected. Every file
under each of the four packaged model directories is listed, including nested
data and required licenses. Files outside these model directories are not
model payloads. Empty directories have no effect on loading and are omitted.

Version is `sha256-` plus SHA-256 of the model object *without* its version:
UTF-8 JSON, keys sorted, separators `,` and `:`, ASCII escaping enabled. Sorted
file records include full hashes and sizes. Identical data has a stable version;
a content, path, license or sample-rule change creates another version. No
host path, time, author or device identifier enters the inventory.

## Destination and publication

Production uses the sandbox's user Application Support directory:

```text
LiveLingo/Models/
  <model name>/
    .preclone-lock
    <content version>/
      <original file paths>
      preclone-state.json
    .partial-<content version>-<UUID>/
    .retained-<content version>-<UUID>/
```

Preview builds use their own `PreviewDataIsolation` data root. Unit-test hosts
do not start this controller; tests inject temporary roots. No courses,
checkpoints or recording folders are inspected by preclone.

After a 15-second launch grace period, a detached task at background priority
starts only when not preparing, recording, paused or stopping. The phase
observer updates an in-memory flag synchronously. Each file and each read
checks that flag; a new recording defers remaining work. Finishing capture
retries after another grace period. Other failures retry at the next launch.
No audio/UI operation waits for cloning or hashing. An already entered kernel
clone call/read cannot be preempted by the flag, but reads are bounded.

For each model the worker holds a nonblocking `flock`, checks a committed
receipt and data when present, otherwise creates a private staging directory
and receipt. It walks paths through directory descriptors, opens sources with
no-follow flags, and calls `fclonefileat` (the descriptor-based `clonefile`
API) once per file. It does not call copyfile or provide a real-copy fallback.
Different devices fail before cloning; unsupported cloning, insufficient space
and any other clone failure retain the partial and diagnose an errno. Cloned
files are set to mode 0600; newly created directories use 0700.

After verification, the worker checks root/parent/staging identity and performs
an exclusive same-parent atomic rename (`RENAME_EXCL`); it never overwrites an
existing version. It rechecks the full destination binding after rename/sync
before reporting success. The receipt and directories are synced around publication.
On restart, only a correctly named, owned partial with a matching receipt is
renamed to `.retained-*`. Unknown files, symlinks, other versions and another
worker's locked data stay untouched. Nothing is sent to Trash or deleted.
Retained data requires an explicitly authorized model-management cleanup later.

## Hash cost and the evidence boundary

Assembly streams every file once for full SHA-256. On launch, files at most
1 MiB are fully hashed. Larger files are checked for exact size and hashed over
three 64 KiB ranges: start 0, start `(size - 65536) / 2` (integer floor), and
start `size - 65536`, concatenated in that order. This limits weight reads to
192 KiB per large file and detects common truncation/sample corruption without
reading about 14 GB on each startup. File size and modification/change times
are compared before/after each read. A final directory walk rechecks verified
file identities, birth/change/modification times, modes, sizes and ancestor
directory snapshots to reject replacement during verification. The same bounded check runs on later
launches rather than trusting a writable receipt alone.

`preclone-state.json` contains schema version, model name, content version,
the source inventory SHA-256 and `verification: "sampledPrecloneV1"`. A newer
App inventory may change because a different model changed; an unchanged model
version is reused only after checking its files against the current inventory.

Sampling is **not** a complete authenticity check: same-size corruption outside
the sampled ranges can pass. APFS clones are independent files, not hard links;
later edits consume copy-on-write space. Cloning avoids an initial second
payload allocation, but metadata still needs space and keeping the clone can
retain blocks after the original App is replaced. There is no promise of zero
disk use or bounded wall time on a stalled filesystem.

## 0.3.1 activation contract

Reuse schema 1, content-version directories and the signed App inventory.
Model packages remain unsigned data. Do not trust their supplied manifest or
the writable preclone receipt to authorize loading. Resolve only the version
required by the installed signed App; authenticate every listed file against
that App's SHA-256, reject extra files, then switch the loader to that directory.
`ModelStorage.verify(model, at: directory, verification: .fullSHA256,
checkpoint: ...)` provides the streaming full-file check. Its receipt name is
an allowed storage-side bookkeeping file, not a model input.

Full verification is required once before activation of both imported packages
and 0.3.0 preclones. A future incremental cache must bind verified files to
their identity and change metadata, handle invalidation, and must not promote
`sampledPrecloneV1` into a full-verification claim. Selecting an older App,
security-scoped access, missing-model UI, external model-package import,
runtime directory selection and user-requested old-version cleanup belong to
0.3.1 and are not implemented here.
