# LiveLingo 0.3.0 User Guide

LiveLingo helps you follow a class with live captions, collect study notes, and review them alongside the recording afterwards. Transcription, translation, notes, and review advice can all contain mistakes. Check important points against the original speech and recording.

This guide covers 0.3.0, including Simplified Chinese, Taiwan Traditional Chinese, and Hong Kong and Macao Traditional Chinese output. Full-screen class mode is experimental.

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

Simplified Chinese is the default. English, Spanish, and French output are not yet enabled. The output choice applies to new recordings and imports, not to an existing course. For saved Chinese courses, **Reading text (阅读文字)** in **Recording processing (录音处理…)** can change the displayed Chinese variant when available. This does not retranslate the course or change its saved output language or exports.

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

The **Recording (录音)** menu offers the same actions. Use **⌘R** to start or end a session and **⇧⌘P** to pause or resume.

**Prevent idle sleep while recording (录音期间防止空闲睡眠)** under **Class settings → Subtitles and processing** is on by default. It cannot prevent closing the lid, manual sleep, or power loss. System sleep ends capture and saves the material already received; after waking, start a new recording yourself.

## Quitting and recovering an unfinished recording

Pressing **⌘Q** while recording, paused, or importing asks for confirmation. Return keeps the current session or import going. Choose **Save and quit (保存并退出)** to finish and exit. During import, only the portion already imported is saved.

In Temporary live session mode, Save and quit converts the class into a recording, asking for a save location if needed. Cancelling folder selection or a failed save keeps the app open. **Quit without saving (退出不保存)** discards the temporary session instead.

The app waits for saving and cleanup before quitting. If they fail or saving makes no progress for about 15 seconds, **Saving or cleanup is unfinished (退出前的保存或清理未完成)** offers **Stay in the app (留在应用)** or **Quit anyway (仍要退出)**. Quitting anyway may leave saving unfinished. Shutdown, restart, and logout skip the initial question: saved-recording mode attempts to save directly, while a temporary live session is not automatically converted into a recording.

If a temporary live session was converted into a recording but the app quit unexpectedly before saving finished, **More → Recover unfinished recording (恢复未完成的录音)** lists available recoveries by time on the next launch. Recovery does not restart audio capture. Follow the message to check processing and saving. If the original folder is inaccessible, choose it again through Save location. If Recording processing offers Retry saving course progress, use it. Resume processing separately if it is paused and you want to process captions and notes. This is not a guarantee of recovery after every unexpected exit.

## Alarm alerts

Both **Detect alarms while recording (录音时检测警报声并提醒)** and **Save this class and start a new recording on an alarm (警报时自动保存本节并另开新录音)** under **Class settings → Alerts (提醒)** are on by default. Detection works only while recording from the microphone, not while paused, capturing system audio, or importing files.

A sustained alarm triggers an alert. In saved-recording mode, with automatic saving enabled, a 30-second countdown saves this class and starts another recording in the same location, with “· 警报后” (after alarm) added to its folder name. You can cancel during the countdown; pausing also cancels it. Temporary live sessions only show the alert and are not automatically saved or split. You can turn off automatic saving while keeping alerts on.

When floating subtitles are visible, the alert appears there. When they are hidden, it uses a system notification; macOS asks for notification permission the first time one is needed. Esc dismisses the alert while LiveLingo or the subtitle window has keyboard focus. Alerts may miss an alarm or trigger incorrectly. They do not replace fire safety equipment; follow on-site announcements and staff.

## Live captions and language labels

The **Bilingual transcript (双语转写)** panel shows recognized speech. English speech appears with the English transcript and a Chinese translation. Speech recognized as Chinese appears once, without a duplicate translation line. Other supported source languages retain their original text alongside a Chinese translation. Source-language recognition is separate from the output-language choices above.

Non-English segments have a small language label, such as Chinese (中文), Japanese (日语), or French (法语). The label describes the language recognized in that segment; English segments have no extra label. These labels are separate from the caption text and are not included when you copy or export captions.

Language detection is automatic. The app checks again when English recognition is unreliable or the preceding segment may be in another language. French, Spanish, and similar languages need two consecutive segments confirming the language; only the current segment switches. Chinese and some other languages can switch after one segment. Short phrases and sudden language changes may still be misidentified; a language label is not a guarantee of accuracy.

If Chinese speech was mistaken for English, hover over that caption and click “…” or right-click, then choose **Recognize again as Chinese (按中文重新识别)**. While recording or paused, this queues the request until the class has ended and live transcription has finished. You can choose **Cancel Chinese re-recognition (取消中文重识别)** while waiting or recognizing, and **Undo Chinese re-recognition (撤销中文重识别)** after completion. The complete audio for that caption must still be readable. This action is unavailable in Temporary live session mode; choose Keep as a recording first if you want to retain and correct it.

The newest captions appear at the top. Turn off **Follow latest (跟随最新)** to read earlier material without new captions pulling you back to the top. It keeps updating while you use another window. **More → Reading size (阅读字号)** and **Class settings → Reading size** offer Standard (标准, the default), Large (大), Extra large (特大), and Double (两倍). Captions, notes, timestamps, and formulas scale together; floating subtitles scale from their own text sizes. The **View (显示)** menu also offers **⌘=** to enlarge, **⌘-** to reduce, and **⌘0** to reset the size.

**Preliminary translation (同步初译)** lets you read an early Chinese translation while waiting for the main translation. The early text can change, so treat it as provisional. It is on by default, remembers your choice, and is under **Class settings → Subtitles and processing** on macOS 15 or later. macOS 14 does not offer this preview; the main translation still works.

## Floating subtitles

