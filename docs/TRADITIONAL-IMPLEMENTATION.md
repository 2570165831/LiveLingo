# Traditional Chinese implementation (unreleased)

Scope: PLAN steps 4 and 8–12, based on `9014439`. That baseline already
contains later English/Spanish/French work, so the G0 source comparison uses
`9014439` rather than the earlier step 7 commit. Step 13 is excluded.
No model weights, GPU inference, real course data, account login, uploads,
signing or publishing are part of this work.

## Dictionary provenance and review boundary

- Source: <https://github.com/BYVoid/OpenCC/tree/ver.1.1.9>.
- Tag: `ver.1.1.9`; commit: `556ed22496d650bd0b13b6c163be9814637970ae`.
- Unmodified dictionary data: 1,050,497 bytes across seven source files.
- License: Apache-2.0. Original `LICENSE` is bundled. This tag has no root
  `NOTICE`; the bundled `NOTICE` explicitly identifies itself as a project
  attribution. [SOURCE.json](../LiveLingo/Resources/ZhVariants/SOURCE.json)
  and [third-party notices](../Packaging/THIRD_PARTY_NOTICES.md) record URLs
  and SHA-256 values for each copied upstream file.
- Upstream `TWPhrases.ocd2` is generated from `TWPhrasesIT`, `TWPhrasesName`
  and `TWPhrasesOther`; the original text sources are kept separate.
- Project reviewed phrases and subject overlays have **zero active mappings**.
  Commented examples and synthetic expected-answer columns are marked
  **待母語者審閱**. Passing upstream gold is an algorithm check, not native
  approval of academic terminology or permission to release.

## Provisional choices requiring user confirmation

`ChineseOutputDefaults` is the single policy location for these decisions:
classroom fixed text follows the regional rendering; `bilingual.jsonl` keeps
the Simplified generation draft; Chinese reading can switch without regenerating
content. Reading switches retain the immutable course/export target and are
available only for released choices. Already rendered legacy notes cannot switch
to another region without a Simplified draft. All three decisions are provisional.

## Verification evidence

Build/test scratch and logs use the one task directory `../work/dd-trad`,
including its `tmp` subdirectory. The Python gate environment follows
`../work/dd-tl1417/run-python-gates.sh`, with scratch relocated to `dd-trad`.
The source freezer, golden fixtures and all existing frozen digest values
remain the acceptance authorities. Full results are recorded below as each
step finishes; no unrun gate is considered passed.

The ten synthetic comparison rows are in
[cases.tsv](../Scripts/Fixtures/zh-variants-v1/cases.tsv). A local comparison
report records ICU, s2tw, s2tw plus the empty reviewed table, s2hk and s2twp.
ICU and s2tw differ on two rows. Accuracy is unknown until native review;
neither direction is called correct merely because it differs.

### Step 4

- Complete corrected Xcode run: XCTest 1150, one skipped, zero failures;
  Swift Testing 166. Warning checker: zero. Preference cleanup: 282 created,
  282 cleaned, no remaining registered plist. Log: `step4-fixed-xcode.log`.
- Python: 674 tests, six skipped, zero failures; Foundation-only Swift/Python
  probe parity passed. CLI multilingual: 20 groups; target review: six groups;
  lifecycle: 23 groups. The offline target-acceptance CLI accepted its authored
  Spanish probe; the quality CLI tests ran through the Python gate driver.
- G1: all bundled upstream s2tw/s2hk/s2twp answer bytes match in Swift and
  Python. Non-Han scalars and concurrent conversion checks passed. Cold-load
  and 500-line synthetic conversion timings are recorded by XCTest measure,
  without a performance acceptance threshold. Native terminology review is
  still pending.
- G8: the test App built with code signing disabled contains LICENSE/NOTICE; all eleven upstream
  file hashes and the project NOTICE hash match SOURCE.json. No DMG was made.
- Initial full run failed two new fixture-path tests because Xcode copied the
  folder using its actual basename, `zh-variants-v1`. The lookup was corrected;
  the subsequent full run above passed. The failed xcresult is retained.

### Step 8

- Added one-time background dictionary preparation, raw-draft caption and
  streaming rendering, preview/floating content rendering and bounded regional
  caching. Source lines, UI labels/placeholders, generation input and storage
  remain untouched. Traditional profiles remain unreleased.
- Full Xcode run: XCTest 1168, one skipped, zero failures; Swift Testing 166.
  Warning checker: zero. Preference cleanup: 296 created and cleaned, no
  remaining registered plist. Log: `step8-final-xcode.log`.
- Python: 674 tests, six skipped, zero failures. Multilingual CLI: 20 groups;
  target review: six groups. The frozen-source diff against `9014439` is empty.
- Eighteen new tests cover raw requests, regional content/source boundaries,
  Unicode spellings, cache limits/concurrency, missing resources, background
  completion and preservation of the stamped course target.
- A failed full run exposed a state-only failure being displayed as pending.
  The regional UI now retains the original UI failure wording; a creation
  fixture also now sets the real creation preference. Focused and full reruns
  passed. Failed build/test evidence remains in the task scratch directory.

### Step 9

- Added structural Markdown rendering for notes and review displays. Original
  and proposed review text both render; source evidence, including trailing
  whitespace and non-Han scalars, is preserved. Disclosure titles stay in the
  interface language. Classification always reads the Simplified Chinese draft.
- Schedule rows render only the target field. Frozen evidence disambiguates
  separators inside either field. Already rendered regional legacy summaries
  bypass conversion.
