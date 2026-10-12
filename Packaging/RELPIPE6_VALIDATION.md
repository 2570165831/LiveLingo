# RELPIPE6 F4: separate signed-resource review

This change closes the preparation-index/signing-stage mismatch in review 4,
F4. It does not perform or certify Developer ID signing, notarization,
installation, runtime acceptance, VM acceptance or publication. All tests for
this change use host Python and static reads; no candidate interpreter,
extension, native executable or signing tool is run.

## Stage contract

The repository `Packaging/PrivacyResources.json` remains the preparation
approval index. Each signing run reads its current bytes and captures every
native resource approved as `macho-public-build-strings`, including its exact
preparation SHA-256, approval-record SHA-256 and reversible source layout.
There is no hardcoded index hash. Missing resources, changed hashes, changed
public string approvals and existing signed-stage receipts fail closed.

`Scripts/sign-offline-app.py` requires `--review-capture` for signing. This is an
absolute path to a **new host receipt outside the App**, in an existing log
directory. Capture happens before the first signing command. The host receipt
is created exclusively; existing receipts are preserved. If signing fails,
preserve this receipt and rebuild a prepared copy instead of overwriting the
receipt or treating partially signed bytes as the preparation baseline.

After inner signatures and final `signed-candidate` audio provenance binding,
`finalize_signed_review` creates the independent App receipt at
`Contents/Resources/LanguageRuntime/signed-resource-review.json`. It immediately
re-reads and validates that receipt. The complete `inspect_tree(phase="signed")`
gate then runs **before the outer App resource seal**. The outer main executable
is outside the resource approval index; its signing/entitlement checks retain
their existing responsibility. The receipt covers the fixed native resource
approvals, not every executable or an assertion of publisher trust.

`approvals_for_app(app_root)` is the integration API. It independently validates
the signed receipt and returns the current repository approvals with only the
reviewed native hashes replaced. The remaining fixed approvals and public
string/source identity fields remain intact. `--verify-only` also requires a
valid signed-stage receipt. `build-offline-dmg.sh` accepts an already signed App;
its signer must have supplied `--review-capture`. There is no signing call or
capture flag to inject into its existing verify-only path. Every original,
staged, resumed and final package privacy check selects `--phase signed`; the
mounted verifier receives `--privacy-phase signed`. Resume verifies the existing
receipt and signatures; it never re-captures or silently approves current bytes.

## What authenticates changed hashes

The App receipt cannot authorize unrelated code by rewriting its hashes. The
final reader reconstructs the original approved **complete file**, using the
current non-signature bytes plus the captured source header/signature bytes.
Its SHA-256 must equal the fixed repository preparation approval. It then
compares source and signed non-signature content exactly, including load-command
payloads, instruction/data sections, string tables and all other LINKEDIT data.
The original package/version/reason/public-string approval is authenticated by
its record hash. The whole-file scanner and strict portable-load gate run on
both source capture and signed output. Final audio provenance is independently
checked against the actual signed libsndfile and must say `signed-candidate`.

Only the following signing differences are excluded, with explicit validation:

- A single terminal `LC_CODE_SIGNATURE`, or its insertion into existing zero
  header padding; derived command count/size changes follow that exact command.
- The signature range must end at slice EOF, belong to a terminal, section-free
  `__LINKEDIT`, and overlap no other segment, section or referenced linker data.
  No arbitrary LINKEDIT bytes or file trailer are excluded.
- A SuperBlob with known slot magics, unique non-overlapping slots, bounded
  lengths and zero final gaps/reservation padding. Each final CodeDirectory
  covers every byte before the signature; every code-page hash is verified.
  Present requirements/entitlement slots must match their special-slot hashes.
  Scatter, pre-encryption hashes, unknown directory versions and linkage
  extensions fail closed. The packed runtime version is a supported field.
- LINKEDIT file size is derived from its exact EOF extent. Its VM size may retain
  the source value or round the new size to 4/16 KiB pages. Other segment fields
  cannot change. Fat slice offsets/sizes may relocate; architectures, alignment
  declarations and reserved fields remain fixed, and inter-slice gaps are zero.

