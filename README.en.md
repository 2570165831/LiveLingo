# LiveLingo

[中文](README.md) | English

LiveLingo is an on-device caption and note-taking app for classes. While you listen, it shows the original speech with a Chinese translation and builds study notes. English and other supported source languages get a translation; Chinese speech appears directly as Chinese. Transcription, the full translation and notes run on your Mac with models bundled in the app, and no recordings are uploaded.

For Apple silicon Macs running macOS 14 or later. Open source, GPL-3.0.

The app's menus and buttons are in Simplified Chinese. In 0.3.0, **More (更多) → Class settings (课堂设置…) → Subtitles and processing (字幕与处理) → Output language (输出语言)** offers Simplified Chinese (简体中文, the default), Taiwan Traditional Chinese (繁體中文（中國台灣）), and Hong Kong and Macao Traditional Chinese (繁體中文（中國港澳）). The choice applies only to new recordings and imports. English, Spanish, and French output are not enabled.

Saved Chinese courses may offer **Reading text (阅读文字)** in **Recording processing (录音处理…)** to switch the displayed Chinese variant. Saving and export keep the course's original language. Traditional Chinese terminology has been reviewed by a language model; this is not native-speaker certification or real-class accuracy data. See the [terminology notes](docs/CHINESE_TERMINOLOGY.md) (in Chinese).

## What it does