- Full final Xcode run: XCTest 1176, one skipped, zero failures; Swift Testing
  166. Warning checker: zero. Preference cleanup: 296 created and cleaned.
  Log: `step9-final-xcode.log`. Eight new Markdown tests passed.
- Python: 674 tests, six skipped, zero failures. Existing multilingual CLI:
  20 groups; target review: six groups. G0 frozen-source diff remains empty.

### Step 10

- Added regional transcript/SRT/summary exports, optional manifest converter
  version, and shared rendered fields for Markdown, text, Word and PDF notes.
  Original transcripts and JSONL generation drafts retain their original bytes.
  Source evidence and recording names are preserved; regional legacy summaries
  bypass a second conversion. Missing resources fail before export writes.
- Legacy review-report matching can compare a Simplified draft with the saved
  regional rendering. Bound snapshot validation remains unchanged.
- Full Xcode run: XCTest 1190, one skipped, zero failures; Swift Testing 166.
  Warning checker: zero. Preference cleanup: 296 created and cleaned, all
  registered plists absent. Log: `step10-xcode.log`.
- Fourteen new exporter tests passed, including extracted Word/PDF text and
  unchanged default manifests. The first focused run exposed an incorrect new
  expected spelling: upstream STPhrases maps `复查` to `複查`. The authored
  expectation was corrected; the final focused run passed all 36 tests.
- Python: 674 tests, six skipped, zero failures. Existing multilingual CLI:
  20 groups; target review: six groups. G0 frozen-source diff remains empty.

### Step 11

- Explicit CLI generation accepts `zh-Hant-TW` and `zh-Hant-HK`; GUI release
  flags remain false. Actual dictionaries are checked before generation state
  changes. The Latin release boundary is unchanged.
- Saved verification renders both the current format and historical regional
  two-line format. New English-only regional exports use converterVersion to
  distinguish their current layout. Missing dictionaries fail explicitly;
  a mismatched converter version or bound target is rejected.
- Actual CLI binary: 36 multilingual groups passed, including Taiwan/Hong Kong
  round trips, missing dictionaries, changed versions, legacy layouts, notes
  headings and bound run markers. Target review: six groups passed. CLI build
  warning checker: zero. Logs: `step11-final-multilingual.log` and
  `step11-final-target-review.log`.
- The shared preflight and caption tests passed all 20 focused tests. The first
  new test build attempted to call a CLI-only entry point from the App host;
  the production preflight was extracted and tested without generation.
- Fixed a CLI-player compiler warning by receiving CoreAudio's retained CFString
  through an unmanaged pointer. The player was compiled, never used for audio.
- Full Xcode run: XCTest 1192, one skipped, zero failures; Swift Testing 166.
  Warning checker: zero. Preference cleanup: 298 created and cleaned, all
  registered plists absent. Log: `step11-xcode.log`. Python: 674 tests, six
  skipped, zero failures. G0 frozen-source diff remains empty.

### Step 12

- Added an autonym selector for released creation targets, hidden while only
  one language is released and disabled during busy/import/archive work. Its
  preference applies only to the next course. Saved labels read the course stamp.
- Chinese reading overrides leave course snapshots, generation and export
  targets unchanged. They respect release flags, reset between courses and
  refuse a second conversion of legacy rendered notes. Evidence remains
  available for a stamped regional export even while reading Simplified Chinese.
- All eight new selector tests passed. The first focused run contained an
  incorrect new assertion after creating the next course: normal finalization
  changes the previous snapshot's state. The exact preference-change byte
  assertion remains; after finalization the prior target is checked separately.
  Log: `step12-fixed-focused-xcode.log`.
- Final Python gate: 674 tests, six skipped, zero failures. Final CLI checks:
  multilingual 36 groups; target review six; lifecycle 23; translation failure
  seven; process exit/restart 20. The quality CLI passed 44 assertions over ten
  synthetic fixtures with no real models; target acceptance accepted one
  authored Spanish row. Process tests use synthetic files and fake workers/ASR.
- Removed three lifecycle-test unused-return warnings with explicit discards;
  the original assertions are unchanged. Final CLI build warning checkers: zero.
- G1 final probe: all three upstream answer files are byte-identical in Swift
  and Python; ten synthetic rows agree between the two implementations. Native
  expected-answer review remains pending.
- G8 final test App: all 16 bundled files match the source; the eleven upstream
  file hashes and the project NOTICE match SOURCE.json. CODE_SIGNING_ALLOWED=NO
  was used; the linker adds an ad-hoc Mach-O signature. No Developer ID signing,
  sealed distribution bundle or DMG was produced.
- Full final Xcode run: XCTest 1200, one skipped, zero failures; Swift Testing
  166. Warning checker: zero. Preference cleanup: 306 created and cleaned, all
  registered plists absent. Log: `step12-xcode.log`. The frozen-source comparison
  against `9014439` remains empty, including the unchanged runtime directory.

## Artifact closeout

Six superseded CLI build folders were moved to
`../work/dd-trad/quarantine/obsolete-cli-steps8-11` after complete inventory,
path/volume checks, no-open-file checks and before/after content fingerprints.
They total 121,085,106 logical bytes and 121,421,824 allocated bytes. The move
is recoverable and on the same volume; it does not reclaim that space.
The final CLI, prior accepted CLI and source archive hashes remain unchanged.

The current test App, compatible build/module caches, final CLI entry points,
G1 probe and offline acceptance/quality CLIs are retained for the receiving
agent's acceptance. The step 11 final CLI is the immediate rollback; the step 4
CLI retains the original dictionary-integration evidence. Regenerable builds
can be retired after handoff acceptance. Per-step logs/xcresults and the exact
upstream archive remain provenance and acceptance evidence; they were not moved.
