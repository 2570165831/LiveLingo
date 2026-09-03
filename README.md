# LiveLingo

LiveLingo 是一个原生 macOS SwiftUI 应用：从麦克风或系统播放音频接收英语，使用本机 Parakeet 分段转写，在输出明显异常或主模型失败时回退到 Qwen3-ASR 1.7B，再调用 LM Studio 中的 Qwen3.5 将完整语段翻译为简体中文。

## 当前能力

- 英语先由 macOS 设备端流式识别逐词预览；每约 10 秒再由本机 Parakeet 完成稳定转写，并按原始顺序加入翻译队列。翻译只处理稳定语段，不阻塞逐词英文预览。
- 转写统一使用 Parakeet TDT 0.6B v2；检测到空结果、乱码、异常短句、重复循环、文本失控，或 Parakeet 请求失败时，自动用 Qwen3-ASR 1.7B 重转当前语段；非英文的回退结果会被拦截，不进入翻译。
- Parakeet 正常结果始终使用原始音频；只有空结果或异常结果的 Qwen 1.7B 回退会启用英语语音频段增强：保留原始波形，只额外提升约 120–7200 Hz，按该频段的活跃帧电平自适应增益，最多提升 12 dB，并在 −1 dBFS 限幅；静音不会被强行增益。
- 自动模式会在供电状态改变后切换下一语段使用的翻译模型，不中断当前录音：
  - 电池：Parakeet（异常回退 Qwen3-ASR 1.7B）→ Qwen3.5 4B（省电）
  - 接电：Parakeet（异常回退 Qwen3-ASR 1.7B）→ Qwen3.5 9B、关闭思考（高质量）
- 也可以在界面中锁定“省电”或“高质量”模式。
- “音频来源”可选择“麦克风”或“系统音频（内录）”。内录模式直接读取课程、会议或视频的系统播放声，不改变系统音量，并排除 LiveLingo 自身音频以避免回灌。
- “记录方式”可选择“录音”或“实时”。两种模式都会连续写入完整无损 PCM 录音；实时模式写入 LiveLingo 专属临时目录，不要求选择保存位置，运行时按最新在上、旧内容向下的顺序保留本次双语历史供回看。暂停/继续不会清空；停止时删除临时录音并清空历史。
- 实时录制期间可随时选择“转为录音”，随后选择保存目录。采集不会中断，停止且文件关闭后再将当前临时录音安全迁移到所选目录；同名会话不会被覆盖，迁移失败时保留临时源文件。
- 翻译提示词针对数学、物理、生物、计算机、经济与化学课堂调优；自动保护公式、变量、算法名、化学式、离子、电荷、实验单位和常见学术缩写，并把偶发的繁体结果统一为简体中文。高质量 9B 模式还会接收经过时间对齐和严格白名单过滤的系统转写 token 提示，仅用于公式、单位和学术缩写纠错；4B 模式不使用这组辅助提示。
- 录音期间写入无损 PCM `recording.wav`。
- 停止后在用户选择的目录中建立独立会话文件夹并导出：
  - `recording.wav`
  - `transcript-en.txt`
  - `transcript-zh-Hans.txt`
  - `bilingual.jsonl`
  - `bilingual.srt`
  - `summary-zh-Hans.md`（已有足够课堂内容时）
  - `manifest.json`
- 提供独立的浮动置顶字幕窗口。
- 双语历史按最新在上、旧内容向下排列，并提供暂停/继续按钮。
- 显示当前音频来源、当前供电状态、ASR 与翻译模型状态。

## 系统与硬件要求

- macOS 27.0 或更高版本。
- Xcode 27.0 或更高版本用于构建；当前本地验证使用 Xcode 27.0 Beta 4。
- 麦克风模式需要可用的麦克风输入设备；内录模式不需要麦克风。
- 当前只在 Apple 芯片 Mac 上验证；尚未验证 Intel 或 Universal 构建。
- LM Studio 本机服务，端口为 `127.0.0.1:1234`。
- Parakeet TDT 0.6B v2、Qwen3-ASR 1.7B MLX 模型与可运行 `mlx-audio` 的 Python 环境。

## 本机处理边界

应用只连接两个固定的回环地址：本机 ASR 服务 `127.0.0.1:18765` 和 LM Studio `127.0.0.1:1234`。仓库代码没有云 API、遥测或上传录音/转写的逻辑；录音和导出文件写入用户选择的本地目录。

模型下载与 LM Studio 自身的行为不属于上述应用代码边界。下载完模型后，LiveLingo 的转写与翻译链路可以完全在本机运行。

