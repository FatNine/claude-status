# 交接文档：把 claude-status 改造成「红绿灯打工/摸鱼指示器」

> 这是一份自包含的设计交接，给在本仓库（`~/workspace/claude-status`，fork 自
> `gmr/claude-status`，BSD-3，可自由修改）新开的 Claude Code session 用。
> 把下面「② 起手提示词」整段贴给新 session 即可开工，其余章节是参考依据。

---

## ① 背景与目标

我想要一个 **Mac 顶部菜单栏的「红绿灯」状态灯**，模仿网上那种外接红绿灯小配件，
但纯软件、不接硬件。用途：Claude 干活时我去看书/摸鱼，等需要我介入时灯变色，
无缝切换「打工 / 摸鱼」。

本仓库的原生 Swift menu bar app 已经满足大部分需求（它会读 Claude Code 会话状态
并在菜单栏显示彩色圆点），只是**默认的颜色语义和我想要的不一样**，需要改造。

### 我想要的红绿灯语义
- 🟡 **黄灯 = Claude 正在干活**（我可以摸鱼、看书、休息）
- 🔴 **红灯 = 轮到我了**（需要我 review、决策、或回答权限/输入）
- 🟢 **绿灯 = 真没事**（空闲，无事发生）

### app 当前的状态模型（4 态）与默认配色
| 状态 | 含义 | 默认色 | 我想改成 |
|---|---|---|---|
| `active` | Claude 正在跑（读文件/调工具/生成） | green | **yellow（黄）** |
| `waiting` | Claude 明确在等你（权限弹窗 / Notification） | yellow | **red（红）** |
| `idle` | 没有进行中的活，也没在等你 | gray | **green（绿）** |
| `compacting` | 在压缩上下文 | blue | 保持 blue（或随意） |

---

## ② 起手提示词（贴给新 session）

```
这是一个 fork 自 gmr/claude-status 的 macOS 菜单栏 app（BSD-3，可自由改）。
请先读仓库根目录的 TRAFFIC_LIGHT_HANDOFF.md 了解完整设计背景，然后执行第一步：

把状态→颜色映射改成「红绿灯打工/摸鱼」语义：
- active  → yellow（Claude 在干活，我摸鱼）
- waiting → red   （轮到我：review/决策/权限）
- idle    → green （真空闲）
- compacting 保持 blue

映射定义在 Shared/ClaudeSession.swift 的 colorName 计算属性（约 29–36 行）。
改完后用下面的命令重新编译并替换 /Applications 里的 app（无需 Rust）：

  cd ~/workspace/claude-status
  xcodebuild -project "Claude Status.xcodeproj" -scheme "Claude Status" \
    -configuration Release -derivedDataPath build \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
  rm -rf "/Applications/Claude Status.app"
  cp -R "build/Build/Products/Release/Claude Status.app" /Applications/
  xattr -dr com.apple.quarantine "/Applications/Claude Status.app"
  open "/Applications/Claude Status.app"

改完颜色后，再和我讨论 TRAFFIC_LIGHT_HANDOFF.md 第 ④ 节那个「干完→红灯提醒
review」的设计决策，因为它默认不生效。
```

---

## ③ 关键文件位置（已核实，行号基于当前 main）

### 颜色 / 图标 / 文案映射 —— `Shared/ClaudeSession.swift`
- `enum SessionState`（约 4–8 行）：`active / waiting / idle / compacting`
- `sfSymbol`（约 20–27 行）：菜单栏 SF Symbol（active/waiting 都是 `circle.fill`，idle 是 `circle`）
- `colorName`（约 29–36 行）：**← 改颜色就在这里**
- `emoji`（约 38–45 行）：emoji 模式下的图标（⚡/⏳/💤/🧹）
- `label`（约 47–54 行）：菜单里显示的文字
- `priority`（约 57–64 行）：多会话聚合时谁优先显示（waiting=3 最高 … idle=0 最低）
- `sortOrder`（约 68–75 行）：列表显示顺序

> 注意：app 支持「emoji 图标」和「极简彩色圆点」两种显示模式（Settings 里切换）。
> 想要纯红绿灯圆点观感，用圆点模式 + 改 `colorName`。

