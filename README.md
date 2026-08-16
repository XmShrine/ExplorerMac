<p align="center">
  <img src="screenshots/icon.png" width="128" alt="ExplorerMac">
</p>

<h1 align="center">ExplorerMac</h1>

<p align="center">在 macOS 上复刻 Windows 11 文件资源管理器的外观与交互</p>

原生 Swift + AppKit，不使用 Electron、WebView 或任何跨平台 UI 运行时。

这是 [FinderWin](../FinderWin)（把 macOS Finder 搬到 Windows）的反向工程。

![主页](screenshots/home.png)

<table>
  <tr>
    <td><img src="screenshots/dark.png" alt="深色主题"></td>
    <td><img src="screenshots/view-large-icons.png" alt="大图标视图"></td>
  </tr>
  <tr>
    <td align="center">深色主题</td>
    <td align="center">大图标视图</td>
  </tr>
  <tr>
    <td><img src="screenshots/view-tile.png" alt="平铺视图"></td>
    <td><img src="screenshots/view-content.png" alt="内容视图"></td>
  </tr>
  <tr>
    <td align="center">平铺视图</td>
    <td align="center">内容视图</td>
  </tr>
  <tr>
    <td><img src="screenshots/search.png" alt="搜索"></td>
    <td><img src="screenshots/properties-file.png" alt="属性对话框"></td>
  </tr>
  <tr>
    <td align="center">递归搜索，结果流式返回</td>
    <td align="center">属性对话框（刻意保留 Win32 的视觉语言）</td>
  </tr>
</table>

## 技术构成

| 层 | 实现 |
| --- | --- |
| 语言 | Swift 6.3，SwiftPM 构建，无 Xcode 工程 |
| UI 框架 | AppKit，控件全部子类化后用 CoreGraphics / CoreText 自绘 |
| 目录枚举 | `getattrlistbulk(2)` 批量系统调用 |
| 字体 | Segoe UI Variable + Segoe Fluent Icons + Microsoft YaHei UI |
| 图标 | `imageres.dll.mun` 提取的原始 `.ico` |
| 产物 | 单个通用二进制，无运行时依赖 |

不用 SwiftUI 的原因：`List` / `Table` 在十万行量级下不可用，且拿不到像素级控制权——Explorer 的行高、列头分隔线、选中态圆角都与其默认样式冲突。

不用 `NSMenu` 的原因：菜单**窗口**的圆角、背景材质与内边距归 AppKit 所有，即便每一项都换成自定义视图，整体仍然读作 macOS。Windows 的菜单是另一种形状（8pt 圆角对 macOS 明显更圆的角）、图标用强调色着色、右侧留出快捷键列、并在一侧带一条图标按钮条——这些都要求自己拥有那个窗口。

不用 `NSTableView` 的原因：详细信息视图的行是等高的，直接绘制可见行意味着零行视图对象；滚动十万条目录不产生任何分配，只重绘与脏矩形相交的约 30 行。Explorer 的行是内缩的圆角选中板，`NSTableView` 也画不出来。

## 性能

12 万个文件的目录（Apple Silicon，APFS）：

```
枚举    169 ms
过滤      3 ms
排序    223 ms
合计    395 ms
```

- `getattrlistbulk` 一次系统调用返回数千条目及其名称、类型、大小、时间戳和标志位，目录列表不需要任何 per-file `stat`。
- 枚举在后台队列进行，分批推送到主线程，首屏在一帧内出现，不等待遍历结束。
- 排序结果按节流重建，而不是每批数据到达就全量重排——后者会让大目录退化成平方复杂度。
- 自然排序在字符串的连续 UTF-8 缓冲区上比较。每次比较materialize 一个 `[UInt16]` 是最直觉的写法，但那会在单次大目录排序的约 200 万次比较中产生同等数量的堆分配，成为整个列表加载的主要开销。

## 已实现

