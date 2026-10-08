# LiveLingo 0.3.0 User Guide

LiveLingo helps you follow a class with live captions, collect study notes, and review them alongside the recording afterwards. Transcription, translation, notes, and review advice can all contain mistakes. Check important points against the original speech and recording.

This guide covers the current development source. Features described here do not imply that an installed app or a published installer has been updated. Full-screen class mode is experimental and is not included in the current 0.2.0 download.

The app's controls are in Chinese. English names below explain their purpose; the Chinese labels in parentheses help you find them in the app. Some classroom text follows your chosen Chinese reading variant. [中文版](GUIDE.zh.md)

## Getting started and choosing where to save

After installation, open LiveLingo from Applications. It first checks the local models. If **Start recording (开始记录)** is unavailable, read the message at the bottom of the window and open **Status details (状态详情)**. If **Check models again (重新检查模型)** appears, use it to retry.

Open **More (更多) → Class settings (课堂设置…)**. Under **Recording and saving (录音与保存)**, check **Recording mode (记录方式)**. The default is **Save recording and notes (保存录音与笔记)**. Click **Choose save location (选择保存位置…)** and choose a folder for your classes. You can also choose it through **More → Save location (保存位置…)**.

Each recording creates a new course folder inside that location. You can click Start recording before choosing a location: the app will ask you to select one first. Cancelling that selection does not start audio capture.

**Temporary live session (实时暂存)** is useful when you only want to follow the current captions. It still writes a temporary recording to disk. On a normal end, the app deletes that recording and clears the session's contents. To keep the class, choose **More → Keep as a recording (转为录音…)** before ending and select a save location. Audio capture continues; the course is moved to that location when you end the session.

Under **Class settings → Subtitles and processing (字幕与处理) → Output language (输出语言)**, new recordings and imports offer:

| Output | Label in the app |
| --- | --- |
| Simplified Chinese | 简体中文 |
| Traditional Chinese, Taiwan | 繁體中文（中國台灣） |
| Traditional Chinese, Hong Kong and Macao | 繁體中文（中國港澳） |

English, Spanish, and French output are not yet enabled. The output choice applies to new recordings and imports, not to an existing course. For saved Chinese courses, the reading selector in **Recording processing (录音处理…)** can change the displayed Chinese variant when available. This does not retranslate the course or change its saved output language or exports. All three Chinese variants use a Simplified Chinese generation and archival draft; classroom display and exports apply the selected variant.

## Audio sources and permissions

Choose an **Audio source (音源)** in Class settings. You cannot change the source or recording mode while recording or paused. End the session before switching.

- **Microphone (麦克风)** records what the microphone hears, such as a lecturer speaking in a classroom.
- **System audio (系统内录)** captures audio playing on your Mac, such as an online class or video. It does not record the microphone. There is no control to select just one class app; audio from other apps may also be captured.

Allow microphone access when macOS first asks. If you previously denied it, enable LiveLingo under **System Settings → Privacy & Security → Microphone**, then start again.

System audio needs macOS recording permission. If capture fails, follow the prompt to enable LiveLingo under **System Settings → Privacy & Security → Screen & System Audio Recording**; the wording can differ by macOS version. Then start again. Although the permission mentions the screen, this capture path receives audio only and does not save screen video.

macOS may also request **Speech Recognition** permission for the optional English word-by-word preview. If that preview is unavailable, the bundled models can still produce the main transcript.

## Starting, pausing, and ending a session

Click Start recording at the top of the window. Once preparation and permissions are complete, the status becomes **Recording (录音中)**. The elapsed recording time and audio waveform appear above the classroom content.

Click **Pause (暂停)** to stop receiving new audio, then **Resume (继续)** to continue. Previously captured material may still be transcribed, translated, or turned into notes while capture is paused.

In Save recording and notes mode, click **End and save (结束并保存)** after class. This stops capture and saves the course, but remaining transcription, translation, and notes may still be processing. Check the status at the bottom: **Saved (已保存)** does not mean all processing is complete.

In Temporary live session mode, the button is **End session (结束记录)**. A normal end discards the session. Starting again after either mode creates a new recording.

The **Recording (录音)** menu offers the same actions. Use **⌘R** to start or end a session and **⌘⇧P** to pause or resume.

## Live captions and language labels

The **Bilingual transcript (双语转写)** panel shows recognized speech. English speech appears with the English transcript and a Chinese translation. Speech recognized as Chinese appears once, without a duplicate translation line. Other supported source languages retain their original text alongside a Chinese translation. Source-language recognition is separate from the output-language choices above.

