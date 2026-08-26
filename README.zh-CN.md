# amcu — another macOS computer use

[English](README.md) · **简体中文**

**不接管屏幕**地读取和操作 macOS 应用程序——并且通过一个小小的浏览器扩展，操作你自己浏览器里的网页，不需要 token、不需要端口、不需要单独的浏览器配置文件。

amcu 是一个小巧、零依赖的命令行工具，面向 macOS 上的 computer-use agent。它读取应用程序的辅助功能树，在目标窗口内点击、输入、滚动和拖拽——与此同时你可以继续正常使用你的 Mac。光标不会移动，焦点不会改变，窗口不会被拉到前台。`amcu browser` 对 Chrome（或任何 Chromium 内核浏览器）的标签页做同样的事：给出页面的辅助功能大纲、带稳定引用（ref），并把真实的输入事件投递到甚至不需要可见的标签页。

```console
$ amcu snapshot --app com.apple.textedit
app: TextEdit [com.apple.textedit]
window: Untitled id=8471 frame=(320,180 700x520)
coordinates: window-relative
0 Window [StandardWindow] "Untitled" @0,0 700x520 actions:Raise
  1 ScrollArea @0,52 700x468
    2 TextArea = "" (focused) @0,52 700x468
  3 Button "Close" @12,12 14x14
  ...

$ amcu click --element 3
click ok on element 3 via ax:AXPress
```

## 为什么

大多数 macOS 自动化工具都是*前台*自动化：激活目标应用、移动真实光标、向全局 HID 事件流投递事件。agent 工作期间，这台机器就不是你的了——而在同一个光标上，你和 agent 会为每一次点击互相争抢。

想做得更好，需要三件事，amcu 三件都做了：

1. **语义化读取，而不是视觉读取。** 辅助功能树给出角色、标签、值和可用动作。它比截图快，token 开销少一个数量级，并且产生的元素引用在窗口移动之后仍然有效。
2. **能语义化操作就语义化操作。** 对按钮执行 `AXPress` 完全不需要坐标，即使控件被遮挡也能工作。
3. **把坐标事件路由到窗口，而不是屏幕。** 当确实无法避免一次带位置的真实点击时，把它投递给目标进程和窗口，而不是全局事件流。

第 3 点是大多数实现止步的地方，因为看上去显而易见的做法似乎并不奏效。见下文。

## 窗口路由点击到底是怎么工作的

用 `CGEvent.postToPid` 投递鼠标事件，看起来就应该得到一次后台点击。实际上大家一试，发现**每次点击都落在窗口的左上角**，于是断定在现代 macOS 上带位置的、按 pid 路由的鼠标事件已经坏了。

并没有坏。有两个条件必须同时满足：

| | 窗口关联 | 落点 |
|---|---|---|
| 裸 `postToPid` | ✗ 不与任何窗口关联 | 错误 |
| 在字段 51/52 中写入窗口 id | ✓ | ✗ 塌缩到窗口角落 |
| 仅 `CGEventSetWindowLocation` | ✗ | 错误 |
| **两者同时** | ✓ | ✓ **精确** |

因此，一次正确的后台点击需要把窗口 id 写入 `kCGMouseEventWindowUnderMousePointer`（字段 51）**和** `…ThatCanHandleThisEvent`（字段 52），**并且**通过 `CGEventSetWindowLocation` 设置窗口局部坐标点。只设置字段，正是制造出「角落点击」传说的那种失败方式。

在 macOS 27.0 (26A5388g) 上实测，另一应用位于最前时，瞄准一个后台窗口的窗口局部坐标 (200, 182)：

```
window id fields only   → delivered to window, landed at (0, 332)   ← the corner
CGEventSetWindowLocation only → not routed to the window at all
both                    → delivered to window, landed at (200, 150) ← exact
```

真实光标始终没有移动，最前的应用也始终没有改变。

## 隐患，以及 amcu 的应对

`CGEventSetWindowLocation` **不是公开 API**。它在运行时通过 `dlsym` 解析，Apple 随时可以修改或移除它。更糟的是，它可能的失效方式是无声的：点击仍然被投递，只是不再落在瞄准的位置——这种故障会在任何人察觉之前就把数据弄坏。

