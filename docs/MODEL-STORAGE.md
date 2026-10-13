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

Production uses the sandbox's user Application Support directory. Before any
model payload is created, the Models root is marked `isExcludedFromBackup = true`
and the Foundation resource value is read back without cached values. The
readback constructs a fresh URL so the caller's cached values do not substitute
for the current resource state.
The backing exclusion attribute is written through the opened root descriptor,
so replacing the root's pathname cannot mark an unrelated directory.
This also repairs the exclusion on an
existing root. Failure stops that model's work. It does not remove backups
already made by Time Machine.

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
receipt, data and source-file identity when present, otherwise creates a private
staging directory and receipt. One model's ordinary failure is reported and
does not prevent later models from being attempted. Capture deferral or task
cancellation stops the entire batch and retries after the next idle grace
period. Ordinary failures retry only on the next App launch.
It walks paths through directory descriptors, opens sources with
no-follow flags, and calls `fclonefileat` (the descriptor-based `clonefile`
API) once per file. It does not call copyfile or provide a real-copy fallback.
Different devices fail before cloning; unsupported cloning, insufficient space
and any other clone failure retain the partial and diagnose an errno. Cloned
files are set to mode 0600; newly created directories use 0700.

After verification, the worker reopens the current bundled source and checks
every source identity again, checks root/parent/staging identity, and publishes
a new version with an exclusive same-parent atomic rename (`RENAME_EXCL`).
A recognized same-version cache from a different installation, or one whose
data fails verification, is instead replaced with `RENAME_SWAP`: the old version
remains published until the new clone has verified, then the two directories
exchange names in one kernel operation. Clone, verification, cross-device or
space failures before that exchange leave the old published version intact.
The worker rechecks the full destination binding after rename/sync before
reporting success. The receipt and directories are synced around publication.
On restart, only a correctly named, owned partial with a matching receipt is
renamed to `.retained-*`. Unknown files, symlinks, other versions and another
worker's locked data stay untouched. Once a verified current version exists,
recognized same-version retained caches are preflighted and directly released
with descriptor-relative `unlinkat`, without using Trash. Moving model bytes
to Trash would keep their data blocks referenced and defeat this space fix.
Only inventory-listed regular single-link files, their directories and a
valid owned preclone receipt may be released; its read is bound to a stable
file snapshot, checked during preflight and again after each gate checkpoint
before removal. The whole tree must pass before
any removal. Unknown entries, symlinks, hard links, foreign owners and invalid
receipts preserve the complete retired directory and produce a diagnostic.
Different content versions remain available as agreed for the later model
manager; this cleanup does not inspect or remove them. These exceptional
retained directories can still hold model blocks and need a user-approved
model-management decision. It never deletes arbitrary user or course data.
Cleanup checks the recording gate and destination bindings throughout; a
deferral can leave a partly released cache for the next idle retry.

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
the source inventory SHA-256, `verification: "sampledPrecloneV1"`, and optional
`sourceFiles` and `clonedFiles` identities (device, inode, size, birth time,
modification time and change time, keyed by inventory-relative file path).
Source identities are checked against the actual opened file before each
clone; completed identities are recorded after cloning and checked again
before publication. Target identities detect copied/replaced or modified
cache files even when their sampled bytes are unchanged. Change time catches
an in-place source rewrite that restores its old modification time.
No absolute App path is persisted.
These local identities are not part of the signed portable inventory.
A newer
App inventory may change because a different model changed; an unchanged model
version is reused only after checking its files against the current inventory
and comparing every stored source and target identity to the current files.
Replacing or reinstalling a complete App with identical model contents
preserves the content version but changes those identities, forcing a fresh
clone from the current App. Legacy schema-1 receipts without identities are
refreshed once. An owned formal directory with a missing, malformed, foreign
or newer unsupported receipt is repaired by publishing a verified new clone
and preserving its entire old tree as retained data. Such a receipt is never
treated as ownership proof for release. Unsafe formal symlinks/foreign-owned
directories remain rejected. Later models still proceed after an error.

Sampling is **not** a complete authenticity check: same-size corruption outside
the sampled ranges can pass. APFS clones are independent files, not hard links;
later edits consume copy-on-write space. Cloning avoids an initial second
payload allocation, but metadata still needs space and keeping the clone can
retain blocks after the original App is replaced. Refreshing and releasing
the old cache prevents that normal same-version reinstall from retaining a
second old payload indefinitely. Source identity comparison is a conservative
reclone trigger, not a physical-extent query or proof of all shared blocks:
filesystem snapshots and other open references can delay actual reclamation,
and writable receipts cannot establish authenticity. There is no promise of
zero disk use or bounded wall time on a stalled filesystem.

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
runtime directory selection and user-requested different-version cleanup
belong to 0.3.1 and are not implemented here. Before 0.3.1 uses a cache as an
active runtime input, its model manager must coordinate refresh/cleanup with
that runtime; 0.3.0's direct release is safe to apply here because every loader
still reads the App bundle.

## Synchronizing a dependent small-update branch

The fixes are a single follow-up commit on `claude/preclone`. A dependent
`claude/smallupd` based on the original preclone commit should cherry-pick
that follow-up before creating its packages; do not cherry-pick the original
preclone commit again. Keep the changed storage implementation, its regression
tests and this contract together. Reconcile any model-manager changes with the
runtime coordination requirement above and rerun full Swift/Python validation
in that branch. This task does not merge, push or modify the dependent branch.
