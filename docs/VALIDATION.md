# 验证记录

## 2026-10-20：系统后台下载与仿真翻页

- 后台传输使用系统 `URLSessionConfiguration.background` 和下载代理；固定会话标识、启动时重连任务、AppDelegate 后台事件完成回调。队列按书籍/章节 ID 原子落盘；页面响应先保存到受保护、排除系统备份的暂存目录，前台通过原 Legado HTTP 桥解析，成功保存正文后才清理。
- 普通静态 GET 章节批量交给系统，后台会话每主机最多 2 个连接、队列最多 16 个在途任务。单个响应上限 8 MB、单本正文上限 100 MB、暂存总额上限 200 MB。任务与原始响应不会混入其他书源；请求身份包括源 ID、URL、方法、请求头与正文。
- 进入后台只中断 WebKit 解析，保留系统传输和队列；前台自动续接。用户暂停、停用/移除源或移除书籍会取消对应传输。动态请求、脚本库、认证 Cookie/头、限速、网页渲染等场景继续用前台运行时。后台响应失败或 HTTP 错误会回退原前台传输，避免重定向 Cookie 流程失效；新增真实 302 → Cookie → 200 测试验证此行为。
- 仿真翻页使用 UIKit `.pageCurl`，CoreText 按字体、行距和可用尺寸分页，支持点击、交互滑动、跨章、书签、纸色、夜间模式、重启恢复及横竖屏重排。分页测试覆盖中文、组合表情和组合字符，逐页校验实际可绘制范围与原文完整性；字号/尺寸变化保留文字锚点。
- **138 项不同的单元测试分批通过**：全量 `background-curl-final.xcresult` 中 137 项通过；最终 `background-curl-verified.xcresult` 中 12 项通过（新增 1 项重定向 Cookie 回退测试，其余为重跑），`background-http-regression.xcresult` 中 12 项 HTTP 回归通过。以上通过批次均无失败或跳过。
- **7 条界面流程通过**：全量 `background-curl-final.xcresult` 的 7 项全部通过，包括既有导入/搜索/离线恢复、脚本源登录/发现、更新目录/缓存/换源、书架与阅读流程，以及两条新增流程。最终两条新增流程在 `background-curl-verified.xcresult` 再次通过。
- 后台实测使用有延迟的本机章节接口：导入 7 章测试书 → 开始整书缓存 → 按 Home → 服务器确认所有章节完成传输且存在进入后台后完成的请求 → 将章节接口改为 503 → 返回应用 → 7 章全部缓存成功 → 离线阅读最后一章。断开章节接口后额外请求计数为 0。允许系统自身重试网络传输，测试按当次运行隔离统计。
- 初期禁用模拟器签名的测试包无法连接 `com.apple.nsurlsessiond`，返回 XPC 4097。恢复 Xcode 默认模拟器签名后真实系统下载测试通过；工程 Bundle ID、签名团队和发布配置均未修改。早期失败结果包保留作诊断，不计为通过。
- 最终 iPhone arm64 未签名构建通过，日志 `build/background-curl-iPhone-verified.log`。未新增第三方依赖；未安装或测试实体 iPhone。最低 iOS 16 和 iPad 未单独执行设备矩阵验证。
- 最终整屏视觉复验 `build/curl-screen-verification.xcresult` 通过，已目视确认横屏、竖屏和夜间正文没有拉伸或裁切。使用整屏截图避免 XCTest 的应用局部截图在旋转后错误裁剪。截图保存在 `docs/screenshots/yuedu-page-curl.png`、`yuedu-page-curl-night.png`、`yuedu-page-curl-landscape.png` 和 `yuedu-background-cache.png`。

后台执行仍由 iOS 调度；从多任务界面强制退出会中断传输，需重新打开后续接。已下载页面的完整书源解析需要前台，不能将此实现理解为任意脚本在后台无限运行。外部书源站点未因此新增逐站验证。

## 2026-10-20：在线书籍管理与阅读流程完善

以下为前一阶段记录；其中后台下载与翻页限制已由上节更新。

