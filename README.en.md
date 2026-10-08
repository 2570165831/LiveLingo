# LiveLingo

Live captions and study notes for English-language classes on your Mac. LiveLingo transcribes speech, translates it into Chinese, and builds notes as you listen. The main speech and language models run locally.

Designed for Apple silicon Macs running macOS 14 or later. Open source under GPL-3.0-only.

[中文](README.md) · [English user guide](docs/GUIDE.en.md)

## Chinese output options

The current development source offers **Simplified Chinese**, **Traditional Chinese for Taiwan**, and **Traditional Chinese for Hong Kong and Macao** for new recordings and imports. Their labels in the app are `简体中文`, `繁體中文（中國台灣）`, and `繁體中文（中國港澳）`. English, Spanish, and French output are not yet enabled. The app's controls are in Chinese.

All three Chinese variants share a Simplified Chinese generation and archival draft. Fixed classroom text follows the reading variant. Saved Chinese courses can switch their reading display when available; their original output choice still governs saving and exports. The `bilingual.jsonl` archive keeps the Simplified Chinese draft.

The snapshot payload still uses `schemaVersion: 1`, but archive envelopes and journal records containing new language metadata require a newer reader. The 0.2.0 reader can decode the legacy caption fields as Simplified Chinese; it cannot open archives with that newer reader requirement, and its CLI cannot verify Traditional Chinese exports. This is a source and file-format compatibility description, not validation in the 0.2.0 GUI or a VM.

The [Chinese terminology notes](docs/CHINESE_TERMINOLOGY.md) describe terminology sources, subject coverage, preserved text, and limitations (in Chinese). Availability in the source does not mean an installed app or published installer has been updated.

## Features

- **Live bilingual captions:** capture microphone or system audio, display the English transcript with a Chinese translation, and pause or resume capture. Supported non-English speech can retain its original text alongside Chinese output; Chinese speech is shown without a duplicate translation line. A separate floating subtitle panel is available.
- **Experimental full-screen class mode:** an optional development-branch feature, off by default and not included in the current 0.2.0 download. It attempts to show subtitles over another app's native full-screen window. Enabling it hides LiveLingo's Dock icon and app menu bar and removes it from ⌘Tab; use the menu-bar icon instead. Coverage depends on the app and macOS behaviour. See the [guide](docs/GUIDE.en.md#full-screen-class-mode) and [checklist](docs/FULLSCREEN_CLASS_MODE.md).
- **Study notes during class:** view the latest update separately from the accumulated whole-class notes.
- **After-class review:** manually request a local 9B model review of saved notes. Advice appears separately and does not automatically change the original notes.
- **Save and export:** keep the recording, captions, and notes; export notes as Markdown, plain text, Word, or PDF. Reopen saved courses to read them and continue unfinished processing.
- **Formula and name preservation:** the app tries to retain chemical formulas and explicitly protected names, with tools to check supported calculations. These checks do not guarantee that the content is correct.
- **Bundled local models:** the complete offline installer includes the models and runtimes for the main transcription, translation, notes, and review. You do not need to install Python or LM Studio separately, or download those models on first launch. Optional macOS previews have separate resource requirements, described below.

## Download and get started

Get the [complete offline installer on Google Drive](https://drive.google.com/file/d/11nM4jOR_lnf0seLDZg4L9Smt_sLtuO2Z/view?usp=sharing), or the split files linked from the [release page](https://github.com/2570165831/LiveLingo/releases/tag/v0.1.0%2B20260924.0014). Follow the release page's instructions to combine split files. GitHub's Source code archives are not app installers.

1. Open the downloaded `.dmg` and drag LiveLingo into Applications.
2. Open it from Applications. In **More (更多) → Class settings (课堂设置…)**, choose the audio source and recording mode. The default mode saves the recording and notes; choose a save location when prompted.
3. Click **Start recording (开始记录)** and grant the permissions requested for your chosen source. The optional English word-by-word preview may also request Speech Recognition permission.

The [0.3.0 English user guide](docs/GUIDE.en.md) explains save locations, permissions, floating subtitles, full-screen mode, note review, exports, and troubleshooting. It describes the development source; the downloaded app may not include newer features.

## Limitations

- **Models make mistakes.** Transcripts, translations, notes, and review advice can omit or misstate important points. Check against the original speech and recording.
- **Preliminary translation needs macOS 15 or later.** This optional preview uses Apple's translation framework. It is unavailable on macOS 14, where you wait for the main local translation instead.
- **macOS previews need system resources.** English word-by-word preview depends on the system's English speech resources. If unavailable, the app uses stable captions. Preliminary translation may need a system language-pack download; you can disable it and use the local models.
- **Full-screen mode is experimental.** Subtitles may cover menus or notifications, and display over every class app is not guaranteed. Move the panel to the bottom, hide it, or disable the mode if needed.
- **Saving is separate from finishing processing.** End and save stops capture and saves current progress while remaining work continues. Exports include the results available at the time of export.
- **Apple silicon is the supported platform.** Intel and Universal builds have not been validated. The complete installer is large because it bundles models and runtimes.

## Models

| Purpose | Model |
| --- | --- |
| Main English transcription | Parakeet TDT 0.6B v2, with Qwen3-ASR 1.7B as a fallback for abnormal results |
| Translation and study notes | Qwen3.5 4B in Energy saver (省电), or Qwen3.5 9B in High quality (高质量) |
| After-class review | Qwen3.5 9B |

The default **Automatic (自动)** setting selects 4B on battery power or with 16 GB of memory or less; it selects 9B on external power with more than 16 GB. You can choose a mode manually in settings.

Models run through MLX. Outlines constrains output formats, and Pint, SymPy, and ChemPy support checks of explicit calculations. These tools reduce some errors; they do not establish that a transcript or explanation is correct. See [third-party notices](Packaging/THIRD_PARTY_NOTICES.md) for model sources and licences.

## Data and privacy

Main transcription, translation, notes, and review are processed locally. The app has no feature for uploading recordings for cloud inference. Saved sessions keep audio, transcript text, subtitles, and notes in your chosen location. Temporary live sessions also write audio to disk; a normal end removes the temporary recording and clears the session. You can convert a temporary session into a saved recording before ending it.

Optional preliminary translation sends preview text to the macOS translation framework. macOS manages language-pack preparation and may require a download. This project has not verified the framework's internal communication or retention, so the whole app is not guaranteed to be offline in every configuration.

Shared or synced save locations follow their service's access rules. Copied translations go to the system clipboard and may be accessible to other apps or, depending on Universal Clipboard settings, other devices. Check recordings and exports before sharing. See [Privacy boundaries](docs/PRIVACY.md) in Chinese and English.

Do not attach private recordings, full classroom transcripts, notes, or credentials to issues or pull requests.

## Development and licence

- Changes: [changelog](CHANGELOG.md) and [release notes](RELEASE_NOTES_20260924.md).
- Building and packaging: [build guide](docs/BUILDING.md), in Chinese. Compiling the Swift app alone does not bundle the models needed for offline use.
- Contributing: [contribution guide](CONTRIBUTING.md).

Project-owned code is licensed under [GPL-3.0-only](LICENSE) and is provided without warranty. Third-party dependencies and models retain their own licences; see the notices and [bundled licence materials](Packaging/MLXLicenses/).