Non-English segments have a small language label, such as Chinese (中文), Japanese (日语), or French (法语). The label describes the language recognized in that segment; English segments have no extra label. These labels are separate from the caption text and are not included when you copy or export captions.

The newest captions appear at the top. Turn off **Follow latest (跟随最新)** to read earlier material without new captions pulling you back to the top. Change the main window's text size through **More → Caption text size (字幕字号)**.

**Preliminary translation (同步初译)** lets you read an early Chinese translation while waiting for the main translation. The early text can change, so treat it as provisional. Enable it in Class settings on macOS 15 or later. macOS 14 does not offer this preview; the main translation still works.

## Floating subtitles

Click **Floating subtitles (浮动字幕)** at the top of the main window, or choose **Recording → Floating subtitles**, to open a separate subtitle panel. It starts hidden on each launch. Closing it does not end the recording.

In **Class settings → Floating subtitles (悬浮字幕)**, you can adjust:

- **Display mode (显示模式)**: bilingual (双语), Chinese translation only (仅中文译文), or original only (仅原文). Translation-only mode shows the original until a usable translation is available. Chinese speech still appears as a single Chinese caption.
- **Original text size (原文字号)** and **Translation text size (译文字号)**: adjust each independently. The panel also has Standard (标准), Large (大), and Extra large (特大) size presets in its upper-right corner.
- **Background opacity (背景不透明度)**: lower it to see the slides behind the panel.
- **Show on all desktops (在所有桌面显示)**: enabled by default for ordinary desktop Spaces. This setting alone does not guarantee subtitles over another app's native full-screen window.

Changing display mode keeps the panel's height unchanged, so hidden text areas may leave empty space.

Use the lock icon beside Floating subtitles in the main window to lock the panel. When locked, clicks pass through to the window behind it, and you cannot click the panel's own controls. To unlock it:

1. Click **Unlock floating subtitles (解锁浮动字幕)** using the lock icon in the main window.
2. In normal mode, choose **Recording → Unlock floating subtitles**. In full-screen class mode, use that action in the LiveLingo menu-bar icon's menu.
3. Press **⌘⇧L** while LiveLingo is the foreground app. This is an app shortcut, not a global shortcut.

The panel starts unlocked on each launch.

If it covers your slides or needs repositioning, choose **Recording → Move floating subtitles to the bottom of the screen (浮动字幕移到屏幕底部)**. This places it at the bottom centre of its screen and shows it. The full-screen mode menu-bar icon offers the same action.

## Full-screen class mode

This experimental mode is off by default and is absent from the current 0.2.0 download. To try subtitles over another app's native full-screen window, enable **Full-screen class mode (全屏网课模式)** under **Class settings → Floating subtitles**, or use the LiveLingo app menu. You still need to show Floating subtitles separately.

When enabled, LiveLingo's Dock icon and app menu bar disappear, and LiveLingo leaves the **⌘Tab** app switcher. Use the LiveLingo subtitle icon in the system menu bar instead. Its menu lets you show the main window, show or hide subtitles, lock or unlock them, move them to the bottom, start or end recording, disable the mode, or quit.

The mode forces subtitles onto all desktops. Turning it off restores the previous Show on all desktops preference and the normal app presentation. The mode's switch is remembered, so it may still be enabled on your next launch. Subtitle visibility and locking are not remembered: the panel still starts hidden and unlocked.

Coverage of other apps' full-screen windows is not guaranteed; check it with the class software you use. Subtitles may cover system menus or notifications. Use the menu-bar icon to move them to the bottom, hide them, or disable the mode if they get in the way. See the [full-screen mode notes and checklist](FULLSCREEN_CLASS_MODE.md) for more detail (in Chinese).

## Study notes and after-class review

As captions settle, the **Study notes (学习笔记)** panel automatically organizes the captured material. Notes sit beside the transcript in a wide window. In a narrow window, switch between **Captions (字幕)** and **Notes (笔记)**.

**Latest update (最近更新)** shows the most recently organized batch; **Whole-class notes (整课笔记)** shows the accumulated material. The information button beside the notes heading shows progress. Click **Update (更新)** to request another pass. Notes may wait when captions are backlogged or memory is under pressure.

Once the course is saved and has reviewable notes, click **Review notes (复查笔记…)**. Use the **Review (复查…)** menu to choose the whole class, the latest batch, or a specific batch. Review runs locally with the larger 9B model; the time needed depends on your Mac and the amount of material.

Results appear separately under **Review advice · Original notes retained (核对意见 · 正文已保留)**. Review does not automatically rewrite the notes. Use the advice as a prompt to check your understanding, and return to the recording and captions when something is uncertain.

