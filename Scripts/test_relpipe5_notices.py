"""R5/R8 regressions using static text and synthetic notice files only.

Fixtures stay under the scoped notices output; no cleanup, native loading,
external process, network access or real model input preparation occurs.
"""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import uuid

from Scripts import model_prepare
from Scripts.privacy_package import PrivacyError

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "work/relpipe/relpipe5/notices/test-fixtures"
QWEN = tuple(i for i in model_prepare.REQUIRED_MODEL_FILES if i != model_prepare.PARAKEET)
ASR = "mlx-community/Qwen3-ASR-1.7B-4bit"
TRANSLATION = "mlx-community/Qwen3.5-4B-MLX-8bit"


def change(identifier, file, **extra):
    return {"model": identifier, "file": file, "action": "omitted-unused-loader-input", **extra}


class ModelNoticeTests(unittest.TestCase):
    def fixture(self):
        root = FIXTURES / (self._testMethodName + "-" + uuid.uuid4().hex)
        root.mkdir(parents=True)
        base, output = root / "base", root / "output"
        documents = {}
        for identifier in model_prepare.REQUIRED_MODEL_FILES:
            folder = base / identifier
            folder.mkdir(parents=True)
            files = [] if identifier == ASR else [change(identifier, ".gitattributes")]
            if identifier == TRANSLATION:
                files.append(change(identifier, "tokenizer_config.json", action="omitted-unused-metadata",
                                    sourceSHA256="1" * 64, preparedSHA256="2" * 64,
                                    reason="stale wording"))
            doc = {"model": identifier, "contributor": "Li", "date": "2026-10-11",
                   "changes": files,
                   "scope": "Parakeet's unused training tokenizer model and vocabulary are also omitted.",
                   "unchanged": "Weights and vocabulary data are unchanged."}
            (folder / "MODIFICATIONS.json").write_text(json.dumps(doc) + "\n")
            documents[identifier] = doc
        return base, output, documents

    def test_empty_asr_records_make_no_omission_claim(self):
        scope = model_prepare.modification_notice(ASR, [])['scope']
        self.assertIn("No model-file modifications are recorded", scope)
        self.assertNotIn("Omit", scope)
        self.assertNotIn("Parakeet", scope)

    def test_three_qwen_scopes_never_claim_parakeet_training_changes(self):
        for identifier in QWEN:
            with self.subTest(model=identifier):
                doc = model_prepare.modification_notice(identifier, [change(identifier, ".gitattributes")])
                self.assertNotIn("Parakeet", doc['scope'])
                self.assertNotIn("training tokenizer", doc['scope'])
                self.assertIn("retained inference vocabularies", doc['unchanged'])

    def test_parakeet_directory_only_does_not_claim_training_files_omitted(self):
        scope = model_prepare.modification_notice(model_prepare.PARAKEET,
                 [change(model_prepare.PARAKEET, "config.json")])['scope']
        self.assertIn("directory metadata", scope)
        self.assertNotIn("model and vocabulary", scope)

    def test_parakeet_both_recorded_training_inputs_are_named(self):
        scope = model_prepare.modification_notice(model_prepare.PARAKEET,
                 [change(model_prepare.PARAKEET, f) for f in ("tokenizer.model", "tokenizer.vocab")])['scope']
        self.assertIn("training tokenizer model and vocabulary", scope)
        self.assertNotIn("prompt-template", scope)

    def test_single_parakeet_training_input_does_not_claim_the_other(self):
        for filename, other in [("tokenizer.model", "vocabulary"), ("tokenizer.vocab", "model is omitted")]:
            with self.subTest(file=filename):
                scope = model_prepare.modification_notice(model_prepare.PARAKEET,
                         [change(model_prepare.PARAKEET, filename)])['scope']
                self.assertNotIn(other, scope)
                self.assertIn("omitted", scope)

    def test_repository_only_scope_does_not_claim_template_change(self):
        scope = model_prepare.modification_notice(TRANSLATION,
                 [change(TRANSLATION, ".gitattributes")])['scope']
        self.assertIn("repository", scope)
        self.assertNotIn("prompt-template", scope)

    def test_recorded_translation_template_has_prompt_reason(self):
        doc = model_prepare.modification_notice(TRANSLATION,
              [change(TRANSLATION, "tokenizer_config.json")])
        self.assertIn("translation prompt-template", doc['scope'])
        self.assertIn("constructs", doc['changes'][0]['reason'])

    def test_refresh_preserves_input_records_and_existing_hashes(self):
        base, output, documents = self.fixture()
        before = {p.relative_to(base).as_posix(): p.read_bytes() for p in base.rglob("*") if p.is_file()}
        model_prepare.refresh_notices(base, output)
        self.assertEqual(before, {p.relative_to(base).as_posix(): p.read_bytes() for p in base.rglob("*") if p.is_file()})
        self.assertEqual(len(list(output.rglob("MODIFICATIONS.json"))), len(documents))
        for identifier, old in documents.items():
            notice = json.loads((output / identifier / "MODIFICATIONS.json").read_text())
            self.assertEqual([c['file'] for c in notice['changes']], [c['file'] for c in old['changes']])
            for left, right in zip(old['changes'], notice['changes'], strict=True):
                for key in ("file", "action", "sourceSHA256", "preparedSHA256"):
                    self.assertEqual(left.get(key), right.get(key))
            self.assertNotIn("Parakeet", notice['scope'])
        self.assertFalse(any(output.rglob("*.safetensors")))

    def test_refresh_cli_uses_only_existing_notices(self):
        base, output, _ = self.fixture()
        stream = io.StringIO()
        argv = ['model_prepare.py', '--notices-from-models', str(base), '--output', str(output)]
        with patch.object(sys, 'argv', argv), patch.object(model_prepare, 'prepare', side_effect=AssertionError('weights preparation forbidden')), contextlib.redirect_stdout(stream):
            result = model_prepare.main()
        self.assertEqual(result, 0)
        report = json.loads(stream.getvalue())
        self.assertEqual(report['modelNotices'], 'refreshed')
        self.assertEqual(report['models'], 4)
        self.assertFalse(report['modelHashesReverified'])

    def test_refresh_missing_notice_fails_before_creating_output(self):
        base, output, _ = self.fixture()
        missing = base / ASR / "MODIFICATIONS.json"
        missing.rename(missing.with_name("synthetic-notice-retained.json"))
        with self.assertRaisesRegex(PrivacyError, 'invalid-model-modification-notice'):
            model_prepare.refresh_notices(base, output)
        self.assertFalse(output.exists())

    def test_refresh_mismatched_model_identity_is_rejected(self):
        base, output, documents = self.fixture()
        doc = copy.deepcopy(documents[ASR])
        doc['model'] = model_prepare.PARAKEET
        (base / ASR / 'MODIFICATIONS.json').write_text(json.dumps(doc))
        with self.assertRaisesRegex(PrivacyError, 'invalid-model-modification-notice'):
            model_prepare.refresh_notices(base, output)
        self.assertFalse(output.exists())

    def test_refresh_symlink_notice_is_rejected(self):
        base, output, _ = self.fixture()
        notice = base / ASR / 'MODIFICATIONS.json'
        saved = notice.with_name('retained-original.json')
        notice.rename(saved)
        notice.symlink_to(saved.name)
        with self.assertRaisesRegex(PrivacyError, 'invalid-model-modification-notice'):
            model_prepare.refresh_notices(base, output)
        self.assertFalse(output.exists())

    def test_refresh_existing_output_is_not_overwritten(self):
        base, output, _ = self.fixture()
        output.mkdir()
        marker = output / 'marker'
        marker.write_text('preserve')
        with self.assertRaisesRegex(PrivacyError, 'invalid-model-preparation-path'):
            model_prepare.refresh_notices(base, output)
        self.assertEqual(marker.read_text(), 'preserve')

    def test_refresh_overlapping_model_tree_is_rejected(self):
        base, _, _ = self.fixture()
        with self.assertRaisesRegex(PrivacyError, 'overlapping-model-trees'):
            model_prepare.refresh_notices(base, base / 'output')

    def test_invalid_records_do_not_synthesize_a_notice(self):
        for records in [None, {}, [None], [{'file': 1}], [change(model_prepare.PARAKEET, '.git')]]:
            with self.subTest(records=records):
                with self.assertRaisesRegex(PrivacyError, 'invalid-model-modification-records'):
                    model_prepare.modification_notice(TRANSLATION, records)


class PackagingNoticeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.notice = (ROOT / 'Packaging/THIRD_PARTY_NOTICES.md').read_text()
        cls.provenance = json.loads((ROOT / 'Packaging/MLXLicenses/ASR-audio/soundfile-binary-provenance.json').read_text())

    def test_gcc_notice_describes_full_base_and_exact_darwin_patch(self):
        self.assertIn('complete GNU GCC 13.4.0 release', self.notice)
        self.assertIn('exact Homebrew Darwin patch', self.notice)
        self.assertNotIn('unrelated frontends', self.notice)
        self.assertNotIn('The selected GCC compiler/library sources', self.notice)

    def test_vocabulary_preservation_is_limited_to_retained_inference_data(self):
        self.assertIn('retained inference vocabularies', self.notice)
        self.assertIn('unused training tokenizer model and vocabulary', self.notice)
        self.assertNotIn('Weights and vocabulary data are unchanged', self.notice)

    def test_soundfile_statement_separates_static_equality_from_rebuild_and_trust(self):
        self.assertIn('11 file-backed sections', self.notice)
        self.assertIn('Whole-file exactMatch remains false', self.notice)
        self.assertIn('source rebuild', self.notice)
        self.assertIn('signer trust', self.notice)

    def test_repository_provenance_stays_pending_with_scoped_static_evidence(self):
        p = self.provenance
        self.assertEqual(p['status'], 'awaiting-input-and-final-binding')
        for key in ('inputSHA256', 'inputExactMatch', 'finalBundledSHA256', 'exactMatch', 'finalMatchesInput'):
            self.assertIsNone(p[key])
        evidence = p['publisherComparison']
        self.assertEqual(evidence['status'], 'reviewed-local-material-static-comparison')
        self.assertEqual(evidence['reviewedInputSHA256'], '6ef1f1c0a4ccbc72210ff55e3df6addc682f873e68aff3e7218e92ccc294da93')
        self.assertEqual(evidence['fileBackedSectionCount'], 11)
        self.assertTrue(evidence['allFileBackedSectionsEqual'])
        self.assertFalse(evidence['wholeFileExactMatch'])
        self.assertEqual(evidence['sourceRebuildExactMatch'], 'unverified')
        self.assertFalse(evidence['signerTrustVerified'])

    def test_changed_source_text_has_no_literal_home_root(self):
        forbidden = '/' + 'Users' + '/'
        for relative in ['Scripts/model_prepare.py', 'Scripts/test_relpipe5_notices.py',
                         'Packaging/THIRD_PARTY_NOTICES.md',
                         'Packaging/MLXLicenses/ASR-audio/soundfile-binary-provenance.json']:
            with self.subTest(file=relative):
                self.assertNotIn(forbidden, (ROOT / relative).read_text())


if __name__ == '__main__':
    unittest.main()