Prepared inputs may contain stale upstream signatures after approved privacy
edits, and nonzero bytes in an old reserved signature area. These source bytes
are captured exactly and authenticated by the preparation **full-file** SHA;
they are not evidence of a valid source signature. The final output receives
the stricter page-hash and zero-padding checks above. CodeDirectory integrity
is not CMS/certificate trust, timestamp validity, Gatekeeper or signing-history
verification. The existing signature verifier still owns those release checks.

## Evidence and remaining gate

Evidence is under `work/relpipe/relpipe6/f4-signed-stage/`. The static reproduction
in `01-static-reproduction.json` shows the original hash rejection and missing
stage hooks. Test logs retain initial failures and corrected results. Tests
cover thin 32/64-bit and both endian forms, fat 32/64-bit containers, signing and
re-signing, incomplete/duplicate receipts, changed index/string approvals,
symlinks, forged headers/load commands/code/LINKEDIT and rehashed malicious
receipts. There are no fixture deletions.

The actual `relpipe5/candidate-final5` native files are read only by fixed index
paths, never executed or loaded. `09-actual-native-capture-final.json` records
the 46-resource capture and unsupported-shape report; the initial explicit-SHA
capture is `11-actual-before-sign.json`. The metadata-only update in
`15-index-binding-refresh.json` checks all 46 unchanged native approval records
and binds `15-before-sign-current-index.json` to that intermediate source-fixture
index. These are historical snapshots; later F1/F2/F3 approval changes require
a fresh capture against the final index. The final candidate's read-only capture
is recorded under `work/relpipe/relpipe6/final-verification/`, without signing or
writing a signed-stage receipt into the prepared App.
Earlier shape logs retain the initial parser failures. This proves preparation capture, not that
future codesign output satisfies final-stage constraints. Independent static
verification is recorded separately from the production comparator. Actual
Developer ID output, final App/DMG signing, mounted runtime acceptance and
publisher/CMS trust remain future authorized release work.

The F4-specific suite passes 42 tests (`13-tests-final.log`), including the parent
`signed` phase integration and signed audio-provenance stage. Run it with host
Python: `/opt/homebrew/bin/python3.13 -B -m unittest
Scripts.test_relpipe6_signed_resources -v` (one shell command). Independent
page-hash/non-signature comparisons are in `12-independent-verification.json`.
The command-construction mock in `Scripts/test-release-flow.py` supplies the
mandatory capture argument and asserts the capture, final review and signed
gate hooks. Its release fixtures keep the real metadata, entry and path checks;
only fake-signature native approvals and provenance are mocked. These fixtures
do not establish real signing or mounted-image acceptance.

## Whole-file and source-text coverage

Archive binary members now receive the same ASCII/UTF-16LE/UTF-16BE whole-file
private-root scan before dispatch to Mach-O, gettext or opaque formats. Native
and metadata policies share Windows home/UNC grammar; the binary scanner uses
distinctive home roots and valid UNC host/share operands to avoid interpreting
instruction bytes or regex flags as generic drive paths. Text metadata retains
its broader rejection of all drive-rooted paths.

File URI scanning parses arbitrary authorities and percent-decodes components
once, also checking overlapping URIs in lists. A concrete remote authority
requires review even for a system/share path. A complete pure formatting or
shell-variable authority names no host, while fixed prefixes/suffixes and
private decoded paths still fail. Approved local URI paths are neutralized
without inventing a hostname; approving a path never approves a remote host.

`file-url-hex` approvals bind complete URI spellings in ordinary source;
`binary-readable-hex` binds complete readable archive-binary strings. Both use
full resource/member hashes and review reasons; URI replacement cannot mask a
different host or longer URI. No directory, suffix, path-prefix or broad binary
fixture exemption was added. Public GCC fixtures were checked against retained
GNU archive bytes; additional runtime URI comments/examples were reviewed in
their retained source context. Current prepared resource approvals total 128;
the native-resource subset remains 46. Runtime/source-archive native bytes were
not changed for these approvals.

The assembler leaves an already-correct Numba OpenMP dependency untouched,
preserving its bytes and existing signature. The no-signing test mode sets
`LIVELINGO_TEST_DISABLE_SIGNING=1`; only the existing real ad-hoc fixture skips,
with an explicit reason. Default behavior of that test remains unchanged.
