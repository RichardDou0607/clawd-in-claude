# Clawd in Claude — 只在 Claude App 窗口里的像素桌宠(v1.15)

> 透明覆盖层 App:只在 **Claude 桌面 App 前台**时出现,限制在 Claude 窗口内容区内,
> 可拖到窗口内任意位置;不显示在别的 App 上,也没有输入框上方那个灰框 band 宠物。

## 快速开始

```bash
cd ~/Desktop/插件工厂/clawd-float-app
./run.sh          # 启动(已编译;也可直接 ./build/ClawdFloat)
```

- 切到 Claude 前台即可看到;切到 Finder/其他 App **立刻隐藏**(不会闪一下),切回 Claude 延迟约 0.28s 再显示;
- 关闭输入框上方的 band 宠物:旧插件 `glm-quota-pet` 已在设置里禁用,并已重启 Claude 卸载;
  想恢复 band 形态再执行 `claude plugin enable glm-quota-pet@glm-quota-pet-market`(需重启会话)。

## 交互

| 操作 | 效果 |
| --- | --- |
| 点宠物一次(螃蟹/状态牌/气泡下方区域) | 立即刷新额度 + 小碎步,气泡右上角显示「更新中」 |
| 点气泡 | 翻页:5 小时 → 本周 → 续费 → 套餐 → 峰谷 |
| 按住拖动 | 在 Claude 窗口内任意拖动,超出边界自动夹回 |
| **Option + 滚轮** | 调大小;普通滚轮留给 Claude 页面滚动 |
| 右键 / 菜单栏 🦀 | 刷新、状态演示、大小、显示位置、退出 |

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
  "anchorMode": "claudeWindow",
  "unit": 14,
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
- `unit`:14 时整窗约 268×244;Option+滚轮或右键菜单可在 8–32 之间调。
  所有 UI(气泡/文字/状态牌/咖啡杯/工具道具/等待板)都按 unit 等比缩放,不会出现小尺寸裁切或大尺寸重叠。

## 数据与调试

- **每 1 分钟自动刷新**(配置 `refreshMinutes: 1`);点一次宠物立即强制刷新;
  Key 发现顺序:配置 token → cc-switch 当前 Claude 供应商(仅 GLM host)→ `~/.claude/settings.json` env;
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
- 跟随窗口约 0.3s 延迟;多显示器/Claude 原生全屏未完整适配(当前主屏验证);
- 续费日以你给的 `2027-01-24` 为准,季卡按 3 个月滚动;官方接口不提供账单日;
- 未签名/未公证;只读 CGWindow owner/bounds,不读屏幕内容。

## 证据

- `evidence/in-claude-anchored.png` — 桌宠在 Claude 窗口内(标注;无 band 宠物)
- `evidence/in-claude-overlay-zoom.png` — 局部放大
- `evidence/clawd-5h-idle.png` — 5h 空闲文案(不再像加载失败)
- `evidence/clawd-renewal-page.png` — 2027-01-24 · 季卡
- `evidence/clawd-states.png` — 八种状态动作总览(空闲/思考/工具/工作/等待审批/等待回复/完成/出错)
- `evidence/clawd-tools.png` — 工具细分动作(9 种 + 未知工具兜底)
- `evidence/clawd-sizes.png` — 同一 UI 在 unit 8/14/20/32 下的等比缩放
- `evidence/tool-state-test.txt` — 长 WebSearch 保持“搜索中”直到 PostToolUse 的回归记录
- `evidence/states/peak-offpeak.png` — 峰谷页(非高峰 + 官方时段 + 倒计时)
- `evidence/flicker-fix.txt` — 切换 App 时 20ms 可见性采样(隐藏后无回弹)
- `evidence/states/*.png` — 单状态大图
- `evidence/anchor-visibility-proof.txt` — Claude 前台显示 / 切走隐藏
- `evidence/selftest.json` — 实时额度、透明窗口、点击路由、吸附边界

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
