# 复审修复记录

对应复审 F1–F8；修复基线为 a42a054。候选与最终测试回执在 work/relpipe/review2/，历史产物只移入 work/relpipe/superseded/。

- F1：六个生成配置文件共 88 个本机字段已重定位或移除。CPython 安装目录由模块位置计算；保留 ABI、版本与非本机编译选项。未用于推理的 Makefile/pkgconfig/venv 文件不进入运行库。普通支持文本扫描路径，Python 按 AST 常量及纯字面量拼接检查。原输入哈希未变。宿主 Python 3.13.3 配合副本验证过 sysconfig、NumPy dot 与 SciPy show_config；这不等于候选 3.13.7 的运行验收。
- F2：完整 GNU GCC 13.4.0 基准、精确 Homebrew Darwin 补丁和生产 bottle 配方随包提供。原包 125386 个文件全部保留；准备后有 125390 个成员、700250407 字节展开内容。36 份授权文本保持原始哈希。来源链以固定官方 bottle/wheel 的全部文件内容 section 相同为支持，属于来源归属推断；不能将版本字段或整 fork tag 直接等同于 wheel 源码。精确 publisher 补丁的 223 个成员中，221 个与 Darwin r0 tag 相同，两个 libgfortran Makefile 不同。完整基准加实际 publisher 补丁才是提供的源码定义。新版宿主映射补丁只用于当前构建检查。离线 native arm64 compiler、libgcc、libquadmath 和 libgfortran 实际构建通过；生成编译器先验签，再用于 runtime 配置。SDK 27、已安装依赖、两项 make jobs、非 bootstrap；历史 seed compiler、全部 superenv 参数和 bottle 字节复现未取得。
- F3：tar 原始固定字段、NUL 后填充及 PAX 扩展头检查；保留成员、类型、大小、展开和元数据限制。检查 Python/C/C++/Rust/JS/Go 等支持格式的解码字面量、拼接以及 shell ANSI-C 和 HTML 实体。公开源样例以成员路径、完整哈希和精确拼写批准，不能按文件夹或后缀放行。JSON 事件流逐对象严格解析；Go 摘要值按规范编码与宽度检查；源 XML 的构建变量不当作固定宿主目录，BOM 也必须保留结构与隐私检查。完整 GCC 真门禁通过，312 个非通用二进制夹具按成员哈希绑定；识别二进制格式不等于审阅其全部内容。
- F4：两份 scipy _fblas 的六条 Homebrew RPATH 已移除；原直接依赖保持。仅允许系统或 loader 相对加载位置；DLC/相对 install ID 例外不适用于依赖或 RPATH。libpython 的两个 install ID 保持相对形式。修改过的候选 Mach-O 全部只做静态检查，不能在重新签名和验签前加载；带 sandbox inherit 权限的候选解释器没有再直接运行。
- F5：上游、真实只读输入和最终候选的哈希分阶段记录。实际输入 SHA256 为 6ef1f1c0a4ccbc72210ff55e3df6addc682f873e68aff3e7218e92ccc294da93；与固定上游资产 e9fd4d76bc457dcfb956617e8d467df85087ce069747fccd78e1e702d8629c14 不同，inputExactMatch 为 false。最终候选必须在最后一次组装后绑定，并重读校验。仓库中的 null/pending 参考文件不能作为发布证据；后续签名或二进制修改需要重新绑定。
- F6：两项审计引用指向随包 source-preparation 目录，按实际 Licenses 基准解析。
- F7：Git/LFS 属性省略有独立真实原因。保留的推理词表、权重及授权保持原件；Parakeet 未使用的训练 tokenizer/vocabulary 省略有明确说明。
- F8：路径准备保留 HTML 实体边界，roff 使用正确注释。最终完整 GCC 的相应 HTML、roff 和 Info 保留原始字节；改变的八个文本成员有文件内日期说明，三个二进制夹具有各自相邻日期说明。

原任务未回退：LAME 的 Makefile.in 与 mpg123 man1 手册保留；四个静态 codec 对应源码仍在；七个音频源码支持实际离线重建 libsndfile，三份 Cargo 源码检查 manifest/library 入口，未执行 Cargo 构建。两套 tokenizers CSS 保留并哈希绑定，Python 补丁版本仍锁为 3.13.7。组装脚本 bundle-mlx-app.py 保持原始字节。

测试：Python 全套执行 1505 项，9 项跳过；之后最终源配置/字面量补验 48 项通过、定向集 204 项通过。跳过项涉及未提供的本地 tokenizer、历史审核材料/冻结 benchmark、CLI 和 Foundation 探针，不代表真实课堂或 GUI 通过。测试均使用合成数据；运行库只读输入与宿主可加载代码先验签，审计钩子阻止加载签名无效的扩展和候选 native 文件。宿主框架资源封印有单独限制，代码本体验签忽略资源封印；未将它写成整体框架封印通过。

候选最终门禁、大小、section 绑定和提交号以 work/relpipe/RECEIPT-review2.md 及 review2/delivery-verification.json 的实际收尾记录为准。尚未做候选启动、模型推理、VM、安装、公证或发布；没有推送。仅测试夹具使用 identity-free ad-hoc 签名，候选没有重新签名。