## 权限

首次开始对应音频来源时，macOS 会请求：

- 麦克风权限，用于麦克风模式。
- 屏幕与系统音频录制权限，用于系统音频内录模式；应用只消费音频样本，不保存画面。
- 用户所选文件夹的读写权限，用于保存会话文件。

Release 必须保留以下沙盒 entitlement：

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.network.client`（仅用于访问两个本机服务）

正式分发产物不得包含 `com.apple.security.get-task-allow`。不要对已经构建的 App 进行省略 entitlement 的临时重签；这会让系统麦克风权限看似已开启但应用仍无法使用。

## 首次运行

1. 在 LM Studio 中确认已下载 `qwen3.5-4b-mlx` 和 `qwen/qwen3.5-9b`，并启动本机服务（端口 `1234`）。LiveLingo 会按所选模式请求模型，LM Studio 可在首次请求时即时加载，无需让两个模型同时常驻内存。
2. 确认以下 ASR 模型目录存在：
   - `~/.lmstudio/models/mlx-community/parakeet-tdt-0.6b-v2`
   - `~/.lmstudio/models/mlx-community/Qwen3-ASR-1.7B-4bit`
3. 启动本机 ASR 服务：

   ```sh
   ./Scripts/run-qwen-service.sh
   ```

   如 Python 环境不在脚本默认位置，通过 `LIVELINGO_QWEN_PYTHON=/absolute/path/to/python` 指定。
   日常使用建议改为安装当前用户的自恢复服务；它只监听 `127.0.0.1:18765`，登录时启动，异常退出后由 `launchd` 自动重启：

   ```sh
   ./Scripts/install-qwen-service.sh
   ```

4. 用 Xcode 打开 `LiveLingo.xcodeproj`，选择 `LiveLingo` scheme 与 `My Mac` 后运行。
5. 选择“录音”后，首次开始会要求选择保存目录；选择“实时”则无需目录，停止时删除临时录音并清空历史。实时录制期间也可点“转为录音”选择目录并保留当前录音。选择“麦克风”或“系统音频（内录）”后首次开始，并允许对应权限。

## 构建与测试

不签名的 Debug 构建与测试：

```sh
xcodebuild -project LiveLingo.xcodeproj \
  -scheme LiveLingo \
  -configuration Debug \
  -derivedDataPath work/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project LiveLingo.xcodeproj \
  -scheme LiveLingo \
  -configuration Debug \
  -derivedDataPath work/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

可重复的 Release 构建：

```sh
./Scripts/build-release.sh
```

默认只生成未签名产物：`work/ReleaseDerivedData/Build/Products/Release/LiveLingo.app`。

需要 Developer ID 签名时，显式提供签名身份、与之匹配的公开证书文件和包含匹配私钥的钥匙串：

```sh
LIVELINGO_SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
LIVELINGO_CERTIFICATE_PATH="/absolute/path/to/developer-id.cer" \
LIVELINGO_KEYCHAIN_PATH="/absolute/path/to/login.keychain-db" \
./Scripts/build-release.sh
```

脚本先构建未签名 Release，再验证公开证书的有效期与 SHA-1 是否和钥匙串中的身份一致，随后使用 hardened runtime、可信时间戳和项目 entitlement 签名。最后执行严格签名校验，并确认四项必要 entitlement 存在且 `get-task-allow` 不存在。脚本不会安装或替换 `/Applications` 中的 App。

完整离线迁移包使用 `Scripts/build-offline-dmg.sh` 构建。它会纳入已签名 App、两个 ASR 模型、两个翻译模型、便携 MLX/Python 运行环境和官方未改动的 LM Studio 安装镜像；生成前后都会校验签名、模型文件和全包 SHA-256 清单。该产物面向本人 Apple Silicon Mac 之间迁移，不作为公开再分发包。

## 签名、公证与开源状态

- Developer ID 本地签名流程已纳入脚本；签名材料不属于仓库内容。
- Apple 公证尚未配置。未经公证的 Developer ID 构建在其他 Mac 上可能被 Gatekeeper 拒绝。
- 项目尚未选择开源许可证。没有许可证时，源码默认不授予他人复制、修改或再分发权利；公开发布前必须先补充许可证并复核仓库名、可见性和个人信息。

## 系统实时字幕的边界

macOS 自带“实时字幕”可以处理应用音频或麦克风，但通用麦克风模式不提供本项目的录音、英中语段配对以及双语 JSONL/SRT 导出工作流。