- **Live bilingual captions**: takes sound from the microphone or system audio (useful for online classes and videos). English and other supported languages retain the original with a Chinese translation; Chinese speech appears once. Non-English segments have language labels. If Chinese is mistaken for English, choose “按中文重新识别” (Recognize again as Chinese) for that caption.
- **Floating subtitles**: lock them to let clicks pass through, adjust the original and translation text sizes and background opacity separately, and move them to the top or bottom of the screen. Reading size also has shortcuts: ⌘= / ⌘- / ⌘0.
- **Experimental full-screen class mode**: tries to show subtitles over another app's native full-screen window. When enabled, the Dock icon disappears and you use the menu-bar icon instead. Off by default, and its behaviour still needs checking on real Macs; see the [guide](docs/GUIDE.en.md#full-screen-class-mode) and the [checklist](docs/FULLSCREEN_CLASS_MODE.md) (in Chinese).
- **Recording alerts and saving**: sustained alarms can trigger an alert during microphone recording; saved-recording mode can save the class and start another recording automatically. ⌘Q asks for confirmation while recording, paused, or importing. An unfinished conversion from a temporary session to a recording can be recovered under the conditions in the user guide.
- **Notes while you listen**: builds study notes during the class, showing the latest updates and the whole class separately.
- **After-class review**: once the recording ends, you can ask the larger 9B model to review the notes. Its comments are listed separately and do not change the original notes.
- **Save and export**: saves the recording, bilingual transcript and notes, and exports Markdown, plain text, Word and PDF. You can reopen an earlier class later to keep reading or continue processing it.
- **Formulas and names kept intact**: chemical formulas and names that are meant to stay as written are kept as written wherever possible, and calculations can be checked with tools.
- **Works offline**: the models for transcription, the full translation and notes are bundled in the app. No Python, no LM Studio, and no further model downloads. The optional instant draft translation and word-by-word English preview use features built into macOS, which may need a connection the first time; see [Known limitations](#known-limitations).

## Download

**[Download the complete 0.3.0 disk image (Google Drive)](https://drive.google.com/file/d/10gwNMQlRPbeWryFTJNDpB1C9LcmB1Aur/view)**: `.dmg` about 14.2 GB (14,154,048,320 bytes), SHA-256: `1569a644522079237677a91d0fb63ea157d8212214958f3f9a2fd2406805973a`.

See the [0.3.0 release page](https://github.com/2570165831/LiveLingo/releases/tag/v0.3.0) for downloads and verification instructions. If it offers split files, download and merge all parts as instructed there. A single part cannot be installed. The `Source code` archives are source code, not the installer.

**You do not need an internet connection the first time you open LiveLingo.** Apple's notarization ticket is stapled to both the app and the disk image, so macOS can complete its security check offline. Optional system language resources may still need downloading; see Known limitations.


**Requirements**

- **Computer**: Apple silicon Mac (M series). Intel Macs are not supported
- **System**: macOS 14 or later
- **Disk**: disk image about 14.2 GB, installed app about 16.3 GB; both are on disk during installation, so you need about 31 GB free (about 45 GB if you merge split files). You can delete the disk image afterwards

## Getting started

1. Open the downloaded `.dmg` and drag **LiveLingo** into Applications.
2. Open LiveLingo from Applications and wait for the local models to be ready. In “更多 → 课堂设置…” (More → Class settings), choose the audio source and Chinese output language. Save recording and notes is the default mode.
3. Click “开始记录” (Start recording), choose a course save location, and allow access to the selected audio source when asked. Captions and notes appear as the class progresses; afterwards, click “结束并保存” (End and save). Speech Recognition permission is for the optional word-by-word English preview.

For details, see the [0.3.0 English user guide](docs/GUIDE.en.md): save locations, audio permissions, floating subtitles, full-screen class mode, note review, export and troubleshooting.

## Known limitations

- **Recognition, translations, and notes can be wrong**: the models can misidentify languages, skip or mistranslate sentences, and get facts wrong in the notes. Check important points against the original and recording. There is no language-detection accuracy data from real classes yet.
- **No instant draft translation on macOS 14**: this feature uses Apple's translation framework, which needs macOS 15 or later. On macOS 14 the Chinese appears once the full translation is done; the translation itself is not affected. Floating captions show the finished translation of the last sentence when the speaker pauses.
- **The instant draft translation may need a language download first**: it uses Apple's translation framework. If this Mac has never installed the English-to-Chinese translation languages, macOS may ask to download them the first time, which needs a connection; until then the draft translation is unavailable and the Chinese appears once the full translation is done. The full translation uses the models bundled in the app and is not affected. You can turn the draft translation (“同步初译”) off in Settings.
- **The word-by-word English preview needs system resources**: it uses the English speech recognition built into macOS. If no preview appears, open System Settings → Keyboard → Dictation, turn on Dictation, add “English (United States)”, and stay online while macOS downloads what it needs. The main transcription is not affected. See [Apple's dictation guide](https://support.apple.com/guide/mac-help/mh40584/mac).
- **Apple silicon only**: Intel and universal builds have not been made or tested. There is no Windows version; if you would like to help with one, see [issue #1](https://github.com/2570165831/LiveLingo/issues/1).
- **Large download**: the speech and translation models are inside the package, which is what lets the app work offline right after installation.
- **Older versions may not open newer courses**: 0.2.0 may be unable to open courses recorded live in 0.3.0, courses with new content, or older courses processed further in 0.3.0. It leaves the original files untouched. End and save unfinished classes in the old version before upgrading; copy course folders if you may return to that version.
- **Alerts and floating subtitles still need real-Mac checks**: alarm alerts only work during microphone recording; missed-alarm and false-alarm rates have not been measured. Locked click-through, multiple displays, screen readers, and the new macOS 14 appearance have not been individually checked on real Macs. Full-screen class mode may cover system menus and notifications.
- **Word/PDF export limitations**: notes lose their bullet symbols but retain their text; use Markdown to keep lists. ⌘Q does not wait for note exports, so let the export finish before quitting.

## Models

| Purpose | Model |
| --- | --- |
| Speech transcription | Parakeet TDT 0.6B v2 for the first English pass; Qwen3-ASR 1.7B for repairs and other source languages |
| Translation and notes | Qwen3.5 4B (“省电”, power saving) or Qwen3.5 9B (“高质量”, high quality); after-class review uses 9B |

The default is automatic: 4B on battery or with 16 GB of memory or less; 9B when plugged in with more than 16 GB. You can also choose manually in Settings.

The models run on your Mac through MLX. Output formats are constrained with Outlines, and clear-cut calculations are checked with Pint, SymPy and ChemPy. These reduce format errors but cannot guarantee the content is correct. For model sources and licenses, see the [third-party notices](Packaging/THIRD_PARTY_NOTICES.md).

## Data and privacy

Audio, transcripts, the full translation and notes are all processed on your Mac by the app. While the instant draft translation is on, the English it uses is handed to the translation framework built into macOS; that part is handled by the system, and this project has not verified what happens inside it. Recording mode saves the recording, bilingual text, captions and notes to a location you choose; live mode uses a temporary recording, which you can also save. The code has no cloud inference and no recording uploads.

When opening an issue or pull request, please do not attach private recordings, full class transcripts, notes or any credentials.

## Feedback

Trouble installing, something not working, a bad translation, or an idea? Please get in touch:

- **QQ group: 970112064** (mostly Chinese-speaking; questions and tips are both welcome)
- **Email**: 2570165831@qq.com
- **GitHub**: [open an issue](https://github.com/2570165831/LiveLingo/issues)

It helps a lot to include your Mac model, memory, macOS version, LiveLingo version and what you were doing when the problem happened. Please do not send private recordings, full class transcripts, notes, passwords or keys.

## Changelog and development

- What changed in each version: the [changelog](CHANGELOG.md) and the release notes for each version ([20260924](RELEASE_NOTES_20260924.md), [20260922](RELEASE_NOTES_20260922.md)). These are in Chinese.
- Building from source, assembling the models, signing and packaging: [docs/BUILDING.md](docs/BUILDING.md) (in Chinese). An app built from the Swift sources alone has no models and cannot work offline.
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) (in Chinese).

## License

The project's own code is licensed under **GPL-3.0-only** (see [LICENSE](LICENSE)). Commercial use and charging for it are allowed; if you distribute the program or a modified version, you must provide the source code as the license requires. The software is provided as is, without warranty. Third-party dependencies and models remain under their own licenses; their license texts and any required corresponding source are kept offline in [Packaging/MLXLicenses](Packaging/MLXLicenses/).

Official releases are planned to be free. This is the project's own distribution choice, not an added restriction on what other distributors may charge.
