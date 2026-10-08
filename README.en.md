# LiveLingo

[中文](README.md) | English

LiveLingo is an on-device caption and note-taking app for English-language classes. While you listen, it shows the English transcript and a Chinese translation, and builds study notes as the class goes on. Transcription, the full translation and notes run on your Mac with models bundled in the app, and no recordings are uploaded.

For Apple silicon Macs running macOS 14 or later. Open source, GPL-3.0.

The app's interface is currently in Chinese, and translations go from English into Chinese.

## What it does

- **Live bilingual captions**: takes English from the microphone or from system audio (useful for online classes and videos) and shows the English transcript with a Chinese translation. Captions can float above other windows, and you can pause and resume at any time.
- **Experimental full-screen class mode**: only in this development branch; the current download (0.2.0) does not include it. It tries to show subtitles over another app's native full-screen window. When enabled, the Dock icon disappears and you use the menu-bar icon instead. Off by default, and its behaviour still needs checking on real Macs; see the [guide](docs/GUIDE.en.md#full-screen-class-mode) and the [checklist](docs/FULLSCREEN_CLASS_MODE.md) (in Chinese).
- **Notes while you listen**: builds study notes during the class, showing the latest updates and the whole class separately.
- **After-class review**: once the recording ends, you can ask the larger 9B model to review the notes. Its comments are listed separately and do not change the original notes.
- **Save and export**: saves the recording, bilingual transcript and notes, and exports Markdown, plain text, Word and PDF. You can reopen an earlier class later to keep reading or continue processing it.
- **Formulas and names kept intact**: chemical formulas and names that are meant to stay as written are kept as written wherever possible, and calculations can be checked with tools.
- **Works offline**: the models for transcription, the full translation and notes are bundled in the app. No Python, no LM Studio, and no further model downloads. The optional instant draft translation and word-by-word English preview use features built into macOS, which may need a connection the first time; see [Known limitations](#known-limitations).

## Download

**[Download 0.2.0 (GitHub release page)](https://github.com/2570165831/LiveLingo/releases/tag/v0.2.0)**: download all 8 split files under Assets and merge them into one `.dmg` of about 14.3 GB, following the instructions on that page. A single split file cannot be installed, and the `Source code` archives at the bottom of the page are source code, not the installer.

**Keep your Mac online the first time you open the app.** This is macOS's own security check (Gatekeeper), not LiveLingo going online. The first time you open an app downloaded from the internet, macOS asks Apple to confirm that it was notarized, meaning it was submitted to Apple and scanned for malware. In 0.2.0 the notarization ticket is attached to the disk image but not to the app you drag into Applications, so macOS has to look it up online once; offline, it reports that the app cannot be verified and refuses to open it. After that first check no connection is needed. LiveLingo itself never uploads any recordings, text or usage data; transcription, the full translation and notes all run on your Mac.

**Requirements**

- **Computer**: Apple silicon Mac (M series). Intel Macs are not supported
- **System**: macOS 14 or later
- **Disk**: The disk image is about 14.3 GB and the installed app about 16 GB. Both are on disk during installation, so you need about 31 GB free (about 45 GB if you merge the split files). You can delete the disk image afterwards

## Getting started

1. Open the downloaded `.dmg` and drag **LiveLingo** into Applications.
2. Open LiveLingo from Applications and allow microphone, speech recognition and system audio recording when macOS asks.
3. Choose the audio source (microphone or system audio) and click “开始记录” (Start recording). Captions and notes will appear.

For details, see the [0.3.0 English user guide](docs/GUIDE.en.md): save locations, audio permissions, floating subtitles, full-screen class mode, note review, export and troubleshooting.

## Known limitations

- **Translations and notes can be wrong**: the models can skip or mistranslate sentences and get facts wrong in the notes. Check important points against the English transcript.
- **No instant draft translation on macOS 14**: this feature uses Apple's translation framework, which needs macOS 15 or later. On macOS 14 the Chinese appears once the full translation is done; the translation itself is not affected.
- **The instant draft translation may need a language download first**: it uses Apple's translation framework. If this Mac has never installed the English-to-Chinese translation languages, macOS may ask to download them the first time, which needs a connection; until then the draft translation is unavailable and the Chinese appears once the full translation is done. The full translation uses the models bundled in the app and is not affected. You can turn the draft translation (“同步初译”) off in Settings.
- **The word-by-word English preview needs system resources**: it uses the English speech recognition built into macOS. If no preview appears, open System Settings → Keyboard → Dictation, turn on Dictation, add “English (United States)”, and stay online while macOS downloads what it needs. The main transcription is not affected. See [Apple's dictation guide](https://support.apple.com/guide/mac-help/mh40584/mac).
- **Apple silicon only**: Intel and universal builds have not been made or tested. There is no Windows version; if you would like to help with one, see [issue #1](https://github.com/2570165831/LiveLingo/issues/1).
- **Large download**: the speech and translation models are inside the package, which is what lets the app work offline right after installation.

## Models

| Purpose | Model |
| --- | --- |
| English transcription | Parakeet TDT 0.6B v2; Qwen3-ASR 1.7B when the result looks wrong |
| Translation and notes | Qwen3.5 4B (“省电”, power saving) or Qwen3.5 9B (“高质量”, high quality); after-class review uses 9B |

The default is automatic: 4B on battery or with 16 GB of memory or less; 9B when plugged in with more than 16 GB. You can also choose manually in Settings.

The models run on your Mac through MLX. Output formats are constrained with Outlines, and clear-cut calculations are checked with Pint, SymPy and ChemPy. These reduce format errors but cannot guarantee the content is correct. For model sources and licenses, see the [third-party notices](Packaging/THIRD_PARTY_NOTICES.md).

## Data and privacy

Audio, transcripts, the full translation and notes are all processed on your Mac by the app. While the instant draft translation is on, the English it uses is handed to the translation framework built into macOS; that part is handled by the system, and this project has not verified what happens inside it. Recording mode saves the recording, bilingual text, captions and notes to a location you choose; live mode uses a temporary recording, which you can also save. The code has no cloud inference and no recording uploads.

When opening an issue or pull request, please do not attach private recordings, full class transcripts, notes or any credentials.

## Changelog and development

- What changed in each version: the [changelog](CHANGELOG.md) and the release notes for each version ([20260924](RELEASE_NOTES_20260924.md), [20260922](RELEASE_NOTES_20260922.md)). These are in Chinese.
- Building from source, assembling the models, signing and packaging: [docs/BUILDING.md](docs/BUILDING.md) (in Chinese). An app built from the Swift sources alone has no models and cannot work offline.
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) (in Chinese).

## License

The project's own code is licensed under **GPL-3.0-only** (see [LICENSE](LICENSE)). Commercial use and charging for it are allowed; if you distribute the program or a modified version, you must provide the source code as the license requires. The software is provided as is, without warranty. Third-party dependencies and models remain under their own licenses; their license texts and any required corresponding source are kept offline in [Packaging/MLXLicenses](Packaging/MLXLicenses/).

Official releases are planned to be free. This is the project's own distribution choice, not an added restriction on what other distributors may charge.