- 新增书籍详情入口（长按书架封面、阅读页右上角），支持目录更新、全书/后续 50 章顺序缓存、暂停与失败重试、同名书籍换源续读。新目录按唯一章节身份迁移进度和书签，保留正文；无法匹配时保留原数据。换源先确认章节，新旧版本分别留在书架。
- 目录新增章节名/序号检索、倒序、仅看缓存与定位当前章节。完整界面测试发现并修复了搜索层关闭后目录弹层未消失的问题；也修复了更新目录后返回阅读页，“下一章”按钮仍沿用旧目录状态的问题。
- 「我的」新增书架备份导出、文件恢复预览和合并恢复，以及单独导出书源配置。校验文件格式、版本、记录与书签引用；写盘成功后才发布恢复结果。重复恢复不重复添加书籍或书签，不回退已有进度；阅读统计不重复累加。
- **126 项不同的单元测试分批通过**：完整回归的 124 项通过；之后最终书籍工具套件 14 项通过，其中 12 项为重跑、2 项新增。覆盖目录插入后位置/书签迁移、无法匹配时原文件不变、顺序队列与范围、暂停取消、失败重试、已缓存章节跳过、磁盘恢复、重复恢复、书源 ID 冲突、重复标题和恢复写盘失败。
- **5 条不同的界面流程分批通过**：最终 `YueduPolish-ReaderFlow.xcresult` 的 3 条通过（新目录更新/缓存/搜索/换源完整流程，以及既有阅读器与四页面导航）；既有书源导入搜索离线恢复、混合源导入登录发现两条在 `YueduPolish-Integration.xcresult` 中通过。该早期结果包整体标记失败，原因是当时新增流程未通过，不能把它当作整包成功。
- 新完整流程使用 `scripts/demo_source_server.py` 的 `/polish-sources.json` 与可新增一章的目录 fixture：导入两个源 → 阅读并添加书签 → 更新 2 章为 3 章 → 返回阅读页检查下一章按钮 → 缓存全书 → 检索第二章并跳转 → 换源匹配第二章 → 停用两个源并重启 → 新版本缓存与原书签仍可阅读。通过结果包含截图，已目视检查书籍管理与换源后的阅读页面。
- 手动在专用 iPhone 17 Pro / iOS 26.5 模拟器验证：备份 6 本示例书到系统「文件」→ 重新选择文件 → 正确显示时间、6 本书、0 个书签 → 合并恢复成功，新增 0 本书、0 个书签（无重复）。恢复到空书架及实际书签还原由单元测试覆盖。
- 最终 `generic/platform=iOS` arm64 未签名构建通过。未修改 Bundle ID、签名团队、发布版本或最低系统要求，未安装到实体 iPhone。没有新增第三方依赖。
- 最终结果：`build/YueduPolish-ReaderFlow.xcresult`、`build/YueduPolish-BackupFinal.xcresult`；iPhone 构建日志 `build/YueduPolish-iPhoneFinal.log`。截图：`docs/screenshots/yuedu-book-management.png`、`yuedu-source-switch.png`、`yuedu-backup-restored.png`。

本轮网络验证仅使用本机原创测试内容，不代表真实外站已全部验证。缓存为前台任务，进入后台暂停，单本批量缓存上限 100 MB；备份上限 200 MB，书源配置单独导出，不包含登录/Cookie 与阅读偏好。跨站拆章/合章、云同步、后台下载、仿真翻页仍未实现。没有以这些改动宣称已达到 Legado 的全部功能。

## 2026-09-24：Legado 文字书源执行引擎

本节记录文字书源执行引擎阶段。后面的“391 条保存、382 条停用”等记录是先前阶段的历史结果，已由本次文字源引擎替代。

