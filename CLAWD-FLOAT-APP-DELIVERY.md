# Clawd 桌宠 · 状态动作版交付报告(v1.27)

> **v1.27 移除输入框 band 视觉 / 区分原生 buddy(2026-10-29 14:52):**
> 现象:桌宠启动后输入框上方仍出现一个小 pet。
> 排查:
> - `glm-quota-pet` 插件的 band hooks 已从源代码、插件缓存和当前 dev-mod 副本中清空,
>   band 不再由该插件渲染;
> - 残留的小 pet 是 **Claude Code 自带的 `/buddy` 彩蛋**,不是本 App/插件。
>
> 处理:
> - 插件保留 enabled 状态作为启动器开关,但 modules 为空,不再画 band/宠物场;
> - 当前会话执行 `/buddy off` 隐藏原生 buddy;
> - 在 `~/.claude/CLAUDE.md` 添加全局提醒,要求新会话开始执行 `/buddy off`;
> - Claude Code 官方暂无持久关闭 buddy 的设置,只能每会话隐藏或靠 CLAUDE.md 提醒。
>
> **v1.26 插件 enabled 状态绑定启动器(2026-10-29 14:20):**
> 需求:Claude 插件页 turn on/off 直接控制桌宠启动器,禁用状态=启动器关闭。
> 实现:
> - LaunchAgent 不再直接跑 App,而是跑 `clawdfloat-controller.py`;
> - 控制器每 0.5s 读 `~/.claude/settings.json` 的 `glm-quota-pet` enabled:
>   true → 拉起 `ClawdFloat`,false → 停止进程;
> - 登录后控制器自启;插件未安装/配置缺失时默认启动;
> - `run.sh` 手动启动前会先确保插件启用;
> - 实测:plugin false 1 秒内停 App,plugin true 1 秒内重新拉起。
>
> **v1.25 修复残留会话导致一直“思考中”(2026-10-29 11:10):**
> 现象:Claude Code 已经没有任务,桌宠仍显示思考中。
> 原因:
> - 会话 205cee0a 在 10:54 留下 `working` 状态,但对应 Claude Code 进程已经不在了,
>   Stop/SessionEnd 没有触发;
> - 多会话聚合按优先级选中这个残留 working,App 在 4 秒后按设计转成 thinking;
> - 原逻辑只有 15 分钟总超时,所以会一直显示思考中。
>
> 修复:
> - 已清理不在运行进程里的残留 session 文件,并把聚合状态重置为 idle;
> - App 现在对 thinking/working 增加 2 分钟无事件自动回 idle;
> - hook 会话 TTL 从 30 分钟收紧到 10 分钟;
> - 已重新编译并装回 LaunchAgent。
>
> **v1.24 从桌宠菜单控制 Claude 内置插件(2026-10-29 10:12):**
> Claude 内部插件管理 turn on/off 失效时:
> - 右键 / 菜单栏 🦀 →「Claude 内置插件」→ 启用/禁用;
> - 调用 `claude plugin enable|disable glm-quota-pet@glm-quota-pet-market --scope user`;
> - 菜单显示当前状态;改动需重启 Claude 会话/App 生效;
> - 已把旧插件设为禁用,独立桌面版不会和 band 宠物重复;需要时可从菜单再启用。
>
> **v1.23 稳定开机自启(2026-10-29 10:05):**
> 之前每次需要手动启动/找助手启动。新增并已安装用户级 LaunchAgent:
> - `./install-launchagent.sh` 编译后把二进制安装到
>   `~/Library/Application Support/ClawdFloat/ClawdFloat`(仓库移动也不影响);
> - 写入 `~/Library/LaunchAgents/com.richarddou.clawdfloat.plist`,RunAtLoad 登录自启;
> - KeepAlive SuccessfulExit=false:异常退出自动重启,菜单正常退出不会强制拉起;
> - 已实测 kill -9 后 launchd 在数秒内自动拉起新进程;
> - `./uninstall-launchagent.sh` 取消自启。
>
> **v1.22 删除截图(2026-10-28 16:38):**
> 应要求删除仓库内全部截图(evidence/ 下的 PNG 等),README 只保留文本回归记录;
> 为避免公开仓库历史里仍能拿到旧截图,已同步清理 Git 历史并强推 main。
>
> **v1.21 公开 README(2026-10-28 16:35):**
> GitHub 仓库已设为 public;README 顶部补充了多会话状态聚合说明和优先级,
> 并补充了可直接克隆构建的 Quick Start。
>
> **v1.20 多会话状态兼容(2026-10-28 16:25):**
> 之前所有 Claude Code 会话共写一个 `claude-activity.json`,谁最后写谁覆盖:
> 会话 A 在跑长工具时,会话 B 一个 Stop/Idle 就会把桌宠改回空闲/完成;
> 两个会话同时工作时状态也会来回跳。
>
> 现在:
> - 每个会话写自己的 `sessions/<session_id>.json`(带 `last_tool/last_tool_ts`);
> - hook 用文件锁串行写,并聚合出全局 `claude-activity.json`,App 仍读同一个文件;
> - 聚合优先级:`等待审批 > 等待回复 > 出错 > 调用工具 > 工作中 > 思考中 > 完成 > 空闲`;
> - 同优先级取最新事件;SessionEnd 删会话文件;30 分钟无事件视为过期;
> - 旧版全局状态会在升级后种成第一个会话,避免正在跑的状态丢失。
>
> 回归(两个会话 A/B):B 在跑 WebSearch 时 A 发审批 → 显示等待审批;
> A 继续 Read 工具 → 显示 Read;A Stop 时 B 仍 working → 保持 working;两边都 SessionEnd → idle。
> 证据:`evidence/multi-session-test.txt`。
>
> **v1.19 桌宠常驻“我正在访问的桌面”(2026-10-28 15:57):**
> 你反馈的是:桌宠只出现在 Claude Code 所在的那个桌面/图层,希望切到哪个桌面就出现在哪个桌面。
> v1.18 只在 “Claude 原生全屏” 时跨桌面保持,普通窗口时依然会跟随 Claude 前台/隐藏。
>
> 修复:
> - `levelMode=allSpaces` 不再要求 Claude 前台或全屏:只要 Claude 在运行,
>   切到任意桌面/任意 App 都保持桌宠可见;
> - `anchorMode=desktop` 下 allSpaces 使用 statusBar 层级 25 +
>   `.canJoinAllSpaces + .fullScreenAuxiliary + .stationary`,并在
>   `activeSpaceDidChangeNotification` 里重新 orderFront / 回到同一屏幕位置;
> - 切换 App 的隐藏逻辑只在 `normal/floating` 生效;allSpaces 不再被隐藏;
> - 缓存最后可见位置,避免全屏 Space 的 CGWindow 坐标偏移把面板算到屏幕外。
>
> 当前配置:`anchorMode=desktop`、`levelMode=allSpaces`。
> 验证:从 DSH/Claude 桌面按 Ctrl+→ 切到 Finder 桌面后,面板 layer=25、ON=1、
>
> **v1.18 Claude 全屏时跨桌面保持(2026-10-28 15:45):**
> v1.17 只解决了“全屏时能显示”,但 Claude 全屏后按 Ctrl+←/→ 切到别的桌面,桌宠还是会消失:
> - 全屏判定用了 `screen.frame.height`(1112),而 Claude 全屏窗口实际是
>   `visibleFrame.height`(1074),所以 `lastClaudeFullscreen` 一直是 false;
> - tracker 只用 `.optionOnScreenOnly`,切到别的 Space 后看不到 Claude 窗口,直接 orderOut;
> - 全屏 Space 的 CGWindow 坐标带巨大 Space 偏移,面板会被算到屏幕外。
>
> 修复:
> - 全屏判定改为“宽度≈屏幕宽度 且 高度≥visibleFrame”;
> - 缓存 `lastClaudeFullscreen` + 最后可见 frame,切 Space 后不让 tracker 的 nil 回调隐藏;
> - 监听 `NSWorkspace.activeSpaceDidChangeNotification`,全屏时重新 orderFront 并把面板放回同一屏幕位置;
> - `allSpaces` 使用 `statusBar + canJoinAllSpaces + fullScreenAuxiliary + stationary`;
> - 全屏锚定用屏幕 frame 而不是带 Space 偏移的 CGWindow bounds。
>
> 验证:Claude 全屏 → 切到另一个桌面,面板 layer=25、ON=1、位置 X=1340,桌宠/气泡正常显示;
> 回到 Claude、退出全屏后恢复原规则;普通(非全屏)切桌面仍会隐藏。
>
> **v1.17 Claude 全屏 / 任意桌面修复(2026-10-28 15:30):**
> 之前“所有桌面空间 + 全屏”在 anchored 模式下完全没生效:锚定窗口的
> `applyAnchoredWindowBehavior()` 把层级/collectionBehavior 写死成
> `floating + moveToActiveSpace`,菜单里的 `levelMode` 被忽略;而且设置顺序是
> 先 `panel.level` 再 `panel.isFloatingPanel`,AppKit 会把 statusBar 层级重置回 floating。
>
> 修复:
> - `applyAnchoredWindowBehavior()` 现在按 `levelMode` 分支:
>   - `normal/floating`:floating + `.moveToActiveSpace + .fullScreenAuxiliary`(当前桌面);
>   - `allSpaces`:先设 `isFloatingPanel`,再设 **statusBar 层级 25** +
>     `.canJoinAllSpaces + .fullScreenAuxiliary`,覆盖 Claude 原生全屏和其它桌面空间;
> - 切换菜单后立刻重新应用行为并 `orderFrontRegardless`,不用重启;
> - 修正“置顶方式”菜单勾选状态更新错误的问题;
> - 仍然只在 Claude 前台时显示,非 Claude 前台会隐藏。
>
> 验证:Claude `AXFullScreen=true` 时,面板 layer=25、ON=1,气泡/桌宠完整覆盖在全屏内容上;
>
> **v1.16 字体大小与宠物大小独立(2026-10-27 21:50):**
> 现在有两个独立旋钮:
> - **宠物大小** `unit`(8–32):控制螃蟹、咖啡杯、工具道具、状态牌、等待板;
> - **字体大小** `textScale`(0.55–2.2,默认 1.0):只控制气泡尺寸和气泡内字体。
>
> 实现上把绘制拆成两层变换:气泡用 `textScale` 的局部坐标系,宠物/道具用 `unit/14` 的局部坐标系;
> 窗口尺寸、气泡/宠物位置、点击命中区按两者重新计算。所以可以:
> - 宠物很大、字体保持默认(unit 32 + textScale 1.0);
> - 宠物不变、字体放大或缩小(unit 14 + textScale 0.85/1.25/1.5);
> - 两者都调,互不挤压/裁切。
>
> 操作:Option+滚轮=宠物大小;**Option+Shift+滚轮=字体大小**;右键/菜单栏也有「宠物大小」「字体大小」菜单。
> 回归:unit 8/14/20/32 + 字体 0.85/1.0/1.25/1.5 全部无裁切/重叠;非默认字体 1.3 下 selftest 仍通过
>
> **v1.15 大小适配修复(2026-10-27 21:10):**
> 之前气泡、状态牌、咖啡杯、工具道具、等待板都是固定像素尺寸,只有螃蟹跟着 unit 变:
> 小尺寸(unit 8/10)时杯子/笔记本会被窗口裁掉,大尺寸(unit 20/24/32)时状态牌会压在蟹壳上、
> 道具显得很小。
>
> 现在改成**基准坐标 + 整体等比缩放**:
> - 所有 UI 一律按 unit=14 的基准坐标绘制,再用 `unit/14` 的整体仿射变换缩放;
> - 窗口尺寸、点击命中区、拖拽/滚轮也同步按这个比例换算;
> - 气泡文字、页脚、峰谷角标、状态牌、咖啡杯、工具道具、等待审批/回复板、笔记本全部一起缩放。
>
> 实测 unit 8 / 14 / 20 / 32:
> - 窗口 153×139 / 268×243 / 382×347 / 612×556 pt;
> - 没有裁切、没有重叠;点击路由和透明窗口 selftest 仍通过。
>
> **v1.14 工具状态完整/持久化修复(2026-10-27 14:20):**
> 你看到的 Searching 只闪一下,根因是 App 把 `tool` 状态在 0.6s 后强制改成了 working。
> 真实会话里 WebSearch 持续了 18 秒(14:13:49 → 14:14:27),所以后半段一直显示 working/thinking。
>
> 修复:
> - 工具状态**持续到 PostToolUse 才结束**,不再 0.6s 后就换 working;长 Search/List/Bash 会一直显示对应状态;
> - 补齐工具颗粒度:**编辑中**(Edit/Write)、**读取中**(Read)、**搜索中**(Grep/Glob/WebSearch)、
>   **列出中**(LS/List)、**运行中**(Bash)、**查找中**(WebFetch)、**分派中**(Task/Agent)、
>   **更新计划**(TodoWrite/Plan)、**执行技能**(Skill)、**发送中**(SendUserFile);未知工具走通用扳手 + 工具名兜底;
> - 快速工具仍用 `last_tool` 兜底显示 1.2s,避免轮询跳过;
> - 回归:长 WebSearch 模拟 Pre 后等 3s,状态保持“搜索中”;Post 后才切 working。证据 `evidence/tool-state-test.txt`;
>
> **v1.13 峰谷时段展示(2026-10-27 13:45):**
> 官方文档([套餐概览](https://docs.bigmodel.cn/cn/coding-plan/overview))明确:
> **高峰 = 每周一至周五 14:00–18:00(UTC+8)**,其余时间非高峰;**周末全天非高峰**;
> 非高峰按基础积分消耗的 **50%** 抵扣(高峰 1x)。
>
> 已加到桌宠:
> - 气泡新增第 5 页 **「峰谷时段」**:大字显示当前「高峰/非高峰」、官方时段规则、切换倒计时,
>   标题旁标注当前积分倍率(0.5x / 1x);
> - 所有页面左下角常驻 **峰/谷 角标**(橙=峰,蓝=谷),不翻页也能看到;
> - 状态每分钟随 tick 自动更新,14:00/18:00/周末会自动切换;当前为**非高峰**(距 14:00 还有 19 分钟);
>
> **v1.12 切换 App 闪一下修复(2026-10-27 10:41):**
> 原因是切走瞬间的竞态:激活通知先到、frontmost 还没更新,窗口 tracker 又在 0.3s 轮询里
> 调了一次 `orderFrontRegardless`,同时 `canJoinAllSpaces` 让窗口在 Space 过渡帧里短暂出现。
> 修复:
> - 切到任何非 Claude App:立即 `alpha=0 → orderOut`,并设置 0.9s 的 `suppressShowUntil`,
>   期间 tracker 回调禁止重新显示;
> - 切回 Claude:先等 0.22s,再延迟 0.28s 统一显示,避开过渡帧;
> - 去掉 `canJoinAllSpaces`,改成 `moveToActiveSpace`,不再跨 Space 预显示;
> - 已显示时不再每次轮询重复 orderFront;点桌宠/点菜单栏(本 App 激活)不触发隐藏/闪烁。
>
> 回归:用 CGWindowList 每 20ms 采样一次可见性(Claude 前台 → 激活 Finder → 再采样 3.2s):
> `1×35 → 0×93`,隐藏之后**没有出现任何一次 1**,即没有回弹/闪烁。证据:`evidence/flicker-fix.txt`。
>
> **v1.11 与 Claude Code 状态颗粒度对齐(2026-10-27 10:36):**
> 是的,需要对齐。Claude Code 会显示 Editing/Reading/Searching/Running/Thinking,我们原来只有
> 一个笼统的「工具」状态,而且快速工具(Edit/Read)的 Pre/Post hook 只差几十毫秒,0.25s 轮询
> 经常只看到 PostToolUse,直接跳到 working/thinking,所以会出现“Claude 在 Editing,桌宠却显示思考中”。
>
> 现在:
> - `PreToolUse` 按 tool_name 细分:**编辑中**(Edit/Write,纸笔)、**读取中**(Read,书本)、
>   **搜索中**(Grep/Glob,放大镜)、**运行中**(Bash,终端)、**查找中**(WebFetch/Search,地球);
> - hook 额外携带 `last_tool/last_tool_ts`;快速工具即使 Pre/Post 几乎同时,也会至少展示 1.2 秒的
>   「编辑中/读取中…」,不再被轮询跳过;
> - 之后按原有规则:4 秒没有下一个工具 → 思考中;下一个工具 → 工具状态;
>
> **v1.10 思考/工作判定修复(2026-10-27 10:30):**
> 你看到的“正在思考但显示工作中”复现了:10:26:07 最后一个 PostToolUse 写入 working 后,
> 模型进入长时间思考/生成,期间没有任何 hook 事件,状态就一直停在 working(直到 10:29 仍然错)。
>
> 修复:在 App 侧加 4 秒宽限——`PostToolUse`/`SubagentStop` 先保持「工作中」4s,
> 4s 内没有下一个工具事件就切「思考中」;下一个 `PreToolUse` 会立即切回「调用工具 / 工作中」。
> 这样连续工具循环仍显示工作中,长思考/长生成会正确显示思考中。
>
> 回归:同一条活跃会话 bf34 在 10:26:07 之后无工具,App 于 10:29:53 切到 `thinking`;
> 真实截图里 Claude 底部状态是 `Thinking`,桌宠状态牌同时显示「思考中」
>
> **v1.9 咖啡杯配色调整(2026-10-27):**
> 你反馈杯子和螃蟹的橙色太接近、容易看错。已重做杯子的装饰:
> **白瓷杯身 + 蓝色横纹 + 深蓝杯套(白点)+ 蓝色把手 + 深蓝杯垫**,并加了一圈深色描边,
> 整只杯子与橙色蟹壳明显区分;杯垫/杯口热气/抬杯喝一口的动作保持不变。
>
> **v1.8 空闲动画改成喝咖啡(2026-10-27):**
> 空闲时不再只是眨眼/小碎步:桌宠右手端着一杯咖啡(杯垫、橙色杯套、冒着热气),
> 每约 10 秒抬杯喝一口(杯身倾斜),然后放回杯垫;同时保持眨眼。
> App 已重新编译并运行。
>
> **v1.7 活跃会话回归修复(2026-10-27 10:21):**
> 你指出的“正在工作却显示成思考”复现了,根因是 v1.5 把 `PostToolUse` 映射成了 `thinking`:
> 一次 agent 回合里每次工具结束都会回到“思考中”,但真实会话在这段时间仍然在连续读文件/改文件/跑命令
> (Hook 日志:10:19:05 Write → 10:19:49 Edit → 10:19:59/10:20:11 Bash → 10:20:30/41 Bash → 10:21:00 Read…),
> 所以观感就是“工作中一直显示思考”。
>
> 现在修正为:**`PostToolUse`/`SubagentStop` → 工作中**,只有刚提交 prompt、首个工具之前才显示思考中;
> 工具执行中先显示 0.6s 的「调用工具」,然后转「工作中」抱笔记本;Stop 才结束。
> 以当前活跃会话 bf34af85 做了回归:App 日志从 `tool` → `working` 持续切换,
>
> **v1.6 新增两个等待状态(2026-10-27):**
> 1. **等待审批**:审批板 + 红色「待批」章 + 小手臂扶板 + 抖脚。
>    触发:`PermissionRequest`,或 `Notification` 消息包含 permission/许可/权限/审批/批准 等关键词。
> 2. **等待回复**:对话气泡 + 三个循环点 + 小手臂扶气泡 + 抖脚。
>    触发:`Notification`(如 "Claude is waiting for your input"),或 `PreToolUse` 的工具是 `AskUserQuestion`。
> 3. hooks 安装脚本已加上 `PermissionRequest` 事件;两个新状态同样支持菜单「状态演示」和
>
> **v1.5 状态切换修复(2026-10-27):**
> 你看到的「工作/思考切换不对」确实存在,根因有三点,已修:
> 1. **映射反了**:原来 `PostToolUse → working`,导致工具结束后模型写回复的整段时间都显示“工作中”
>    (实测一段 26.7s 的 working 其实是模型在生成);现在 **PostToolUse → 思考中**,模型处理结果时回到思考气泡。
> 2. **工具状态太短**:`PreToolUse` 到 `PostToolUse` 可能只有几十毫秒,扳手动画一闪而过;现在工具开始先显示
>    「调用工具」0.6s,工具还在跑就转「工作中」抱笔记本打字,工具结束回「思考中」。
> 3. **内部工具污染**:Claude Code 的 `mcp__ccd_turn__update_plan/wrap_up` 也会触发 Pre/PostToolUse,
>    把状态乱切;hook 已过滤掉 `mcp__ccd_turn__*`。
> 并新增诊断日志:`claude-activity.log`(每次 hook 事件)+ `app.log` 里的 `activity -> ...`(App 实际切换)。
>
> **v1.4 更新(2026-10-27):**
> ① 自动刷新间隔从 5 分钟改为 **1 分钟**(`refreshMinutes: 1`);
> ② **点一次宠物**即可立即刷新——点击范围从“螃蟹矩形”扩大到“气泡下方整块区域”(螃蟹 + 状态牌 + 空白),
> 点击后气泡右上角显示「更新中」,螃蟹同时小碎步;③ 点击容差从 3pt 放宽到 6pt,触控板轻点不会误判成拖拽。
> 其余内容同 v1.3。

## v1.3 内容(存档)

> **结论:已加上「通过动作表示状态」的动画,并接通 Claude Code 的真实事件。**
> 空闲眨眼、思考冒泡、调用工具挥扳手、工作中抱笔记本敲键盘、等待确认看怀表、完成跳起撒星星、出错发抖;
> 状态由 Claude Code hooks 实时写入文件,App 0.25s 轮询切换,不是随机动画。
> 输入框上方的 band 宠物仍然关闭;覆盖层桌宠只在 Claude App 窗口内显示、可拖动。

## 1. 七种状态动作


| 状态 | 动作 | 触发(Claude Code hook) |
| --- | --- | --- |
| 空闲 | 眨眼 / 偶尔小碎步 / 呼吸起伏 | SessionStart / SessionEnd / 长时间无事件 |
| 思考中 | 头顶三个气泡上飘 + 身体轻晃 + 偶尔换脚 | UserPromptSubmit |
| 调用工具 | 壳右侧伸小手臂,握扳手敲击 + 火花;状态牌显示工具名(如 `Bash`) | PreToolUse(带 `tool_name`) |
| 工作中 | 迷你笔记本(屏幕滚代码)+ 键盘 + 两只小手臂交替敲 | PostToolUse / SubagentStop |
| 等待确认 | 左边怀表秒针在走 + 抖脚 | Notification |
| 完成 | 向上跳 + 举起手臂 + 星星 | Stop(约 6s 后回空闲) |
| 出错 | 身体发抖 + 头顶红色感叹号 | PostToolUseFailure |

单状态大图在 `clawd-float-app/evidence/states/`。

## 2. 状态怎么接进来的

1. **Hook 桥**:`clawd-float-app/hooks/clawd-state-hook.py`。Claude Code 触发事件时把 JSON 从 stdin 传给它,
   它把 `{state, event, tool, ts, session}` 原子写入
   `~/Library/Application Support/ClawdFloat/claude-activity.json`;永远 exit 0,不阻断操作。
2. **安装**:`./install-state-hooks.sh` 把命令 hooks 合并进 `~/.claude/settings.json`
   (先备份;只增删含 `clawd-state-hook.py` 的条目),覆盖
   SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / Stop / SessionEnd。
   卸载:`./uninstall-state-hooks.sh`。
3. **App 读取**:`ClaudeActivityWatcher` 每 0.25s 读文件,状态变化时重置动画相位;
   `done` 展示 6s 自动回空闲,>15 分钟没新事件也回空闲,避免卡在“工作中”。
4. **手动预览**:右键/菜单栏 🦀 →「状态演示」子菜单;或

## 3. 验证证据(真机)

| 检查 | 结果 |
| --- | --- |
| hooks 真实触发 | ✅ 用 headless Claude 跑一句“Reply with exactly OK”:输出 `OK`,状态文件出现真实 session 事件,最终 `SessionEnd → idle` |
| 桌面 App 新会话 | ✅ Claude 桌面 Code 页新会话触发 `SessionStart`,写入 `claude-activity.json`(说明 hooks 对 App 也生效) |
| App 实时切换 | ✅ 写入 working/thinking/… 后 0.25s 内,桌宠切换成笔记本打字/思考气泡等动作 |
| 原有功能不回退 | ✅ 透明窗口 268×244、额度四页、2027-01-24 季卡、页脚圆点不重叠、拖拽/吸附、band 宠物关闭 |
| 当前运行 | ✅ App 正在运行;切到 Claude 前台即可看到桌宠 |

## 4. 怎么用

```bash
cd ~/Desktop/插件工厂/clawd-float-app
./run.sh                    # 启动桌宠(当前已在运行)
./install-state-hooks.sh    # 需要重装状态 hooks 时
./uninstall-state-hooks.sh  # 不想要 hooks 时移除(桌宠仍可手动演示)
```

- 切到 Claude 前台 → 桌宠出现;Claude 不在前台自动隐藏;
- 拖动/大小/退出同前:按住拖、Option+滚轮、右键或菜单栏 🦀;
- 状态动画只在 Claude 前台时可见;band 宠物保持关闭(插件已禁用)。

## 5. 已知边界

- Hook 状态是**事件级近似**:PreToolUse 到 PostToolUse 之间算“调用工具”,模型生成文本阶段算“思考中/工作中”;
  Notification 也可能只是“Claude 在等你输入”,不一定是权限确认;
- 多会话同时跑时以**最后写入的事件**为准;
- hooks 写的是用户级 `~/.claude/settings.json`(已备份,可用卸载脚本还原);
- 覆盖层仍是跟随 Claude 窗口的独立透明窗口(不带 Claude 进程内嵌),需 Claude 运行且前台;
- 多显示器/Claude 原生全屏未做完整适配。

## 6. 文件

```
插件工厂/
├── CLAWD-FLOAT-APP-DELIVERY.md
└── clawd-float-app/
    ├── Sources/main.swift                 ← 桌宠 + 状态动画
    ├── hooks/clawd-state-hook.py          ← Claude Code hook → 状态文件
    ├── install-state-hooks.sh / uninstall-state-hooks.sh
    ├── build.sh / run.sh
    ├── build/ClawdFloat
    ├── README.md
    └── evidence/
        ├── anchor-visibility-proof.txt
        └── selftest.json
```

**当前状态**:状态 hooks 已安装,桌宠 App 正在运行;切到 Claude 前台即可看到动作动画。