**Manage queue (管理队列…)** lets you inspect review tasks, retry failed tasks, and change their order. With **Focus mode (专注模式)** enabled, recording and captions take priority and background review waits for idle time.

## Exporting and reopening a course

Click **Export (导出)** below Study notes. Choose Markdown, plain text, Word, or PDF, and select Latest update or Whole-class notes. Optionally include **Bilingual captions and timestamps (附带双语字幕与时间戳)** and **Review advice (附带核对意见)**, then click **Choose location and export (选择位置并导出…)**.

Included captions follow the selected notes scope. Included review advice consists of the saved reports for this recording, in a separate section; choosing Latest update does not restrict those reports to that one batch. Export reads the results already available and does not run a model to generate fresh notes. If the chosen scope has no notes, the app reports that it cannot export.

The course folder also contains the recording, transcript text, and subtitle files. Notes are saved there once generated. After ending a saved session, use **More → Show in Finder (在访达中显示)** to locate it. Keep the whole folder so that processing progress can be restored.

Later, choose **More → Open course (打开课程…)** or **File (文件) → Open course** and select the course folder. Opening a saved course does not record new audio. For unfinished work, open **More → Recording processing (录音处理…)** to inspect, pause, or resume processing.

Use a current build to reopen newer courses. The Chinese archival draft in `bilingual.jsonl` retains Simplified Chinese in the legacy caption fields. However, a course archive containing new language metadata requires a newer reader: 0.2.0 cannot read those archives. The 0.2.0 CLI also cannot verify Traditional Chinese exports. Preserving old fields is not a guarantee of full backward compatibility; reopening these courses in the 0.2.0 GUI or a VM has not been validated.

## Data and privacy

The main transcription, translation, notes, and review use local models. There is no app feature for uploading classroom recordings for cloud inference. Saved course folders and exports may contain speech from lecturers and classmates; check their contents before sharing.

Optional preliminary translation passes preview text to the macOS translation framework. The system manages its language resources and may need to download a language pack. Its internal communication and retention have not been verified by this project, so local model processing does not mean the entire app is always offline.

Temporary live sessions also write recordings to disk. The app removes them on a normal end; this is not a promise that no file was ever written. If cleanup fails, follow the message in the app.

Saving or exporting to a shared or synced folder also makes the contents subject to that service's access rules. Copying a translation puts it on the system clipboard, where other apps with access may read it; Universal Clipboard settings may allow it to reach other devices. See [Privacy boundaries](PRIVACY.md) for details in Chinese and English.

## Troubleshooting

### What if translation stops updating?

Open Status details at the bottom and check the audio source, speech recognition, and translation separately. If capture is paused, click Resume. If local models are not ready, use Check models again when offered. If only the early translation has stopped, turn off Preliminary translation and keep following the main captions.

When an individual segment has no completed translation, the original text is retained. Some failures are retried automatically. After class, open Recording processing and resume it if paused. If translations still do not recover, try Pause processing (暂停处理), then Resume processing (继续处理), to queue unfinished translations again. This processes previously captured audio; it cannot recover sound after capture stopped.

### What if notes fail or take a long time to update?

Check progress using the information button beside the notes heading. If notes are waiting for captions or memory, let caption processing catch up; existing notes are retained. If you see **This update failed (本轮更新失败)**, click Update to retry. If after-class processing is paused, resume it in Recording processing first. A retry can still fail. Keep the course folder, and do not assume blank or older notes cover the full class.

### What happens if disk space runs out?

Recording continuously writes to disk. Check available space at your chosen save location before class; temporary live sessions also need space. An audio write failure can stop recording. Failures to save course progress or exports are reported too, and the presence of some files does not establish that the whole class was saved.

Keep the existing course files, address the space problem, and follow the app's messages. If Recording processing offers **Retry saving course progress (重试保存课程进度)**, use it. Processing may remain paused after a successful save, so resume it separately. If recording has stopped, later sound was not captured. Starting again creates a new recording.

### Do I need an internet connection on first launch?

The main transcription, translation, and notes models in the complete offline installer do not need a model download. If a bundled model or runtime is missing, going online will not make the app fetch it automatically; check that your installation is complete.

The optional English word-by-word preview and Preliminary translation depend on macOS resources. During first-time translation preparation, the app asks macOS to prepare language resources. If the system requests a download, that step needs a connection. You can instead turn off Preliminary translation and wait for the local model's translation. If English preview resources are unavailable, the app falls back to stable captions.

### Why is processing still running after recording ends?

End and save stops capture and saves the current progress, then continues processing material already captured. You can pause this in Recording processing and resume it later. Any export made before processing finishes contains only the results available at that time.