所以 amcu 不信任这个符号的存在本身。对每一个 OS 构建版本，首次使用时会运行一次**自检**：打开一个自己的一次性窗口，走完整的后台路径在一个刻意不对称的点上点击它，然后核实点击实际到达的位置。只有精确命中才算可用。结论按 OS 构建版本缓存，所以这个成本每次系统更新只付一次。

```console
$ amcu doctor
amcu doctor — 27.0 (26A5388g)
  [ok] accessibility: reading and acting on user interfaces is permitted
  [ok] screen_recording: window capture is permitted
  [ok] ax window ids: resolvable
  [ok] background pointer delivery: window-routed pointer events land accurately (verified on build 27.0 (26A5388g))
```

一旦自检失败，坐标点击并不会开始移动你的光标：它退回到在目标点上通过辅助功能树按压找到的元素——仍然没有指针事件，仍然在后台。只有当那个点上没有任何可按压的东西时，才会指给你剩下的选择：语义化元素动作，或显式的 `--mode foreground`。滚动和拖拽没有这样的回退，会直接拒绝。

## 快速开始

需要 macOS 14 或更高版本。每个 [release](https://github.com/uoox/amcu/releases) 都附带编译好的通用二进制（Apple 芯片 + Intel），无需自行编译。

### 人工部署

```bash
curl -fsSL https://raw.githubusercontent.com/uoox/amcu/main/Scripts/install.sh | sh
```

脚本会下载最新 release，用发布在旁边的校验和核对其 SHA-256，安装到 `~/.local/bin/amcu`（或 `AMCU_INSTALL_DIR`），然后就此停下——它无法替你做的两件事是权限授予：

```console
$ amcu doctor --request     # macOS 弹出授权提示；批准它们
$ amcu doctor               # 每一行都应显示 [ok]
```

权限属于**运行 amcu 的那个程序**——你的终端，或 agent 的宿主——而不是这个二进制本身：

- **辅助功能** —— 一切操作都需要。
- **屏幕录制** —— 仅 `amcu screenshot` 需要。

要操作网页，还需一步：`amcu browser install`，然后加载它指出的未打包扩展（见 [`amcu browser`](#网页amcu-browser)）。

用 `--version v0.6.0` 锁定版本，或用 `--source` 从 `main` 分支构建（需要 Swift 工具链）。`install.sh --help` 列出全部选项。

### Agent 部署

把下面这段原样交给 agent——它是为具备 shell 能力、但无法点击 macOS 授权对话框、也不该假装能点击的 agent（Claude Code、Codex、一个 SSH 会话……）写的：

```text
安装 amcu（https://github.com/uoox/amcu），一个不接管屏幕即可读取和操作 macOS 应用
与浏览器标签页的 CLI：

1. curl -fsSL https://raw.githubusercontent.com/uoox/amcu/main/Scripts/install.sh | sh
   （安装到 ~/.local/bin/amcu；如果 ~/.local/bin 不在 PATH 中，下面的命令请用完整路径）
2. amcu doctor --request --json
   这会触发只有我才能批准的 macOS 授权提示。如果 "accessibility" 未授予，请停下来
   告诉我：在 系统设置 > 隐私与安全性 中，为运行你的那个应用程序批准「辅助功能」
   （如需截图，再加上「屏幕录制」）。然后重新运行 `amcu doctor --json`，直到 "ok" 为 true。
   不要试图自己授予权限，也不要循环重试。
3. 把这一行加入项目的 CLAUDE.md（或你使用的等价指令文件）：
   To read or operate a macOS desktop application, use `amcu`; for web pages,
   `amcu browser`. Run `amcu guide` before the first use in a session.
   （意思是：读取或操作 macOS 桌面应用用 `amcu`，网页用 `amcu browser`；每个会话首次使用前先运行 `amcu guide`。）
4. 运行 `amcu guide`，然后用 `amcu apps` 确认你能看到正在运行的应用程序。
```

第 2 步之后的一切都无需人工介入。`amcu doctor --json` 只有在两项权限都已授予、且后台指针投递已在当前 OS 构建版本上验证通过时才报告 `"ok": true`，所以 agent 只需检查一个字段，而不必解读一段散文。任何命令加上 `--json`，都会在 stdout 输出结构化结果，在 stderr 输出结构化错误——带错误码和下一步建议。

### 其他安装方式

**手动下载。** 从 [releases 页面](https://github.com/uoox/amcu/releases)取得 `amcu-<version>-macos-universal.tar.gz`，用旁边的 `.sha256` 核对，然后把 `amcu` 放到 PATH 中的任意位置。经浏览器下载的压缩包会带上隔离属性（quarantine），所以还要执行 `xattr -d com.apple.quarantine ~/.local/bin/amcu`。

**从源码构建。** 需要 Swift 工具链（Command Line Tools 就够了——不需要 Xcode）：

```bash
git clone https://github.com/uoox/amcu
cd amcu
swift build -c release
install -m 755 .build/release/amcu ~/.local/bin/amcu   # 或 PATH 中的任意位置
```

无论来源如何，都不要把它装进包管理器的前缀目录（`/opt/homebrew/bin`，Intel 上的 `/usr/local/bin`）：这些目录属于包管理器，一个手工构建的二进制放在里面，`brew doctor` 会抱怨，将来的某次清理也可能把它删掉。`install.sh` 出于同样的原因拒绝这些目录。

## 用法

```
INSPECT
  amcu apps                                  list running applications
  amcu windows    --app S                    list windows with ids and frames
  amcu snapshot   --app S                    capture the accessibility tree as indexed text
  amcu scan       --app S                    optical fallback: recognise text and where it is
  amcu menu       --app S                    read the menu bar without opening it
  amcu focus      --app S                    report what currently has keyboard focus
  amcu doctor                                check permissions, verify background delivery
  amcu guide                                 operating instructions for an agent driving this

ACT
  amcu click      --app S --element N        press an element by its snapshot index
  amcu click      --app S --at X,Y           click a point (window-relative unless --screen)
  amcu action     --element N --action A     perform any action the element advertises
  amcu set-value  --element N --value V      set an element's value, then read it back
  amcu replace    --element N --text T        replace the selection through the accessibility API
  amcu type       --app S --text T           type literal text
  amcu paste      --app S --text T           paste via the pasteboard (input-method safe)
  amcu key        --app S --key K --mod cmd  press a key combination
  amcu menu-item  --app S --path "A > B"     invoke a menu command
  amcu scroll     --app S --dy N             scroll
  amcu drag       --app S --from X,Y --to X,Y
  amcu screenshot --app S --out FILE         capture one window, occluded or not
  amcu window     --app S --raise|--move X,Y|--resize W,H|--minimize|--restore

WEB PAGES
  amcu browser install                       one-time: register the native host, write the extension
  amcu browser tabs | tab --new --url U | tab --select ID | navigate --url U
  amcu browser window [--show|--hide|--close]   amcu 自己的后台窗口，tab --new 在这里打开
  amcu browser snapshot                      the page as an outline with [ref=e12] on every control
  amcu browser snapshot --diff               only the lines added/removed since the last snapshot
  amcu browser find --text T                 search the last snapshot (substring or /regex/)
  amcu browser click --ref e12 | fill --ref e7 --value V | type --ref e7 --text T --submit
  amcu browser select-option | key | scroll | drag | hover | upload | dialog
  amcu browser screenshot | eval --js EXPR | console | network | wait --text T | --url-matches RE
  amcu browser fill --ref e7 --secrets .env --secret DB_PASSWORD   type by key, masked in output
```

### 网页：`amcu browser`

桌面路径本来就能读取浏览器窗口的辅助功能树，但网页值得比窗口所公布的更好的东西：整个文档而不只是可见部分、在重新渲染后仍然有效的引用、投递到非前台标签页的真实输入事件、导航、求值、控制台和网络。Playwright 的 MCP 服务器通过它的「extension mode」做到了这一切——代价是需要一个中继进程、一个粘贴进扩展的 token，以及一条任何一端重启都要重新建立的连接。老是坏的正是这些，所以 amcu 保留了同样的能力，去掉了所有活动部件：

- **扩展通过 Chrome 的原生消息（native messaging）与 amcu 通信。** `amcu browser install` 写入一个清单，把这个二进制指定为 `amcu bridge` 扩展的宿主。扩展加载时由浏览器自己启动宿主，并强制限定哪个扩展 id 可以连接。没有可供网页探测的监听端口，也没有 token，因为操作系统已经知道谁在和谁对话。
- **`amcu browser …` 通过 Unix socket 到达该宿主**，socket 位于 `~/Library/Caches/amcu/browser/`，每个运行中的浏览器一个。如果扩展被重新加载，浏览器会启动一个新宿主，下一条命令就会找到它。如果浏览器退出，socket 随之消失，CLI 会明说而不是挂起。
- **读取靠内容脚本；操作靠调试器协议。** 快照在页面内计算（角色、可访问名称、状态、可见性、引用），不需要调试器。点击、按键、拖拽、截图、求值、控制台和网络走 `chrome.debugger`，所以输入事件与用户自己的无法区分——包括对不可见的标签页。唯一可见的副作用是当标签页保持附加时浏览器显示的「amcu bridge started debugging this browser」信息栏；`amcu browser detach` 可以去掉它。
- **每个动作都报告它做了什么。** `click`、`type` 和 `key` 返回时带上随后可见的结果：导航、打开了对话框、观察到多少次 DOM 变化、出现了什么（菜单、对话框）、焦点去了哪里——或者在什么都没发生时给出 `no DOM change observed`。`snapshot --diff` 只打印自上次快照以来新增和删除的行，此后新出现的引用带 `[new]` 标记；往往仅凭报告就能回答「成功了吗」，无需重新读取页面。这种关联是时间上的，不是因果上的——繁忙页面自己的更新也会被计入，而报告会说明页面何时尚未安静下来。
- **大纲陈述截图会隐藏的事实。** 输入框带上它们的实时校验约束（`[maxlength=5] [pattern=…] [accept=…]`），唯一交互性来自框架点击处理器（`jsaction`、`ng-click`、内联鼠标处理器）的元素被包含进来并标为 `[clickable]`，人类看不见的文本标为 `[unseen=opacity|font-size|contrast]`（一个经典的提示注入渠道——标记只陈述事实，判断留给调用者），来自其他源的 frame 标为 `[cross-origin]`，页脚会说明视口上方和下方还有多少页面。任何指针事件之前，目标必须静止两个动画帧，所以点击永远不会落在一个正在动画的元素曾经所在的位置。
- **秘密不进入记录。** `--secrets .env`（或 `$AMCU_SECRETS`）加载 dotenv 键：`fill --ref e7 --secret DB_PASSWORD` 按引用输入，加载的值在所有输出中被掩码为 `[secret:KEY]`——快照和回显是可靠的；控制台和网络只在页面重新编码该值之前有效，文档如实说明这一点，而不承诺一条边界。

一次性设置：

```console
$ amcu browser install
registered native host for chrome: ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/cc.uoox.amcu.json
wrote extension 0.5.0 (id cgpbockoghamineoofoonidkickapbok) to ~/Library/Application Support/amcu/extension

next: in the browser open chrome://extensions, turn on Developer mode (top right), click "Load unpacked"
      and choose:  ~/Library/Application Support/amcu/extension
then: amcu browser doctor
```

扩展以未打包方式从该文件夹加载；其清单中一个固定的 key 使它在任何地方都有相同的 id，这正是原生消息清单所允许的。升级 amcu 意味着再运行一次 `amcu browser install`——它会重写该文件夹，并在有浏览器连接时要求运行中的扩展自行重新加载。Chrome、Chrome Beta/Dev/Canary、Chromium、Edge、Brave、Vivaldi、Arc 和 Opera 读取的都是同一类清单，`install` 会为每个存在的浏览器各写一份。

然后就是熟悉的形式：

```console
$ amcu browser tabs
id=727784600	win=727784597:2	GitHub - uoox/amcu: another macOS computer use	https://github.com/uoox/amcu  (active)
$ amcu browser snapshot
tab 727784600 "GitHub - uoox/amcu: another macOS computer use" https://github.com/uoox/amcu  [chrome]
- link "Skip to content" [ref=e1]:
  - /url: https://github.com/uoox/amcu#start-of-content
- banner:
  - heading "Navigation Menu" [ref=e2] [level=2]
  - link "Homepage" [ref=e3]:
    - /url: https://github.com/
  - navigation "Global":
    - list:
      - listitem:
        - button "Platform" [ref=e4]
...
  - button "Search or jump to, type / to search" [ref=e10]
...
$ amcu browser click --ref e10
click ok on e10 (button "Search or jump to, type / to search" [ref=e10]) at 827,36 via cdp
$ amcu browser snapshot --interactive | grep combobox
- combobox "Search or jump to" [ref=e170] [active] [expanded]
$ amcu browser fill --ref e170 --value "background click"
fill ok on e170 (combobox "Search or jump to" [ref=e170]) via cdp:insertText (verified)
$ amcu browser key --key Enter
key ok: Enter to tab 727784600 "GitHub - uoox/amcu: another macOS computer use" https://github.com/uoox/amcu
→ navigated to https://github.com/search?q=background+click&type=repositories
```

引用的检查方式与元素索引相同：动作之前，元素会被重新解析，其角色和可访问名称与快照记录的进行比对，所以在你脚下发生变化的页面会产生 `stale_snapshot`，而不是点在移动到那里的任何东西上。frame 是地址的一部分——`f42e12` 是 frame 42 的第 12 个元素，快照把每个 frame 打印成独立的一节，附带它所在的 iframe，坐标在通往点击的路上被换算。每个 `--session` 有自己的当前标签页，所以并发的 agent 不会互相抢夺。

`tab --new` 在 amcu 自己的窗口里打开：一个独立的、从不获得焦点的浏览器窗口，首次使用时创建，第一个标签页是一个固定（pinned）的说明页。你的焦点、你的活动标签页和窗口顺序都不会被碰；agent 的标签页不在你的标签栏里，你不会误关它们；而且由于标签页可以在这个未聚焦的窗口*内部*被设为活动，它保持渲染，截图在窗口压在所有东西后面时照样工作（截图还会自己把窗口从最小化中恢复，且不聚焦）。`amcu browser window` 报告它的状态，`--show` 把它聚焦到前面供你观看 agent 工作，`--hide` 最小化，`--close` 关闭。`tab --new --user-window` 是显式的例外，会开在你的窗口里。另外，会*修改*页面的命令只有在被明确指定时才作用于你正在看的标签页——没有 pin 标签页也没有 `--tab` 时，写操作会拒绝执行，而不是把你正在读的页面导航走。

`amcu browser` 不会做的事，坦白说明：它无法脚本化 `chrome://` 页面、Web Store 或 `file://` URL，除非扩展被授予文件访问权限；截图需要标签页渲染，amcu 自己的窗口会不可见地保证这一点，但*你的*窗口中的后台标签页可能不会渲染（错误信息会说明该怎么做，而 `snapshot` 不需要像素）；`eval` 无法到达跨源 frame 的脚本上下文，不过在其中点击和输入是可以的；对被遮挡元素的点击会被拒绝并指出遮挡物，因为一次落在 cookie 横幅上的点击，正是这个工具拒绝报告的那种「成功」。当你更清楚情况时，`--force` 会退回到 JavaScript 点击。

`amcu browser guide` 承载了面向 agent 的操作约定，`amcu browser doctor` 端到端地诊断整个设置。

### 由 agent 驱动

`amcu guide` 打印操作约定——正常的操作顺序、为什么 bundle id 胜过显示名称、索引何时失效、哪条文本路径可以被验证、什么会被拒绝。它放在二进制里而不是这份 README 或某个 skill 文件里，因为那些会漂移：一个参数改了，散文却还在向一个无从得知自己错了的模型讲授上一季度的用法。

对 Claude Code 来说，整个集成就是 `CLAUDE.md` 里的一行：

```markdown
To read or operate a macOS desktop application, use `amcu`; for web pages,
`amcu browser`. Run `amcu guide` before the first use in a session.
```

没有包装层，没有 MCP 服务器，没有需要保持同步的东西。MCP 服务器只值得为没有 shell 的客户端去建——而且要建成四五个分组的工具，而不是每条命令一个。

### 菜单，无需打开

应用程序的菜单栏无论是否位于最前都可读，菜单项*及其键盘等价快捷键*不按任何东西就能返回——所以在菜单里四处查看，屏幕上什么都不会出现。

```console
$ amcu menu --app com.example.app --filter export
File > Export > PDF…	[cmd+shift+e]
```

`menu-item` 利用了这一点：当菜单项声明了键盘等价快捷键，快捷键被发送给进程，命令运行而完全不出现菜单。只有没有快捷键的菜单项才退回到按压菜单，那可能会短暂地显示它。

```console
$ amcu menu-item --app com.example.app --path "File > Export > PDF…"
menu-item ok on File > Export > PDF… via shortcut:cmd+shift+e
```

### 当没有辅助功能树时

有些窗口自己绘制界面，不公布任何有用的东西。`snapshot` 会明说，而不是返回一棵貌似合理的空树：

```console
$ amcu snapshot --app com.example.canvas
...
(this window exposes no actionable accessibility elements — it may render its
own interface; try `amcu scan` for an optical fallback)
```

`scan` 识别窗口中的文本，并给每一段文本一个与辅助功能元素**同一空间**的索引，所以 `click --element N` 两种情况下都能用。`--annotate out.png` 写出一张带编号的叠加图供模型查看。

这是刻意为之的*可寻址视觉*，而不是视觉 agent：amcu 报告文本和它的位置，把解读留给驱动它的模型。那个模型缺的不是读截图的能力——而是一种把截图中的一个点变成对一个无人在看的窗口的精确点击的办法，而这部分 amcu 已经解决了。

取舍在输出中写明：识别出的文本没有角色、没有状态、没有动作——一个禁用的按钮和一段说明文字看起来一模一样。它也不能像元素那样在点击前被重新验证，所以扫描会过期（`--max-age`，默认 60s），而不是无声地变陈旧。

### 写入会被读回

`set-value` 和 `replace` 通过辅助功能 API 写入并把值读回。被应用程序无声拒绝的写入会作为失败报告，附带两个字符串，而不是作为成功：

```console
$ amcu set-value --element 7 --value "hello"
set-value ok on element 7 via ax:AXValue (verified)
```

`replace` 在选中范围上编辑 `AXValue`。它不需要焦点、不需要前台窗口、不需要兼容的输入法——而且与合成的按键不同，结果是可以被验证的。当元素不暴露选中范围时，它退回到替换整个值，并说明它做的是哪一种。

### 快照经过整形，并且会说明

一棵未过滤的树大部分是脚手架。Chrome 过去会填满整整 1500 个节点的预算然后截断——这在模型看来就是「页面的其余部分不存在」。没有标签、值或行为的结构性容器被跳过而其子节点仍被遍历，标签已经说明一切的控件不再展开，长表格只报告实际在屏幕上的行。现在 Chrome 约 800 个节点即可捕获完毕，不截断。

被隐藏的内容在输出中计数。`--no-shaping` 关闭全部整形。

```
(hidden: 341 structural containers, 186 offscreen rows)
```

### 触达 Chromium 和 Electron 的层级结构

白名单中的宿主会被要求公布其辅助功能树——只用 `AXManualAccessibility`，绝不用 `AXEnhancedUserInterface`，因为后一个标志会使 `AXPosition` 写入被忽略，会悄悄弄坏这个工具自己的 `window --move`。

如实测量：在 macOS 27 上它什么都没改变。Chrome 在激活前报告 151 个节点，激活后 152 个；Lark，一个带真实窗口的地道 Electron 应用，两次都报告 502 个。近期的 macOS 似乎在任何辅助客户端活跃时就会自行启用 Chromium 的辅助功能。这个标志被保留下来，因为它只是一次幂等写入，是这些宿主的文档所记载的做法，而且较老的系统可能仍然需要它——但它是一项在此没有展示出任何收益的防御措施，不是对任何已观察到的问题的修复。

### 输入落在目标的焦点所在

按键落在目标应用程序*内部*当前拥有焦点的东西上，这是自动化最悄无声息的出错方式。每条输入命令都会解析焦点并报告它，`--expect-focus` 把假设变成检查：

```console
$ amcu type --app com.example.app --text "hello" --expect-focus "Search"
error [element_not_found]: focus is on TextArea "Notes", which does not match 'Search'
  next: Focus the intended field before typing.
```

任何命令加上 `--json`，即可在 stdout 得到机器可读输出、在 stderr 得到结构化错误。

### 选择器

`--app` 接受 bundle id、`pid:1234` 或应用程序名称。**优先使用 bundle id**：显示名称是本地化的，所以 `--app Finder` 在中文系统上会失败，因为同一个应用在那里叫 `访达`。`--window-id` 和 `--window-index` 在应用程序的多个窗口中挑选。

### 元素索引被检查，而不是被信任

索引来自同一 `--session` 中最近一次 `snapshot`。动作之前，amcu 按记录的路径重新解析元素，并核实角色和标签仍然匹配。如果界面在下面发生了变化，你得到的是 `stale_snapshot` 错误，而不是点在移动到那个位置的任何东西上。

```console
$ amcu click --element 4 --session inbox
error [stale_snapshot]: element 4 changed label ("Archive" -> "Delete")
  next: Re-run `amcu snapshot`; the interface changed after it was captured.
```

### 投递模式

- `--mode auto`（默认）—— 元素提供语义动作就用语义动作，否则用经过验证的后台投递；如果这个系统的路由投递没通过验证，点击退回到在目标点上做辅助功能按压（光标仍然不动）。**绝不无声地退回前台**：抢占焦点是可见的副作用，所以必须明确要求。
- `--mode background` —— 窗口路由，光标原地不动。
- `--mode foreground` —— 全局事件 tap。移动光标、夺取焦点。只有当目标已经在最前时才是正确的。

### 错误是写给 agent 看的

每一次失败都带有机器可读的错误码和具体的下一步，包括什么时候*不要*重试：

```console
$ amcu click --app Gmail --at 100,200
error [app_not_found]: no running application matched 'Gmail'
  next: Run `amcu apps` to list running applications with their pid and bundle id.
  next: Prefer a bundle id (com.apple.finder) or pid:1234 over a display name — display names are localized and differ per system language.
  next: If the target is a website, select the browser application that shows it; selectors address desktop applications, not web pages.
  next: Do not retry the same selector unchanged.
```

## amcu 不会做的事

- **自我声明为秘密的值会被隐去。** 快照直接进入模型，通常也进入记录。任何角色、子角色、占位符或标识符提到密码、口令、一次性验证码或 token 的元素，其值都会被替换为 `[redacted]`。即使对行为良好的控件这也很重要：AppKit 的 `NSSecureTextField` 确实会掩码它的字符，但它以私用区字形*按原始长度*公布掩码——所以一份未隐去的快照会精确泄露密码有多长，还把一串模型读不懂的垃圾塞给它。自定义、网页和 Electron 的输入框则完全不作任何承诺。
- **密码管理器默认被拒绝。** 钥匙串访问、1Password、Bitwarden、KeePassXC 等等都会被拒绝，除非传入 `--allow-sensitive`。这是一道护栏，不是安全边界——任何拥有辅助功能权限的东西都能读那些窗口。它防止的是意外：agent 扫过所有打开的窗口，或者听从它在网页上读到的一条指令，然后悄悄把一个保险库放进了记录。

## 局限

坦白列出，因为在运行时才发现更糟：

- **没有 Dock，没有系统所有的对话框。** 保存和打开面板、sheet 和应用内警告框*是*可达的——它们作为宿主应用的窗口出现，所以 `--window-index` 可以正常寻址。够不到的是系统自己所有的对话框：权限提示、密码请求，以及其他由 SecurityAgent 绘制的任何东西。macOS 在那里刻意拒绝自动化，也理应如此。
- **光学回退只有文本。** `scan` 找到文本及其位置；它分不清按钮和说明文字，看不见图标或无标签控件，也报告不了状态。它是给什么都不公布的窗口用的回退，不是辅助功能树的替代品。
- **窗口管理是可选的。** `amcu window` 可以移动、缩放、置前和取消最小化——但没有任何其他命令会为了让自己的活儿好干而替你做这些事。
- **惰性构建的菜单读出来是空的。** 只在打开时才填充子菜单的应用程序，其子菜单会显示为没有菜单项。`menu-item --press` 仍然可以通过打开菜单来触达它们。
- **依赖私有 API。** 后台*坐标*点击依赖 `CGEventSetWindowLocation`。语义动作、辅助功能按压回退和 `--mode foreground` 不依赖。自检的存在就是为了让你立刻发现，而不是最终才发现——而且当它失败时，点击降级为辅助功能按压，而不是降级到你的光标上。
- **浏览器扩展以未打包方式加载。** Chrome 为此要求开发者模式，并在 amcu 持有某个标签页的调试器期间显示信息栏。发布到 Web Store 可以去掉前者；后者是 Chrome 告诉用户有扩展正在驱动页面的方式，它会保留。
- **仅限 macOS**，14.0+。

## 先行者

amcu 之所以存在，是因为另外三个项目各自解决了其中一部分，而阅读它们比从零开始更有价值：

- **[stablyai/orca](https://github.com/stablyai/orca)**（MIT）—— 其 `native/computer-use-macos` 辅助程序是这个领域的参考设计：以 AX 树为主要通道、用 ScreenCaptureKit 做逐窗口捕获、语义动作优先、错误信息写给 agent 而不是开发者。这种按权限划分作用域的辅助程序架构，值得在任何能用的地方照搬。
- **[steipete/Peekaboo](https://github.com/steipete/Peekaboo)** —— 记录了角落点击的失败，并只用公开 API、通过辅助功能命中测试绕过了它。如果你想要零私有 API 暴露，这种做法是稳妥的，代价是无法投递一次真正的带位置点击。
- **[andelf/axcli](https://github.com/andelf/axcli)** —— 证明了角落点击的限制*是*可以突破的，途径是 `CGEventSetWindowLocation`（这一发现又归功于 [Lakr233/bgclick-rev-skill](https://github.com/Lakr233)）。amcu 的窗口路由配方沿用了这一发现，并加上了运行时验证。

## 开发

```bash
swift build            # 构建
swift run amcu-tests  # 运行测试套件
```

测试套件覆盖纯逻辑——两个方向的坐标换算、快照渲染和陈旧性契约、会话处理、菜单快捷键的拼写，以及对一张已渲染图像的光学识别（不需要屏幕录制授权，所以能在 CI 中运行）。需要真实 UI 会话的部分，在已授予权限的机器上用 `amcu doctor` 验证。

测试是一个普通的可执行文件，而不是 XCTest 或 swift-testing target：那两者*运行*起来都需要完整安装的 Xcode，而这个工具要在只有 Command Line Tools 的机器上保持可验证。只有部分贡献者能执行的测试，是会腐烂的测试。

浏览器扩展位于 `extension/`，由 `Scripts/embed-extension.py` 嵌入二进制（它重新生成 `Sources/AmcuCore/ExtensionBundle.swift`）；两者一旦漂移，测试套件就会失败，所以改动 `extension/` 下的任何东西之后都要运行该脚本。

### 发布

每个 release 都携带编译好的二进制；`.github/workflows/release.yml` 中的工作流保证这一点：

1. 把 `Sources/AmcuCore/Version.swift` 和 `extension/manifest.json` 提升到同一个版本号，提交。
2. 打标签并推送：`git tag v0.6.0 && git push origin main v0.6.0`——或者在 GitHub 界面上用一个新标签创建 release。
3. 工作流检出该标签，运行测试套件，用 `Scripts/package.sh` 构建 arm64+x86_64 通用二进制，并把 `amcu-<version>-macos-universal.tar.gz` 及其 `.sha256` 上传到 release——release 尚不存在时用自动生成的说明创建它，已存在时则不动手写的说明。如果你更喜欢手写，之后再编辑说明即可。

`Scripts/package.sh v0.6.0` 在本地重现该产物，并在标签与二进制报告的版本不一致时拒绝——release 永远不会带着一个报错版本号的二进制发出去。`Scripts/install.sh` 下载的正是这些资产名，所以它们是契约的一部分。

### 端到端测试

```bash
AMCU_E2E=1 Tests/e2e/run.sh
AMCU_E2E=1 AMCU_E2E_CHROME="/path/to/Chromium" Tests/e2e/browser/run.sh
```

这会编译几个很小的 AppKit 探针窗口（一个滚动的 200 行表格、一个带焦点的文本框、一个把自己对辅助功能 API 隐藏起来的自绘画布、一对组合框），并用真实的 `amcu` 二进制去驱动它们：视口裁剪、`--no-shaping`、按索引点击、带实时选区的已验证 `set-value`/`replace`、盲窗口检测，以及一项检查：任何动作命令都绝不改变最前的应用程序。

它通过 `AMCU_E2E=1` 选择启用——没有它，脚本以 0 退出并附一条说明——因为它需要 CI 所缺的一切：已登录的窗口服务器会话、发起终端的辅助功能权限，以及对 System Events 的自动化权限。这些场景之所以值得，是因为它们能抓到单元测试套件在结构上抓不到的 bug（相对错误的参考坐标系做裁剪、ScreenCaptureKit 在 UI 会话之外中止进程），而在 CI 中伪造这些条件，测的只会是伪造本身。

浏览器脚本以一次性配置文件启动一个 Chromium（Chrome for Testing 或 Chromium 构建——品牌版 Chrome 已不再遵守 `--load-extension`），加载扩展、把原生消息清单放到该配置文件读取的位置，启动一个小型测试站点并驱动它：可信点击、已验证填写、下拉选择、对话框、iframe、被遮挡和屏幕外的元素、陈旧引用、上传、截图、控制台。它绝不触碰你自己的浏览器。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
