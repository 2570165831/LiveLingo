# macOS 14 启动期间的应用对象

SwiftUI 可以在 `NSApp` 尚不存在时初始化 `@StateObject`。App 的 delegate adaptor 排在状态对象声明之前，也不能证明此时应用对象已经建立。

0.3.0 的旧候选在 macOS 14.6.1 上升级启动时，`AppModelHolder` 进入全屏控制器的共享初始化；控制器立即读取 activation policy，环境闭包隐式解包 nil `NSApp`。匹配崩溃报告 UUID 的 arm64 二进制在该闭包中先加载 `NSApp`，再用 `cbz` 在零值时跳往 `brk #1`。两份报告均在这个分支的 trap 指令停止，接收者寄存器均为零。

## 初始化约定

- 全屏环境每次通过 provider 解析当前应用对象；不存在时，窗口列表为空、窗口引用为 nil、活动状态为 false、activation policy 暂按 regular。需要应用对象的变更操作返回失败或不操作。
- 不用 `NSApplication.shared` 抢先创建对象。控制器在 `applicationDidFinishLaunching` 中启动，先重新读取真实 policy，再应用保存的全屏模式。重复启动不覆盖用于退出恢复的原始 policy。
- `showMainWindow` 的取消隐藏操作通过同一环境执行，保持注入契约。

已审计 AppModelHolder、AppModel、字幕录音开始观察器、字幕窗共享控制器、模型预克隆控制器，以及其他 shared 和 StateObject 初始化路径。除上述全屏读取外，没有发现能由这些初始化路径触发的 nil NSApp 隐式解包。字幕窗原有初始隐藏状态读取已使用可选访问。文件选择、退出确认等用户动作中的读取不属于本次启动调用链。

## 回归方法

`FullScreenClassModeTests` 覆盖 nil provider 下环境和控制器的构造、connect、窗口快照，以及 provider 延迟就绪。真实输入与前台观察器在测试中注入，避免安装进程级监听器。另一用例让 policy 在构造后由 regular 变为 prohibited，确认启动同步、保存模式切到 accessory，以及退出恢复 prohibited；重复 start 不篡改原始值。

实际客机验证应使用保留旧版设置的升级基线，替换 App 后检查主窗口和新崩溃报告；确认签名变化的系统对话框之前，进程存活不能当作初始化成功。没有运行时或模型的启动测试不能代替离线功能、最终签名或发布包验收。