- 用户合集为 2,234,302 字节、391 项，SHA-256 `135282482326be10dade5c13422140590a43f00347fec000250caa2af994defa`。实际文件离线导入测试确认 **342 个文字源保留并启用、49 个非文字源排除、0 个结构错误、0 个因脚本类型而停用**。逐字段导出比对与重新打开存储均通过；导入不运行第三方脚本。
- 执行模块已支持 CSS / Jsoup 常用规则、XPath、JSONPath、正负索引/切片/排除、组合、变量模板、JavaScript 与尾随正则；请求支持 POST、GBK、动态头、Cookie、登录表单、网页渲染、脚本库和分页。系统框架提供摘要、加解密、图片像素、字体映射等接口，并适配合集使用的一组 Java / Android 风格对象。
- **112 项单元测试通过，0 失败、0 跳过**。其中规则 27 项、HTTP 12 项、原生工具 9 项、运行时 18 项、书源导入/持久化 27 项，以及本地书籍/书架/阅读偏好 19 项。
- 运行时回归覆盖同步网络桥、相对 URL 的 GBK POST、动态请求头、登录状态/缓存保存、搜索→分页目录→分页正文、变量跨阶段传递、无参请求重试、二进制 data URL、浏览器响应对象、动态网页、本体切换为非文字后的过滤、多行请求选项、目录顺序、详情页搜索回退和可选元数据失败。另验证连续两章写入的书籍变量不会被旧书架快照覆盖。无穷循环在 1 秒预算后结束，下一操作正常返回；原生等待期间取消也可返回。
- 原生工具用 NIST AES、DES 和 RFC 4231 HMAC 向量及独立 OpenSSL RSA fixture 验证；章节号转换、编码和位图像素测试通过。字体接口仅验证错误输入处理，未验证真实混淆字体的正文还原。
- **5,118 条静态规则烟测通过，0 解析异常、0 脚本钩子调用**。使用合成 HTML / JSON，排除脚本和模板。它只能证明这些样本未产生解析异常，不能证明命中真实网站内容。复现命令与脱敏报告见 [静态规则烟测](../scripts/LEGADO_RULE_SMOKE.md)。
- iPhone 17 Pro / iOS 26.5 专用模拟器单元测试已通过。最终 generic/platform=iOS arm64 未签名构建成功；Bundle ID、团队、发布配置未修改，没有安装到实体 iPhone。
- **2 项完整 UI 流程通过，0 失败、0 跳过**：网址导入→搜索→两章阅读→停用书源→重启后缓存复读，以及混合文字/脚本/漫画/无效项导入→明细报告→启用状态/原始字段重启保留→登录表单保存/动作执行→发现分类书目。两次完整界面运行均通过；截图已目视检查。
- 最后再次下载用户原始 HTTPS 链接：服务返回 480,931 字节 gzip 数据，解压后仍为 2,234,302 字节，SHA-256 与已测试文件完全一致。最终手动线上导入界面复核因 Mac 锁屏未执行；不以命令行下载替代该项 UI 验证。
- 最终 112 项单元结果包：`build/LegadoStateValidation.xcresult`，日志 `build/LegadoStateValidation.log`；2 项界面流程结果包：`build/LegadoReleaseValidation.xcresult`，日志 `build/LegadoReleaseValidation.log`；最终 iPhone 构建日志 `build/LegadoStateDevice.log`。前一轮界面截图已保存为 `docs/screenshots/legado-import-report.png`、`legado-source-settings.png` 和 `legado-explore.png`。

验证未批量执行合集里的第三方脚本，也未逐站访问 342 个书源的搜索、登录、目录和正文。远端脚本库、站点变更、真实反爬及账户权限仍需现场验证；现有结果不能宣称所有网站均可用。最低 iOS 16 与 iPad 未进行独立设备矩阵测试。编译保留了旧书源使用 MD5 的系统弃用提示，以及无 AppIntents 依赖的元数据提示。

## 2026-09-24：指定书源合集的兼容导入修复

- 实际下载用户提供的 `shuyuan.nyasama.net/shuyuan/cbbaa5456b27e41df047e242ffb6cb4f.json`：解压后 2,234,302 字节，共 391 条。文件本身未超出新的 50 MB 上限；旧导入器仍会因某一条含 Android 脚本或扩展规则而拒绝整个合集。
- 现在将配置保存与规则执行检查分开。391 条全部导入，0 条跳过；9 条通过当前规则检查，382 条暂不兼容并停用。规则检查不代表这些站点已联网验证，也不表示已实现完整 Legado 引擎。
- 对实际文件逐字段验证导出内容，除应用 ID / 启用状态外，原有字段、脚本及扩展配置均保留；关闭并重新创建书源存储后内容一致，再次导入仍是 391 条。验证摘要位于 `build/SourceImportInvestigation/verification.json`，第三方配置没有纳入测试资源。
- 新增常见 CSS 链、Legado class/id/tag 与索引、`@json:`、静态请求头、正则替换支持。脚本只作为数据保存，不会执行；Android Java 桥接、动态请求、POST 选项、分页、登录及其他未支持规则会列出原因。
- `SourceEngineTests` 13 项、`SourceCompatibilityTests` 11 项、`LegadoRuleTests` 9 项，合计 **33 项通过，0 失败**。覆盖混合批次报告、无效条目跳过、原始配置恢复、不兼容书源启用限制、规则删除、混合格式拒绝、CSS / JSON / 正则提取、请求头在完整加载流程中的传递以及下载边界与取消。
- iPhone 17 Pro / iOS 26.5 隔离模拟器构建与测试成功；generic/platform=iOS arm64 未签名构建成功。未修改 Bundle ID、签名团队或发布配置，未安装到实体 iPhone。
- 两项界面流程验证通过：本地测试服务导入→搜索→两章阅读→停用书源后重启恢复缓存，以及混合批次报告→查看逐项原因→禁用开关→重启后保留脚本与扩展字段。首次混合用例出现 XCTest 点击落点 `{-1,-1}`，该轮中断；增加可点击等待后独立重跑通过。报告截图见 `docs/screenshots/source-import-report.png`。
- 最后在同一隔离模拟器中手动输入用户原始 HTTPS 网址，实际走 URLSession 下载、后台解析、持久化和 UI 展示，弹窗确认「已导入 391 个书源」，显示 9 条规则受支持、382 条暂不兼容并停用。没有以本地替代地址冒充本次线上导入结果。
- 单元测试结果：`build/SourceCompatibilityTests.xcresult`；混合界面测试结果：`build/MixedSourceImportUITest.xcresult`；初次界面流程记录：`build/SourceCompatibilityUITests.xcresult`。日志：`build/source-compatibility-tests.log`、`build/source-compatibility-device.log`、`build/source-compatibility-ui.log`、`build/mixed-source-import-ui.log`。