Click the **Floating subtitles (悬浮字幕)** icon at the top of the main window, or choose **Recording → Show floating subtitles (显示悬浮字幕)** (**⇧⌘F**), to open a separate subtitle panel. It starts hidden on each launch. **Show floating subtitles when recording starts (开始记录时自动显示悬浮字幕)** is off by default and can be enabled in settings. Closing the panel does not end the recording.

In **Class settings → Floating subtitles (悬浮字幕)**, you can adjust:

- **Display mode (显示模式)**: bilingual (双语, the default), Chinese translation only (仅中文译文), or original only (仅原文). Translation-only mode shows the original until a usable translation is available. Chinese speech still appears as a single Chinese caption. The panel's header also lets you change display mode and pause or resume recording.
- **Original text size (原文字号)** and **Translation text size (译文字号)**: adjust each independently. The panel also has Standard (标准), Large (大), and Extra large (特大) size presets in its upper-right corner.
- **Background opacity (背景不透明度)**: lower it to see the slides behind the panel.
- **Show on all desktops (在所有桌面显示)**: enabled by default for ordinary desktop Spaces. This setting alone does not guarantee subtitles over another app's native full-screen window.

Changing display mode keeps the panel's height unchanged, so hidden text areas may leave empty space. Clicking the unlocked panel leaves the slides or other app you were using in front.

Use the lock icon beside Floating subtitles in the main window to lock the panel. When locked, clicks pass through to the window behind it, and its normal controls cannot be clicked. The alarm alert's cancel button remains clickable. To unlock it:

1. Click **Unlock floating subtitles (解锁悬浮字幕)** using the lock icon in the main window.
2. Uncheck **Recording → Lock floating subtitles (锁定悬浮字幕)**, or uncheck that item in the LiveLingo menu-bar icon's menu if the icon is visible.
3. Press **⇧⌘L** while LiveLingo is the foreground app. This is an app shortcut, not a global shortcut.

The panel starts unlocked on each launch.

If it covers your slides or needs repositioning, choose **Recording → Move floating subtitles to the bottom of the screen (悬浮字幕移到屏幕底部)** or **Move floating subtitles to the top of the screen (悬浮字幕移到屏幕顶部)**. This centres it at that edge of its screen and shows it. You can also move it through the panel's **Size and position (字号与位置)** menu or the LiveLingo menu-bar icon. The panel remembers its previous position.

## Full-screen class mode

This experimental mode is off by default. To try subtitles over another app's native full-screen window, enable **Full-screen class mode (全屏网课模式)** under **Class settings → Floating subtitles**, or choose **Enable full-screen class mode (开启全屏网课模式)** in the LiveLingo app menu. You still need to show Floating subtitles separately.

When enabled, LiveLingo's Dock icon and app menu bar disappear, and LiveLingo leaves the **⌘Tab** app switcher. Use the LiveLingo subtitle icon in the system menu bar instead. Its menu lets you show the main window, show or hide subtitles, lock or unlock them, change display mode and position, pause or resume, start or end recording, disable the mode, or quit. In normal mode, **Show the LiveLingo icon in the menu bar (在菜单栏显示 LiveLingo 图标)** can be enabled separately; it is off by default.

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

To process an existing audio or video file, choose **More → Import audio or video (导入音频或视频…)**, also in the Recording menu (**⇧⌘I**), then choose the file and a course save location. Import does not change the original file. **Stop import (停止导入)** keeps the portion already imported.

0.2.0 may be unable to open courses recorded live in 0.3.0, courses containing new kinds of content, or older courses processed further in 0.3.0. It leaves the original files untouched. Copy your course folders before upgrading if you may return to an older version. Starting a recording after opening an old course creates a new class; it does not append audio to the old recording.

Word and PDF export currently lose notes' bullet symbols, but retain the text. Use Markdown if you need to preserve lists. **⌘Q** does not wait for note exports, so let the export finish before quitting.

## Data and privacy

The main transcription, translation, notes, and review use local models. There is no app feature for uploading classroom recordings for cloud inference. Saved course folders and exports may contain speech from lecturers and classmates; check their contents before sharing.

Optional preliminary translation passes preview text to the macOS translation framework. The system manages its language resources and may need to download a language pack. Its internal communication and retention have not been verified by this project, so local model processing does not mean the entire app is always offline.

Temporary live sessions also write recordings to disk. The app removes them on a normal end or quit, but files may remain after a force-quit or crash. This is not a promise that no file was ever written. If cleanup fails, follow the message in the app.

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

No. In 0.3.0 the notarization ticket is stapled to both the app and the disk image, so macOS can complete its security check offline the first time you open it (you will see “Verifying…” and then the usual prompt for an app downloaded from the internet).

The main transcription, translation, and notes models in the complete offline installer do not need a model download. If a bundled model or runtime is missing, going online will not make the app fetch it automatically; check that your installation is complete.

The optional English word-by-word preview and Preliminary translation depend on macOS resources. During first-time translation preparation, the app asks macOS to prepare language resources. If the system requests a download, that step needs a connection. You can instead turn off Preliminary translation and wait for the local model's translation. If English preview resources are unavailable, the app falls back to stable captions.

### Why is processing still running after recording ends?

End and save stops capture and saves the current progress, then continues processing material already captured. You can pause this in Recording processing and resume it later. Any export made before processing finishes contains only the results available at that time.

### Where can I report other problems?

Join QQ group **970112064**, email 2570165831@qq.com, or open an issue on [GitHub](https://github.com/2570165831/LiveLingo/issues). Please include your Mac model, memory, macOS version, LiveLingo version and what you were doing; do not attach private recordings, full class transcripts or notes.