- 窗口框架：标签页栏（多标签、各自独立的历史记录）、Win11 标题栏按钮 `─ □ ×`
- 地址栏：后退 / 前进 / 向上 / 刷新、面包屑（每段可点击，chevron 展开同级文件夹）、点击空白处切换为可编辑的 `C:\...` 路径输入、搜索框
- 命令栏：新建 / 剪切 / 复制 / 粘贴 / 重命名 / 共享 / 删除 / 排序 / 查看 / 更多，按选中状态启用禁用
- 导航栏：主页、六个库文件夹（带固定图钉）、此电脑及其下的驱动器，可展开
- 八种视图：超大 / 大 / 中等 / 小图标、列表、详细信息、平铺、内容，`Ctrl+Shift+1…8` 切换
- 详细信息视图：名称 / 修改日期 / 类型 / 大小四列，列宽可拖拽，点击列头排序，排序指示器绘制在标签正上方
- 选择模型：单击、Shift 连选、Cmd 多选、Cmd+A 全选、框选、方向键 / PageUp / PageDown / Home / End 导航
- 拖放：列表内、拖到导航栏的位置、与 Finder 及其他应用互拖，同卷移动 / 跨卷复制
- 状态栏：项目计数、选中计数与选中总大小
- 文件操作：剪切 / 复制 / 粘贴 / 删除 / 重命名 / 新建，含冲突对话框
- 右键菜单：列表项与空白处两套，自绘以匹配 Win11 的形状与排布
- 目录监听：FSEvents，外部改动实时反映（带防抖，且内容未变时完全不重绘）
- 撤销 / 重做：移动、复制、删除、重命名、新建都可回退，Ctrl+Z / Ctrl+Y
- 深浅色主题：跟随系统，两套 WinUI 令牌
- 状态持久化：窗口位置尺寸、导航栏宽度、列宽、排序、隐藏项目、视图模式、紧凑视图、上次位置
- 属性对话框：文件与文件夹，文件夹大小递归统计，可改名与只读/隐藏属性
- 缩略图：图片 / 视频 / PDF 走 Quick Look，异步生成、按内容哈希缓存
- 搜索：当前文件夹递归搜索，结果流式返回，类型列换为文件夹路径

### Windows 概念映射

| Windows | macOS 实现 |
| --- | --- |
| 盘符 | 启动卷固定为 `C:`，其余卷按挂载顺序取 `D:` 起 |
| 路径显示 | `C:\Users\xmshrine\Desktop`；地址栏同时接受 POSIX 与 Windows 两种写法 |
| 已知文件夹 | `~/Desktop` 显示为「桌面」等，使用 Windows 的本地化名称与图标 |
| 隐藏项目 | dotfile + `UF_HIDDEN` 标志 |
| 文件类型列 | 复刻注册表 ProgID 描述字符串，未知扩展名回退为 `XXX 文件` |
| 大小列 | 向上取整到整数 KB，千位分组，文件夹留空 |
| 排序 | 重新实现 `StrCmpLogicalW` |

### 视图模式

Explorer 的八种布局全部实现，图标尺寸沿用 Windows 的 256 / 96 / 48 / 16 阶梯。

三种排布方式：详细信息与内容按行铺满宽度；四种图标视图与平铺从左到右流动、到右边界换行；只有「列表」是从上到下流动、到下边界换列，因而也是唯一会横向滚动的视图。这三种排布的坐标计算集中在 `ListLayout` 一处——命中测试、键盘移动、框选和绘制都从这里读取矩形，因为「第 n 项在哪里」被推导三遍的下场，就是点中的格子和选中的格子对不上。

方向键的含义随排布改变：在网格里下键跨一整行，在「列表」里下键只走一项。图标视图的空白区域不响应点击而是起框选，这是 Explorer 的行为，也只有在命中区域收紧到图标加标签时才成立。

标签的换行需要「先折行再截断」，这要求段落样式用**折行**模式再配合 `.truncatesLastVisibleLine`；直接写 `.byTruncatingTail` 得到的是单行加省略号，完全不折行。选中项的标签会多显示一行，这样长文件名不必改名就能读全。