### Claude Code 插件（探测状态的那部分）—— `claude-status-plugin/`（git submodule）
- 这是 **Rust** 写的，编译产物 `session-status` / `set-session-name` **已预编译提交**在
  `claude-status-plugin/plugins/claude-status/scripts/`，所以**只改颜色不需要装 Rust**。
- hook 配置：`claude-status-plugin/plugins/claude-status/hooks/hooks.json`
  当前注册的 hook 与对应动作：
  | Hook 事件 | 命令 | 效果 |
  |---|---|---|
  | `SessionStart` | `session-status` | 会话开始 |
  | `PermissionRequest` | `session-status --signal` | → waiting |
  | `Notification` | `session-status --signal` | → waiting |
  | `PreCompact` | `session-status --signal` | → compacting |
  | `SessionEnd` | `session-status` | 会话结束 |
  - **没有 `Stop` hook**（关键，见第 ④ 节）。
  - `active` vs `idle` 不是靠 hook，而是 Rust 二进制读会话 JSONL transcript 推断的。

---

## ④ 重要设计决策：「Claude 干完一轮 → 红灯提醒我 review」默认不生效

这是整个改造里唯一需要动脑的点，务必先想清楚：

- 我想要「Claude 答完一轮、该我看/继续输入时」亮红灯。
- 但当前插件**没有 `Stop` hook**。Claude 答完一轮、又没触发权限/通知时，状态会落到
  **`idle`**（我的方案里 = 绿），**不会**进入 `waiting`（红）。
- 也就是说：「需要权限/决策 → 红」开箱即用（PermissionRequest/Notification 已映射 waiting）；
  但「单纯答完、等我 review → 红」**默认拿不到**。

### 两个可选方案
**方案 A：加一条 `Stop` hook（推荐先试）**
- 在 `hooks.json` 增加 `Stop` 事件，调用已预编译的 `session-status --signal`。
- 纯 JSON 配置改动，**不需要装 Rust、不用重编二进制**，改完重装插件即可。
- 待确认：`--signal` 在 `Stop` 时会落成 `waiting` 吗？需要瞄一眼 Rust 源码
  （`claude-status-plugin/crates/` 里 `session-status` 的 `--signal` 处理逻辑），
  确认它产出的状态。如果 `--signal` 恒等于「需要注意」状态，那加 Stop hook 就直接
  得到「干完→红」。
- 副作用要注意：每轮 Stop 都会变红，可能希望「我一发新消息就回到黄」——确认
  下一条 `UserPromptSubmit`/`active` 能把它顶回去（active priority=2 > idle，但
  vs waiting=3 需要验证聚合逻辑）。

**方案 B：把 `idle` 也当成「该你了 = 红」**
- 不加 Stop hook，直接把 `colorName` 里 `idle → red`。
- 更简单，但语义糙：会话只要静下来就红，分不清「真没事」和「等我 review」。
- 如果你常开多个会话、或会话经常闲置，红灯会很吵。不推荐，除非你只单开一个会话。

> 我的倾向：先用方案 A，把「真空闲」和「等我 review」区分开，才符合红绿灯本意。

---

## ⑤ 编译 / 导出 / 安装（已验证可跑通）

```bash
cd ~/workspace/claude-status

# 1) 编译 Release（无需 Rust；插件二进制已预编译在仓库里）
xcodebuild -project "Claude Status.xcodeproj" -scheme "Claude Status" \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
# 产物：build/Build/Products/Release/Claude Status.app

# 2) 替换 /Applications 里的旧版并启动
rm -rf "/Applications/Claude Status.app"
cp -R "build/Build/Products/Release/Claude Status.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/Claude Status.app"   # 保险
open "/Applications/Claude Status.app"
```

改 `hooks.json`（方案 A）后，需要让 Claude Code 重新加载插件：通常**新开一个会话**
即生效（hook 在会话启动时加载）。必要时在 Settings 里重装插件，或重启 app。

---

## ⑥ 环境事实（交接时已确认）
- macOS 26.5、Xcode 26.5 已装；**Rust/cargo 未装**（改颜色不需要；只有要重编 Rust 插件才需要）。
- 插件已安装启用：`~/.claude/plugins` 中 `claude-status@claude-status-marketplace` v2.0.5，
  marketplace 路径指向 `/Applications/Claude Status.app/Contents/Resources/claude-status-plugin`。
