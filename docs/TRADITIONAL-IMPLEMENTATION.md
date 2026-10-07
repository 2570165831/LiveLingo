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
- G8: the unsigned test App contains LICENSE/NOTICE; all eleven upstream
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