列头只属于详细信息视图，切换模式时随之出现或消失，把那条高度还给列表。

### 拖放

复制还是移动由**卷**决定，而不是由应用决定：同卷内拖动是移动，跨卷是复制，修饰键可以覆盖。这条规则是长在手上的，值得原样复刻，而不是继承 macOS「一律复制」的默认。修饰键上 Explorer 用 Ctrl（复制）和 Shift（移动），Mac 上对应 Option 与 Command，四个都接受。

拖到文件夹上落进该文件夹，拖到空白处落进当前文件夹，拖到导航栏的任意位置落进那个位置。Explorer 拒绝的几种落点这里同样拒绝：落回自己所在的文件夹（移动时无意义）、落到自己身上、落进自己的子目录——最后一种若放行会把正在移动的目录树删掉。

拖出的每一项各带自己的 pasteboard 条目和屏幕矩形，所以落点被拒时系统会把它们分别飞回原来的格子。拖动影像是单元格实际绘制结果的半透明副本，而不是另写一遍的近似画法——后者迟早会和真正的渲染器走偏。

落地后走的是和「粘贴」同一套机器：同样的冲突对话框，同样的撤销记录。

### 缩略图

只对能产出预览的类型请求 Quick Look，其余保持类型图标——这既更快，也是 Explorer 的行为。缓存键包含修改时间与大小，文件改动后自动重新生成；生成失败的键会被记住，避免每次滚动重试。请求在绘制过程中发出但从不等待，缩略图就位后只重绘那一行；导航到新目录会作废尚未完成的请求，否则快速翻阅一个上万张照片的文件夹会为早已滚出屏幕的行排队上万次生成。

### 搜索

后端是递归遍历而不是 Spotlight。Spotlight 是 Windows Search 的对应物，但它只认识已索引的位置——在 `/tmp`、新挂载的卷或任何被排除的目录里查询都会返回空，而且无法与「确实没有匹配」区分开。用列表同一个 `getattrlistbulk` 枚举器走一遍树足够快（12 万条目 200ms 内），结果永远正确，且不依赖索引。

结果按广度优先流式返回，浅层匹配先出现。搜索期间目录监听暂停，类型列换成文件夹路径（路径截头保尾，因为尾部才有信息量），Esc 或清空搜索框退出。

### 属性对话框

刻意与应用其余部分风格不同。Windows 11 从未现代化过这个窗口，它至今仍是遗留的 Win32 对话框——选项卡控件、蚀刻分隔线、固定标签列、13pt 复选框、右下角的按钮组。复刻 Explorer 意味着连这种视觉语言的断裂一并复刻，而不是把它抹平。

文件夹大小复用列表用的同一个 `getattrlistbulk` 枚举器递归统计，边算边刷新，关闭窗口即取消。「占用空间」按 4 KB 分配单元向上取整，这是 Explorer 打印的数字；APFS 的克隆与压缩会让真实占用更小。

一处刻意偏离：Windows 即便在深色模式下也把这个对话框保持为浅色（它早于主题系统）。这里让它跟随应用主题，看起来才像是有意为之而非坏掉。

### 快捷键

Ctrl 与 Cmd 全部等价——Ctrl 是 Explorer 的文档写法，Cmd 是 Mac 硬件上的肌肉记忆。

| 键 | 动作 |
| --- | --- |
| `Backspace` | 后退（Explorer 的绑定） |
| `Alt+←` / `Alt+→` / `Alt+↑` | 后退 / 前进 / 向上 |
| `F2` | 重命名 |
| `Del` / `Cmd+Backspace` | 删除到废纸篓；加 `Shift` 为永久删除 |
| `F5` / `Ctrl+R` | 刷新 |
| `Ctrl+X/C/V/A` | 剪切 / 复制 / 粘贴 / 全选 |
| `Ctrl+Z` / `Ctrl+Y` | 撤销 / 重做 |
| `Ctrl+Shift+N` | 新建文件夹 |
| `Ctrl+Shift+C` | 复制路径 |
| `Ctrl+T` / `Ctrl+W` | 新建 / 关闭标签页 |
| `Ctrl+L` / `Ctrl+F` | 聚焦地址栏 / 搜索框 |
| `Ctrl+Shift+1…8` | 切换视图模式 |
| `Alt+Enter` | 属性 |

