LiveLingo 全离线安装包（Apple Silicon）
========================================

这份安装包包含：
- LiveLingo.app
- Parakeet TDT 0.6B v2（主转写）
- Qwen3-ASR 1.7B 4-bit（异常回退转写）
- Qwen3.5 4B MLX 8-bit（省电翻译）
- Qwen3.5 9B MLX 4-bit（高质量翻译，关闭思考）
- 便携 Python/MLX ASR 运行环境
- 官方未改动的 LM Studio 0.4.23-1 Apple Silicon 安装镜像

要求
----
- Apple Silicon Mac
- macOS 27.0 或更高版本
- 至少 20 GB 可用磁盘空间
- 16 GB 统一内存可以使用；长时间离电建议选“省电”（Parakeet + 4B），
  接电或更重视质量时选“高质量”（Parakeet + 9B）。模型按需加载，不会同时常驻。

安装
----
1. 双击“验证安装包.command”，等待全部项目显示 OK。
2. 双击“安装 LiveLingo.command”。脚本会再次校验后再改动本机。
3. 安装脚本会备份已有 LiveLingo 与 ASR 服务。已有同名模型若内容不同，
   安装会停止，不会覆盖。
4. 首次使用麦克风时允许麦克风权限；首次使用“系统音频（内录）”时允许
   屏幕与系统音频录制权限。LiveLingo 只读取系统音频，不保存画面。

运行方式
--------
- LM Studio 服务只监听 127.0.0.1:1234；翻译模型由 LiveLingo 按模式自动加载。
- ASR 服务只监听 127.0.0.1:18765。
- “实时”仍会写临时录音，停止时删除临时文件并清空历史；暂停不会清空。
- 实时过程中点“转为录音”并选择目录，停止后会把完整会话移入该目录。

安全与分发边界
--------------
- LiveLingo 使用 Developer ID 签名和 hardened runtime，但本次个人离线包未做
  Apple 公证。若另一台 Mac 的 Gatekeeper 阻止首次打开，请在 Finder 中右键
  LiveLingo 选择“打开”；不要关闭系统安全功能。
- 内含 LM Studio 官方原始安装镜像，只供本人设备离线迁移；不要公开再分发。
- 第三方模型和运行库的来源与许可证见 THIRD_PARTY_NOTICES.md。
