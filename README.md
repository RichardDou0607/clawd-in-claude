# Clawd in Claude — Claude Code 像素桌宠 / GLM 额度悬浮层(v1.23)

> macOS 透明覆盖层 App,读取 Claude Code hooks 的实时状态,用像素螃蟹展示
> 思考中/工具/工作中/等待审批/等待回复/完成/出错,并显示 GLM Coding Plan 额度。
>
> 两种显示方式:
> - **跟随 Claude 窗口**(锚定模式):只在 Claude App 前台出现,限制在窗口内容区内,可拖到窗口内任意位置;
> - **桌面自由悬浮 + 所有桌面常驻**:切到哪个桌面就显示在哪个桌面,可覆盖在其他 App 上。
>
> **多会话兼容**:同时开多个 Claude Code 会话时,按
> 等待审批 > 等待回复 > 出错 > 调用工具 > 工作中 > 思考中 > 完成 > 空闲
> 聚合显示,不会互相覆盖。详见 [多会话兼容](#多会话兼容)。
> 输入框上方的灰框 band 宠物已禁用。

## 快速开始

需要 macOS + Xcode Command Line Tools,以及已安装的 Claude Desktop App。

```bash
git clone https://github.com/RichardDou0607/clawd-in-claude.git
cd clawd-in-claude
./install-launchagent.sh   # 推荐:编译 + 安装登录自启
# 或者只临时启动(不登录自启):
./build.sh && ./run.sh
```

## 开机自启 / 稳定启动(推荐)

执行一次:

```bash
./install-launchagent.sh
```

- 编译并安装到固定路径 `~/Library/Application Support/ClawdFloat/ClawdFloat`;
- 装用户级 LaunchAgent `~/Library/LaunchAgents/com.richarddou.clawdfloat.plist`;
- **登录后自动启动**,不需要每次手动运行/找助手启动;
- 异常退出(崩溃/被杀)launchd 会自动重启;
- 菜单里正常「退出 Clawd」不会被强制拉起(下次登录再启动)。

状态/重启/卸载:

```bash
launchctl print gui/$(id -u)/com.richarddou.clawdfloat | head -30
launchctl kickstart -k gui/$(id -u)/com.richarddou.clawdfloat   # 手动重启
./uninstall-launchagent.sh                                      # 取消登录自启
```

> 代码更新后重新跑一次 `./install-launchagent.sh` 即可把新二进制安装到固定路径。
> 日志在 `~/Library/Application Support/ClawdFloat/launchd.out.log` / `launchd.err.log`。

- 跟随 Claude 窗口模式:切到 Finder/其他 App **立刻隐藏**(不会闪一下),切回 Claude 延迟约 0.28s 再显示;
- 桌面自由悬浮 + `levelMode=allSpaces`:桌宠常驻你当前访问的桌面,切 Space/切 App 都保持可见;
- 关闭输入框上方的 band 宠物:旧插件 `glm-quota-pet` 已在设置里禁用,并已重启 Claude 卸载;
  想恢复 band 形态再执行 `claude plugin enable glm-quota-pet@glm-quota-pet-market`(需重启会话)。

## 交互

| 操作 | 效果 |
| --- | --- |
| 点宠物一次(螃蟹/状态牌/气泡下方区域) | 立即刷新额度 + 小碎步,气泡右上角显示「更新中」 |
| 点气泡 | 翻页:5 小时 → 本周 → 续费 → 套餐 → 峰谷 |
| 按住拖动 | 在 Claude 窗口内任意拖动,超出边界自动夹回 |
| **Option + 滚轮** | 调**宠物大小**;普通滚轮留给 Claude 页面滚动 |
| **Option + Shift + 滚轮** | 调**字体/气泡大小**(独立于宠物) |
| 右键 / 菜单栏 🦀 | 刷新、状态演示、宠物大小、字体大小、显示位置、**置顶方式(全屏/跨桌面)**、退出 |

## 气泡五页

1. **5 小时额度** —— 百分比、已用/上限、下次更新时间 + 倒计时;
   如果当前 5h 窗口还没被使用,接口不会返回 nextResetTime,显示「本 5h 窗口空闲 · 使用后开始计时」
   (这不是加载失败;真正请求失败会显示「刷新失败 · 显示旧数据」并保留上次数据)。
2. **本周额度** —— 百分比、已用/上限、下次更新时间 + 倒计时。
3. **续费** —— **2027-01-24 · 季卡 · 还 90 天**(配置项 `renewalDate` + `planCycle=quarterly`)。
4. **套餐** —— GLM Coding Plan 的档位(Max/Pro/Lite)、Key 来源、更新时间。
5. **峰谷** —— 当前 **高峰 / 非高峰**、官方时段规则与切换倒计时。

页脚小圆点会跟随页数;旁边常驻一个 **峰/谷** 角标(峰=橙,谷=蓝),不翻页也能一眼看到当前时段。
小点已移到详情文字**下方**,不会和文字重叠。

## 峰谷时段(官方口径)

- **高峰**:每周一至周五 **14:00–18:00(UTC+8)**;
- **非高峰**:其余时间;**周末全天都算非高峰**;
- 官方套餐概览:**非高峰时段模型调用按基础积分消耗的 50% 抵扣**(即 0.5x;高峰按 1x)。
  个别模型/老套餐的系数可能不同,以官方文档为准。

来源:[套餐概览](https://docs.bigmodel.cn/cn/coding-plan/overview)、
[老用户权益说明](https://docs.bigmodel.cn/cn/coding-plan/notice/usage-revision)。

## 状态动作(随 Claude Code 实时变化)

| 状态 | 动作 |
| --- | --- |
| 空闲 | **喝咖啡**:白瓷杯身 + 蓝色横纹/深蓝杯套白点/蓝色把手/深蓝杯垫(刻意避开螃蟹橙色),每约 10 秒抬杯喝一口,杯口冒热气,同时眨眼 |
| 思考中 | 头顶冒出三个思考气泡,身体轻轻晃,偶尔换脚 |
| 调用工具(按工具细分) | **编辑中**(Edit/Write)、**读取中**(Read)、**搜索中**(Grep/Glob/WebSearch)、**列出中**(LS/List)、**运行中**(Bash)、**查找中**(WebFetch)、**分派中**(Task/Agent)、**更新计划**(TodoWrite/Plan)、**执行技能**(Skill)、**发送中**(SendUserFile);未知工具显示工具名+扳手 |
| 工作中 | 抱着迷你笔记本,屏幕滚动代码,两只小手臂在键盘上交替敲击 |
| 等待审批 | 左边一块审批板,红色「待批」章反复盖下,小手臂扶着板,抖脚 |
| 等待回复 | 左边一个对话气泡,三个点循环闪,小手臂扶着气泡,抖脚 |
| 完成 | 向上跳一下、举起两只手臂,周围冒星星 |
| 出错 | 身体发抖,头顶红色感叹号 |

状态来源:Claude Code hooks 写入 `~/Library/Application Support/ClawdFloat/claude-activity.json`,
App 每 0.25s 读一次:

| Hook 事件 | 状态 |
| --- | --- |
| `UserPromptSubmit` | 思考中(模型开始想/写) |
| `PreToolUse` | 按 tool_name 显示 **编辑中/读取中/搜索中/列出中/运行中/查找中/分派中/更新计划/执行技能/发送中**;状态持续整个工具执行过程,直到 PostToolUse |
| 工具持续执行 | 工作中(抱笔记本敲,持续到 PostToolUse) |
| `PostToolUse` / `SubagentStop` | **工作中**;若 4 秒内没有下一个工具,切到 **思考中** |
| 下一个 `PreToolUse` | 调用工具 → 工作中(所以连续工具循环会一直保持工作中的节奏) |
| `PermissionRequest` | 等待审批 |
| `Notification`(含 permission/许可/权限等关键词) | 等待审批 |
| `Notification`(其他,如 waiting for input) | 等待回复 |
| `PreToolUse` 且 tool=`AskUserQuestion` | 等待回复 |
| `Stop` | 完成(约 6s 后自动回空闲) |
| `SessionStart` / `SessionEnd` | 空闲 |
| `PostToolUseFailure` | 出错 |

> 注:思考中出现在「刚发出 prompt、还没调工具」和「工具结束 4 秒内没有下一个工具(模型进入长时间思考/生成)」;
> 连续工具循环中会保持工作中/调用工具,不会每做完一个工具就闪回思考。
> 长工具(WebSearch/List/Bash 等)保持工具状态直到 PostToolUse,不会 0.6s 后就换 working;
> 快速工具(Edit/Read 的 Pre/Post 可能只差几十毫秒)通过 hook 的 `last_tool/last_tool_ts` 兜底展示 1.2 秒,
> 不会因为 0.25s 轮询直接跳过“编辑中/读取中”。
> Claude Code 内部的 `mcp__ccd_turn__*`(update_plan / wrap_up 等)不是用户可见动作,
> hook 会直接忽略,避免把真实的思考/工具/工作状态冲掉。状态切换日志:
> `~/Library/Application Support/ClawdFloat/claude-activity.log`(hook 事件)和 `app.log` 里的 `activity ->`。

### 多会话兼容

Claude Code 同时开多个会话/窗口时,状态不再“最后写入的覆盖一切”:

- 每个会话写自己的 `~/Library/Application Support/ClawdFloat/sessions/<session_id>.json`;
- hook 再聚合出一个全局 `claude-activity.json` 给 App 读取;
- 聚合优先级:
  `等待审批 > 等待回复 > 出错 > 调用工具 > 工作中 > 思考中 > 完成 > 空闲`;
- 同优先级取**最新事件**;
- `SessionEnd` 移除该会话文件;30 分钟无事件的会话视为过期;
- 因此一个会话在工作时,另一个会话弹审批,桌宠会显示“等待审批”;
  一个会话 Stop/闲置也不会覆盖另一个会话的“工作中/调用工具”。

无需重装 hooks(脚本路径没变),Claude Code 的下一次事件就会使用新逻辑。

安装/卸载 hooks(只增删含 `clawd-state-hook.py` 的条目,会先备份 settings.json):

```bash
./install-state-hooks.sh    # 装到 ~/.claude/settings.json
./uninstall-state-hooks.sh  # 移除
```

不想装 hooks 也能预览:右键/菜单栏 🦀 →「状态演示」,或 `--snapshot out.png --state working`。

## 配置

`~/Library/Application Support/ClawdFloat/config.json`:

```json
{
  "anchorMode": "desktop",
  "levelMode": "allSpaces",
  "unit": 14,
  "textScale": 1.0,
  "renewalDate": "2027-01-24",
  "planCycle": "quarterly",
  "renewalDay": 26,
  "refreshMinutes": 1,
  "page": 0
}
```

- `renewalDate`:明确的下次续费日(优先);过期后按 `planCycle` 自动往后滚(季卡=3 个月)。
- `planCycle`:`monthly` / `quarterly`(季卡)/ `yearly`。
- `renewalDay`:没配 `renewalDate` 时的每月续费日兜底。
- `refreshMinutes`:自动刷新间隔,默认 **1 分钟**;点一次宠物可立即强制刷新。
- `unit`:控制**宠物大小**(8–32;14 时宠物约 154×121);Option+滚轮或右键「宠物大小」调。
- `textScale`:控制**气泡字体和气泡尺寸**(0.55–2.2;1.0 默认);Option+Shift+滚轮或右键「字体大小」调。
  两者相互独立:可以宠物很大字体不变,或字体很大宠物不变。命中区/窗口尺寸会同步重算。
- `anchorMode`:`claudeWindow`=跟随 Claude App 窗口;`desktop`=桌面自由悬浮。
- `levelMode`:`normal`/`floating`=只在 Claude 前台显示;`allSpaces`=**所有桌面常驻 + 全屏**。
  allSpaces 会把面板设为 statusBar 级 + `.canJoinAllSpaces + .fullScreenAuxiliary + .stationary`;
  **切到哪个桌面就显示在哪个桌面,即使当前前台不是 Claude**。
  想要“我正在访问哪个桌面,桌宠就在哪个桌面”请用:
  `anchorMode=desktop` + `levelMode=allSpaces`(当前配置就是这样)。

## 数据与调试

- **每 1 分钟自动刷新**(配置 `refreshMinutes: 1`);点一次宠物立即强制刷新;
  Key 发现顺序:配置 token → cc-switch 当前 Claude 供应商(仅 GLM host)→ `~/.claude/settings.json` env;
- 多会话状态文件:`~/Library/Application Support/ClawdFloat/sessions/*.json`;
  聚合结果仍在 `claude-activity.json`(带 `sessions` 数量);
- 日志:`~/Library/Application Support/ClawdFloat/app.log`,成功写 `quota ok`,失败写 `quota failed`,
  5h 窗口空闲会写 `quota note: 5h window has no nextResetTime (idle window...)`;
- 已验证:App 日志全部 `quota ok`;原始接口里 `unit=3` 的条目在窗口未使用时**没有 nextResetTime**
  (currentValue=0),所以旧文案「更新时间未返回」看起来像失败,现已改为「空闲」说明。

## 与 Claude 插件的关系 / 为什么不用插件

Claude Code 插件只能渲染在 band(输入框上方,带灰框)、Pane、对话流,没有自由浮层 API,
所以 band 里的宠物永远拖不出灰框。本 App 用跟随 Claude 窗口的透明覆盖层实现“在 App 内拖”;
band 插件已禁用,避免两个宠物同时出现。

## 已知边界

- 覆盖层是独立窗口(不是 Claude 进程内嵌 UI),Claude 必须运行且前台;
- 跟随窗口约 0.3s 延迟;Claude 原生全屏已支持(需 `levelMode=allSpaces`);
  `anchorMode=desktop` + `levelMode=allSpaces` 时桌宠会常驻当前桌面,可能盖在其它 App 上;
  多显示器仅主屏验证;
- 续费日以你给的 `2027-01-24` 为准,季卡按 3 个月滚动;官方接口不提供账单日;
- 未签名/未公证;只读 CGWindow owner/bounds,不读屏幕内容。

## 证据

> 截图已从仓库删除;这里只保留文本回归记录与 selftest 数据。

- `evidence/multi-session-test.txt` — 两个 Claude Code 会话的状态聚合回归(审批/工具/working/done/idle)
- `evidence/tool-state-test.txt` — 长 WebSearch 保持“搜索中”直到 PostToolUse 的回归记录
- `evidence/flicker-fix.txt` — 切换 App 时 20ms 可见性采样(隐藏后无回弹)
- `evidence/anchor-visibility-proof.txt` — Claude 前台显示 / 切走隐藏
- `evidence/activity-regression.txt` / `thinking-regression.txt` — 状态流转回归
- `evidence/selftest.json` / `selftest-summary.json` — 实时额度、透明窗口、点击路由、吸附边界

## 文件

```
clawd-float-app/
├── Sources/main.swift           # App 全部代码(含状态动画)
├── hooks/clawd-state-hook.py    # Claude Code hook → 状态文件
├── install-state-hooks.sh       # 安装状态 hooks
├── uninstall-state-hooks.sh     # 卸载状态 hooks
├── build.sh / run.sh
├── build/ClawdFloat
└── evidence/
```