Mac 键盘通常没有独立的前删键，所以 `Cmd+Backspace` 也映射到删除；单独的 `Backspace` 保留 Explorer 的「后退」语义。

### 文件操作的 Windows 语义

- 剪切不移动任何东西，只标记选择；移动发生在粘贴时，期间被剪切的项目在列表中变暗。Windows 用剪贴板上的 `Preferred DropEffect` 记录这个意图，这里用一个私有 pasteboard 类型做同样的事，同时仍写入标准 file URL 供其他应用粘贴。
- 重名冲突弹出「替换 / 跳过 / 保留两者」，带「为所有当前冲突执行此操作」勾选框；「保留两者」生成 `报告 (2).txt`，扩展名保持完整。
- Delete 进废纸篓（对应回收站），Shift+Delete 永久删除并二次确认。
- 快捷键 Ctrl 和 Cmd 都接受：Ctrl 是 Explorer 的文档写法，Cmd 是 Mac 硬件上的肌肉记忆。Mac 键盘通常没有独立 Delete 键，所以退格和前删都映射到废纸篓。
- 新建文件夹后直接进入重命名状态，且预选不含扩展名的部分——都是 Explorer 的行为。
- 撤销菜单项按 Windows 的写法带上动词：「撤销 移动」「撤销 删除」。永久删除**不进**撤销历史——没有东西可以放回去，为不可恢复的操作提供撤销项比不提供更糟。

### 撤销的实现

所有文件操作都分解为两种可逆原语：`moved(from:to:)` 和 `created(_:)`（以及删除产生的 `trashed(original:inTrash:)`）。反转一个步骤既执行回退、又产出「回退这次回退」所需的步骤，所以重做就是对反转结果再反转一次，两条路径共用同一套代码。

删除能撤销的前提是 `trashItem(at:resultingItemURL:)` 返回的废纸篓内路径——没有它就没有回去的路。

## 尚未实现

- 「此电脑」虚拟视图（当前导航栏可展开驱动器，但根节点本身尚无驱动器列表页）
- 属性对话框只有「常规」页；Windows 还有安全 / 详细信息 / 以前的版本
- 分组依据（右键菜单里 Windows 有，功能未实现故未放入菜单）
- 面包屑溢出时 Explorer 会折叠为 `«`，这里目前是直接截断
- 拖动悬停在导航栏文件夹上不会自动展开（Explorer 的 spring-loaded 行为）
- 状态栏右下角的两个视图切换按钮（视图菜单与快捷键已覆盖同样的功能）

## 构建

### 环境要求

| 项目 | 版本 |
| --- | --- |
| 运行 | macOS 13.0 或更高（`Package.swift` 声明的最低平台） |
| 构建 | Swift 6.3.3（swiftlang-6.3.3.1.3），随 Xcode 或 Command Line Tools 提供 |
| 工具链 | `swift-tools-version:5.9`，只用 SwiftPM，没有 `.xcodeproj` |
| 实际验证环境 | macOS 26.6（25G70），Apple Silicon |

没有 Xcode 也可以，装命令行工具即可：

```bash
xcode-select --install
swift --version          # 应为 6.x
```

### 编译

```bash
./build.sh            # 调试版，只编译当前架构，最快
./build.sh --release  # -Ounchecked 的 arm64 + x86_64 通用二进制
open build/ExplorerMac.app
```

`build.sh` 做三件事：调用 `swift build`、把二进制和 `Resources/` 组装成 `.app`、写入 `Info.plist` 并做一次 ad-hoc 签名。产物固定在 `build/ExplorerMac.app`，Release 版约 45 MB，其中 43 MB 是字体与图标资源，二进制本身约 2 MB。

首次 Release 构建要编译两个架构，冷编译在 M 系列上约一到两分钟；后续增量构建几秒。