- **支持 Claude Desktop 的 code 模式**，不限终端 CLI —— desktop code 和终端共用同一个
  Claude Code 引擎 + 同一套 `~/.claude/` 插件/hook 体系。证据：本机会话开头能看到
  superpowers 插件的 `SessionStart` hook 注入内容，证明插件 hook 在该环境会触发。
- 插件只对**安装之后新开的会话**生效；旧会话/已开着的会话不写状态。

## ⑦ 验证方法
1. 在 Claude Desktop 新开一个 code 会话，派个活（读文件 / 跑命令）。
2. 看右上角菜单栏圆点是否按新配色变化（干活=黄、要权限/找你=红、空闲=绿）。
3. 查状态文件是否写出：`ls ~/.claude/projects/*/*.cstatus`
4. 测方案 A 时，重点观察「Claude 答完一轮」那一刻是否变红。

---

## ⑧ 实际实现记录（与原计划的差异 / 已落地）

> 上面 ①～⑦ 是最初设计草案。实际实现做了调整，以下是**已交付的真实状态**。

### 配色与状态模型（已实现，纯 Swift，未碰 Rust）
- **没有用红色**：waiting/「该你了」最终用**橙色**（红太刺眼）；硬卡在橙点中心加**实心红点**。
- **没有加 Stop hook**：改为**app 侧推导**的「注意力级别」(`AttentionLevel`)，绕开了不可靠的问号检测：
  - `active`/`compacting` → **working**（绿；compacting 折叠进 working，内部标志位保留）
  - `waiting`（权限/问题）→ **hardBlock**（橙+红心）
  - `idle` 且未读且 ≤ **60 分钟** → **needsYou**（橙）；已读或 >60 分钟 → **dormant**（灰）
- **多会话聚合优先级**修正为 hardBlock > needsYou > working > dormant（待 review 不再被「工作中」淹没）。
- **菜单栏图标几何不变**：claw + 10px 圆点 / 2px 缝，只换颜色 + 硬卡红心。
- **悬停 ✓「标记已读」**：仅 needsYou 行、悬停显现、独立命中区（防误点）→ 转 dormant。
- **worktree 命名**：`…/<repo>/.claude/worktrees/<codename>` → 显示 `repo · codename`（`deriveProjectName`）。
- 关键文件：`Shared/ClaudeSession.swift`(AttentionLevel)、`SessionMonitor.swift`(acknowledge/聚合)、
  `AppDelegate.swift`(菜单栏)、`SessionRowView/SessionListView.swift`、`Claude_StatusWidgetEntryView.swift`、
  `SessionDiscovery.swift`(命名)。

### Claude Desktop 会话识别 + 跳转（部分实现）
- **已做**：`SessionSource.claudeDesktop`（靠可执行路径含 `Application Support/Claude/claude-code/` 判断），
  行显示「Claude」；点击 → `NSWorkspace` 激活 `com.anthropic.claudefordesktop`（唤起 app 到最前）。
- **做不到（已实测确认）**：精确跳到某个具体 session tab。
  - Claude Desktop 注册了 `claude://` scheme，确认的外部路由只有 `cowork/shared-artifact?uuid=`、`mcp-auth-callback`。
  - 实测 7 种候选 deep link（host=session/code/code-session × 路径/`?uuid=`/`?cliSessionId=`，用 CLI 会话 UUID）：
    **全部只把窗口唤到最前、不切会话** → `claude://` 没有开放 code-session 导航路由。
  - 内部有 `importCliSession`(IPC)、`navigateToChat`、`cliSessionId` 概念，但都是 renderer↔main 的内部 IPC，外部进程调不到；
    `sessionUrl` 是后端 API URL（`/v1/code/sessions/…`），不是能选中 tab 的 UI 链接。
  - **剩余可能路线**：① AX 辅助功能自动化（按窗口标题/标签找到并点击 tab，脆弱、需授权辅助功能权限）；
    ② 等官方开放 deep link。注：`osascript` 读 Claude Desktop 窗口标题当前被「辅助访问」拦截，需先授权。