## 2026-09-24：书源合集导入大小修复

- 网址下载、本地文件读取和 JSON 解析统一使用 50,000,000 字节上限；每批最多 10,000 个书源。普通书籍页面继续使用 8 MB 上限。
- 大合集在后台读取/解析，合并时使用网址索引；校验失败不会部分写入。超限错误保留其类型，并显示限制值与检测到的大小，不再误报为连接失败。
- `SourceEngineTests` 共 13 项通过，0 失败。包括超过 2 MB、201 个合法书源的模拟 URL 下载、异步导入、本地文件导入和持久化恢复；数量超限的原子性；已知/未知响应长度的边界；下载取消。
- iPhone 17 Pro / iOS 26.5 模拟器构建与 generic/platform=iOS arm64 未签名构建均成功。
- 结果包：`build/SourceImportFixTests.xcresult`；日志：`source-import-build-output.log`、`source-import-test-output.log`、`source-import-device-output.log`。
- 本次未收到截图中书源的完整网址，尚未对该线上合集实测。规则兼容范围未变。

## 2026-09-21：首版验证

日期：2026-09-21。环境：Xcode 26.6（17F113），iPhone 17 Pro 模拟器，iOS 26.5。最低部署目标为 iOS 16。

## 构建

| 目标 | 结果 |
| --- | --- |
| iPhone 模拟器 Debug | BUILD SUCCEEDED，安装并成功启动 |
| generic/platform=iOS，arm64 Debug | BUILD SUCCEEDED，CODE_SIGNING_ALLOWED=NO |

未连接或安装到实体 iPhone，未进行签名归档或 App Store 发布。真机运行需要用户在 Xcode 中配置自己的团队。

没有 Swift 编译错误或代码警告。Xcode 输出了无 AppIntents 依赖时跳过元数据提取的提示；模拟器测试中有系统 WebKit/调试器日志，但未造成测试失败。

## 自动化结果：29 项通过，0 失败，0 跳过

| 套件 | 数量 | 覆盖 |
| --- | ---: | --- |
| BookImporterTests | 11 | TXT 编码、章节、大文本、EPUB 解压/顺序/DRM/XML/异常文件 |
| LibraryStoreTests | 5 | 进度与书签持久化、去重、移除、边界、坏文件保留、初始化通知 |
| ReaderTests | 3 | 偏好持久化与无效配置回退 |
| SourceEngineTests | 7 | JSONPath、CSS、脚本不执行、请求错误、导入与稳定 ID、搜索/目录/正文 |
| YueduUITests | 2 | 章节切换、书签、设置页、重启恢复、书架搜索、四个主页面 |
| SourceFlowUITests | 1 | 真实 localhost 服务导入、搜索、两章下载、停用书源后重启恢复缓存 |

本次源服务以 `python3 scripts/demo_source_server.py` 启动，端到端测试实际执行，没有跳过或替换为假结果。

最终视觉检查后调整了宋体字体名称与重复空行的排版，再次完成模拟器构建及 3 项 ReaderTests，全部通过（`build/TypographyTests.xcresult`）。

结果包：`build/FinalTests.xcresult`。构建日志：`build-output.log`、`device-output.log`。最终测试日志：`final-test-output.log`。这些生成物被 `.gitignore` 排除。

## 运行检查

- 首次启动、空书源状态、书架和原生阅读界面已检查。
- 修复首次启动期间通知导致单例重入的问题，并新增回归测试。
- 修复目录/设置弹层关闭、夜间状态栏、跨页面导入呈现和本地空章节处理。
- 应用截图保存在 `docs/screenshots/`，来自实际模拟器运行。

完整网络测试以本地测试书源为边界；未验证所有第三方 Legado 书源。系统语音功能已经实现，但未逐一验证设备上可用的语音包。最低版本 iOS 16 与 iPad 未分别执行设备矩阵测试。