### 无窗口渲染

app 自带把窗口画成 PNG 的能力，不需要屏幕录制权限，也不需要窗口真的显示出来：

```bash
./build/ExplorerMac.app/Contents/MacOS/ExplorerMac --snapshot out.png [--path /some/dir]
./build/ExplorerMac.app/Contents/MacOS/ExplorerMac --view 1   # 指定启动时的视图模式 0…7
```

## 运行遇到问题

### 「无法打开，因为无法验证开发者」/「已损坏，无法打开」

这个 app 是 ad-hoc 签名的，没有 Apple 开发者证书，也没有做公证。**自己在本机编译出来的产物不会有这个问题**——它没有被打上隔离属性。只有当 `.app` 经过下载、AirDrop、网盘或压缩包传输后，才会被 macOS 加上 `com.apple.quarantine`，然后拒绝启动。

三种解法，任选一种：

```bash
# 1. 直接去掉隔离属性（最省事）
xattr -dr com.apple.quarantine /path/to/ExplorerMac.app
```

2. 在访达里**右键点击** app →「打开」，弹窗里再点一次「打开」。注意直接双击不行，必须走右键菜单。

3. 系统设置 →「隐私与安全性」，往下滚到底，会有一句「已阻止使用 ExplorerMac」，点右边的「仍要打开」。

确认是不是隔离属性的问题：

```bash
xattr -l build/ExplorerMac.app     # 列出 com.apple.quarantine 就是它
```

### 双击没反应，或者文件列表全是空的

macOS 的隐私保护会拦下对桌面、文档、下载和外置卷的访问。第一次进这些目录时系统会弹窗询问，允许即可；如果当时点了「不允许」，之后就只会看到空列表。

修复：系统设置 →「隐私与安全性」→「文件与文件夹」，找到 ExplorerMac 打开对应开关；或者干脆在「完全磁盘访问权限」里把它加进去，一次解决所有目录。

**重新编译后权限可能会失效**：每次构建都会生成新的 ad-hoc 签名，macOS 据此认为这是另一个 app，于是重新询问甚至直接沿用旧的拒绝记录。此时在设置里把旧条目删掉再重新添加。

### 「ExplorerMac 已退出」/ 启动即崩溃

双击启动时崩溃信息会被系统吞掉。直接从终端跑二进制，错误就会打在标准错误上：

```bash
./build/ExplorerMac.app/Contents/MacOS/ExplorerMac
```

资源缺失不会导致崩溃——字体缺了回退到系统字体，图标缺了画成空框——所以崩溃通常另有原因，以终端里的输出为准。

### 界面字体不对，或者按钮全是空方框

说明 Segoe UI Variable / Segoe Fluent Icons 没有被注册上。命令栏的图标是以**文字**形式绘制的私用区码位，没有那个字体就会显示成空框。检查 `Resources/Fonts` 里是否有全部 8 个文件，然后重新执行 `./build.sh`——字体是在构建时拷进 `.app` 的，光放进源码目录不会生效。

## 资源来源

`Resources/Fonts` 与 `Resources/Icons` 中的字体与图标提取自本机的 Windows 11 25H2 简体中文安装镜像：

```
sources/install.wim
  └─ Windows/Fonts/{SegUIVar,segoeui,SegoeIcons,msyh}.ttf|ttc
  └─ Windows/SystemResources/imageres.dll.mun     # 图标资源，非 System32 下的存根
```

提取用到 `wimlib`（读 WIM）与 `icoutils`（从 PE 资源中抽 `.ico`）。

这些文件是 Microsoft 的版权资产，**仅供拥有对应 Windows 授权的用户本地自用，不可随本项目分发**。若要分发，需替换为 Selawik（微软 MIT 授权的 Segoe UI 字宽兼容克隆）与自绘矢量图标；代码中的字体解析与图标加载路径均已按可替换设计。

Windows、Segoe 及相关标识是 Microsoft Corporation 的商标。本项目仅用于界面研究与兼容性实验。
