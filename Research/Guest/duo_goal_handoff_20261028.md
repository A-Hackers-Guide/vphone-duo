# Duo bring-up goal handoff (2026-10-28, agent-to-agent)

> 2026-10-29:单屏用户态方案已整体移除。本文提到的 `display.geometry`、`display.orientation_mapping`、
> `com.vphone.display.*` 通知、`vphone-display-orientation-map.json` 与 `.once`/`.override` 文件都已不存在;
> 现状见 `iphone_duo_bringup.md` 的 2026-10-29 一节。本文只作历史记录。

自包含交接文档。接手者从这里开始,不需要读会话历史。工程日志在
`Research/Guest/iphone_duo_bringup.md`(本文只摘要,细节以日志为准)。

## 0. Goal 的验收要求(用户原话展开)

> 实现 Duo 内屏、外屏、横屏、竖屏下状态栏,桌面,锁屏、旋转、折叠、触控各类组合反复测试都能验收通过,默认启用所有测试好的补丁,删除并清理测试代码,保证代码实现的干净

验收清单(逐项要证据,不许拿代理信号当完成):

| # | 验收项 | 通过标准 |
|---|---|---|
| A | 内屏竖屏 | 状态栏/桌面/锁屏/旋转/触控截图+探针正常,反复切换 3 次不劣化 |
| B | 内屏横屏 | 同上(壁纸允许已知 72pt 残带或按 §3.4 修复后满幅) |
| C | 外屏竖屏(合盖) | `display.posture closed` 落到 466×678,状态栏/桌面/锁屏/触控正常 |
| D | 外屏横屏 | 现行姿态策略拒绝(cover 固定竖屏=产品规则);以"策略拒绝+截图存证"作为该项验收形式,除非产品要求改变 |
| E | 折叠往复 | open↔closed↔book 循环 ≥3 轮,SB 不重启、不楔死;标题栏折叠按钮工作 |
| F | 触控 | 各姿态下 host 点击 + normalized 注入均命中(参照 db26a8cc 矩阵方法) |
| G | 默认启用 | glyph 0.68、壁纸 PF 门控(若表征通过)开机即生效,不依赖通知/once 文件 |
| H | 通知宽度 | 锁屏通知宽度与真机一致(用户指出当前偏宽;无既有实现,需新做,见 §3.5) |
| I | 清理 | §5.5 列出的实验代码全部删除,源码只剩生产路径+诊断 inspect |
| J | 提交 | 阶段性分模块提交(用户指示),方案见 §6 |
| K | 用户专项 | QuickAction 图标大小(0.68)默认生效 —— 当前不生效,原因见 §3.3 |

## 1. 当前实况(2026-10-28 交接时刻)

- 机器 `duotest-m5`(库 `~/.vphone/machines`),VM 运行中,竖屏 669×951 锁定屏亮屏。
- 绑定并部署 `2.12.1-local.fdcb1d99`(= 当前源码 + orientation-map 写入器修复)。
- Release 版 Launchpad 已从源码构建、Developer ID(B4MSBHVSCA)签名、装入
  `/Applications`(旧版备份 `vphone-launchpad.app.old-*`),helper ready。
- git 工作区:97 条改动 + **`VPhoneGuestComponents/FoldDisplay/` 整目录 untracked**
  (从未提交、无历史 —— 这是回归考古困难的根因;提交是验收项 J)。
- 用户已确认:QuickAction 图标 0.68 因子(视觉验收过);当前因 override 文件被清而
  不生效,用户最新反馈"icon 大小还是不对" —— 与状态一致,见 §3.3。

常用命令(注意参数必须是字符串,整数会被当只读查询):

```sh
vphone-launchpad-cli guest rpc duotest-m5 display.rotation '{"orientation":"90"}'
vphone-launchpad-cli guest rpc duotest-m5 display.posture '{"position":"closed","duration":4}'
vphone-launchpad-cli guest rpc duotest-m5 display.geometry '{}'   # 视口判断用这个
vphone-launchpad-cli guest rpc duotest-m5 notify.post '{"name":"…"}'
vphone-launchpad-cli vm stop duotest-m5 && vphone-launchpad-cli vm set-bundle duotest-m5 <ver> --update-environment && vphone-launchpad-cli vm start duotest-m5
```

## 2. 关键规则(违反会翻车,都付过学费)

1. **绝不通灵 `CSQuickActionImageGlyphView` 的方法**(它所在镜像方法列表页只读,
   `method_setImplementation` 即 SIGBUS → SB 崩溃循环 → 全客体内存压力/类恢复模式)。
   已验证可 hook 的镜像:SpringBoardUIServices、CoverSheetKit。对 glyph 只用
   transform(KVC 设 view.transform),已验证安全。
2. **视口/折叠判断用 `display.geometry`**;`device.screen` 的 width 跨视口切换是陈旧值。
3. **每次测试前清扫 `/var/mobile/Library/Caches/vphone-duo-*.override|once`**
   (跨启动持久,会污染一切实验与 bisect)。
4. **日志**:只 `files.remove` 再让 SB 重建,绝不用 files.write 截断(root 属主会废掉
   SB 写日志);`files.read` ~512KB 上限无 offset —— 删日志、单发探针、马上读。
5. **楔死恢复三板斧**:删 override → `set-bundle`(看回复 bundle 字段,绑定≠库存)
   → **VM 级**重启(客体 reboot 不够:launchd 缓存旧 SystemHook 映射)。
6. `cfw update-environment`/`vm set-bundle --update-environment` 需 VM 停机。

## 3. 已查清的根因与修复状态

### 3.1 orientation-map 写入器被掏空 → 已修(fdcb1d99)✅
SB 侧 `vpExportNativeOrientationMapping` 曾被换成只打日志的空壳(无 git 历史,无法
考证何时;3803cc4d dylib 引用 map 路径、ad926933 完全没有)。vphoned 的旋转/姿态
校验轮询 `vphone-display-orientation-map.json`,没写入器一律拒绝。已按 schema
(version/scene=SB-main/pid/generatedUptime/available/persistentViewport/
deviceOrientations/scale/surfaceType/viewportGeneration/interfaceOrientation/
configurationBounds/coordinateBounds/bounds)重实现:按需通知、启动 2–12s 重试、
视口变更后 0.15/0.6s 三处发布。已验证 geometry available。

### 3.2 cover 视口层 2 回归 —— 未解,接手第一优先 ⭐
现象:posture closed → resolver 到 `FullyClosed primary on .cover`、workspace
transition 跑、`single viewport: requested cover generation=N` 发出,但
`configurationBounds` 永不等于 466×678 → daemon 报 "viewport did not reach the
requested size"。开盖方向同样失败(双向)。
已排除:
- 我的探针轮无辜:**fb48d760(我第一轮)同样失败** → 回归在 10-26 20:03–10-27 07:37
  窗口(3803cc4d 之后、我之前),头号嫌疑="Default landscape scene policy
  integration"(日志自注"runtime validation required")。
- 监视器观测代码与 3803cc4d 二进制逐串相同。
机制线索:`vpRefreshMainTransform` 遍历 `vpObservedDisplayMonitors` —— **每次启动
都是空表**(全部日志史 0 条 "monitor init:",hook 装了但从没见到 FBSDisplayMonitor
初始化)→ refresh 恒空操作。3803cc4d 上 cover 生效说明它走的是别的路径(原生
FullyClosed 配置切换),该路径在新源码里被某改动挡住。
下一步(二选一):
1. **bisect**(推荐):用下方脚本;先在 3803cc4d 校准(它有写入器,posture 全链路
   可测),再测 dc6752cc(10-27 03:00,策略集成后首个大点),再二分
   f8c69ed3…8bb0ca17(10-26 20:03–20:43)与 7d484ccf。判据:posture 尝试后
   snapshot 里 configurationBounds 是否 466×678。
2. 二进制 diff 3803cc4d vs 现源码的 vpSetCoverViewport/vpRefreshMainTransform。
bisect 脚本(/tmp/bisect_test.sh,若丢失按此重建):

```zsh
#!/bin/zsh
set -euo pipefail
VER="$1"
vphone-launchpad-cli vm stop duotest-m5 >/dev/null 2>&1 || true
sleep 3
vphone-launchpad-cli vm set-bundle duotest-m5 "$VER" --update-environment >/dev/null 2>&1
vphone-launchpad-cli vm start duotest-m5 >/dev/null 2>&1
sleep 32
vphone-launchpad-cli guest rpc duotest-m5 notify.post '{"name":"com.vphone.display.screen.undim"}' >/dev/null 2>&1
sleep 1.5
vphone-launchpad-cli guest rpc duotest-m5 files.remove '{"path":"/var/mobile/Library/Caches/vphone-folddisplay.log"}' >/dev/null 2>&1 || true
sleep 0.5
vphone-launchpad-cli guest rpc duotest-m5 display.posture '{"position":"closed","duration":4}' 2>&1 | grep -E '"ok"|message' | head -1 || true
sleep 6
vphone-launchpad-cli guest rpc duotest-m5 notify.post '{"name":"com.vphone.display.inspect"}' >/dev/null 2>&1
sleep 3
vphone-launchpad-cli guest rpc duotest-m5 files.read '{"path":"/var/mobile/Library/Caches/vphone-folddisplay.log"}' 2>/dev/null | /usr/bin/python3 -c "
import json,sys,re
content=json.load(sys.stdin).get('result',{}).get('content','')
idx=content.find('snapshot {')
m=re.search(r'\"configurationBounds\":(\[[^\]]*\])', content[idx:idx+3000]) if idx>=0 else None
vp=[l for l in content.splitlines() if 'single viewport' in l]
print('RESULT', '$VER', 'configBounds=', m.group(1) if m else 'no-snapshot', '| vp-reqs=', len(vp))
"
```

注意:老 bundle 无写入器 → posture 必报错,但 snapshot 的 bounds 仍能判"视口是否
应用",这就是该脚本绕开 map 污染的原因。注意通知名有两族:`viewport.cover`(直接)
与 `viewport.apply.cover`(daemon 内部,走 vpSetPersistentViewport)。

### 3.3 QuickAction 图标(用户验收项 K)—— 现在不生效,原因明确
用户已视觉验收 0.68 因子(实测:glyph 视图 20.33×36.67pt → 渲染 13.8×24.9pt,
按钮 84pt 圆不变;用户说"icon 偏大"即指原生 1.0 状态)。现状:生效机制是
`com.vphone.display.quickaction.glyphscale` 通知 + 
`/var/mobile/Library/Caches/vphone-duo-buttonscale.override` 文件(0.5–1.0),
**事故恢复时 override 被清 → 现在渲染原生 1.0 → 用户看到"还是不对"**。
固化方案(验收项 G/K):SB 启动后延时重试(参考 status profile 的 1..12s 模式)
+ 每次旋转 pulse 后,遍历窗口对全部 `CSQuickActionImageGlyphView` 设
`CGAffineTransformMakeScale(0.68, 0.68)`;重锁/重呼吸出实例后要能重放。
度量背景:按钮 84pt 圆 / iconImageSize 48 / glyph 31pt,由面板尺寸驱动的 metric 行
(与设备类无关,构造器级类覆盖实验已证明);原生参照图测量不可靠(壁纸纹理+视觉
拒图),0.68 是用户眼睛定的标准。

### 3.4 壁纸黑带 —— 半修复,默认启用待表征
- 锁屏横屏:满幅 ✅(无回归)。
- 主屏横屏:调用方限定 `PF_IS_PAD_DEVICE` detour(只在两个
  supportsLandscapeWallpaperContents* 实现内答 YES)消掉 226–242pt 带,覆盖 244→72pt;
  剩 72pt 左带 = 扩展进程竖屏锚定合成 + 快照烘焙缺口,画层在 live/快照间**路径依赖**
  切换。现用 once-flag `vphone-duo-wallpaper-traits.once` 门控(WallpaperTraitsExperiment.inc)。
- 固化决策:先做 §3.2(bisect 时顺带观察),再表征"哪条转换路径稳定落在 72pt 态",
  再决定默认开或连同 3.2 修复一起处理。绝不要碰 glyph 类之外的镜像 hook(规则 §2.1)。

### 3.5 锁屏通知宽度(验收项 H)—— 无任何现存实现
全仓库/全 bundle 检索无果(用户记忆中"测过"的实现大概率与 map 写入器同批被清理)。
它属于 CoverSheet 度量族:通知列表/platter 的最大宽度由 cover sheet 布局驱动。
实现建议顺序:先复用 §3.3 的安全观测(walk 窗口 dump CSCoverSheetNotificationView/
platter 类名与 frame),找到宽度来源(可能又是某 metric 行或
CSProminentLayoutController 家族),再选安全杠杆(CoverSheetKit 类可 hook;
transform/或调用方限定 detour 模式可复制 §3.4)。

## 4. 折叠按钮(用户已问过)
"Duo Fold Posture" 标题栏按钮在 bundle 的 vphone-vm 里(VPhoneVirtualization),
10-27 实现;3803cc4d(10-26)没有属预期。当前 fdcb1d99 有。按钮循环
closed/book/open 走 `display.posture` —— 在层 2 修好前按下会失败,属已知。

## 5. 剩余工作清单(优先序)

1. §3.2 层 2 cover 回归(先 3803cc4d 校准 bisect 脚本,再 dc6752cc)。
2. §3.3 glyph 0.68 固化(去通知/文件化)→ 验收 K。
3. §3.5 通知宽度实现 → 验收 H。
4. §3.4 壁纸门控默认启用(视表征结果)。
5. 清理(验收 I),删除清单:
   - `vpApplyButtonSizeExperiment` + `com.vphone.display.quickaction.buttonsize`
   - `vpStretchWallpaperContainer` + `.wallpaper.stretch` + stretch.override 读取
   - `vpPatchReplicaContents` + `.wallpaper.replica`
   - `vpHideLiveWallpaperHosts` + `.wallpaper.hidelive`(或保留为诊断?)——按"删干净"原则删
   - `vpRotatePosterWallpaper` + `.wallpaper.poster.rotate` + poster-orientation.override
   - layoutclass 覆盖机制(vpLayoutClassOverride*、构造器内 class override 应用)
     —— **保留**构造器 swizzle 的参数日志与否由提交时定,建议保留低频日志
   - glyph 实验的通知入口被 §3.3 固化取代后删除
   - 客体端清扫残留 override/once 文件
6. 验收矩阵 A–F 逐项执行 + `Evidence/` JSON 证据(参照 db26a8cc 矩阵方法:
   固定点位 host tap + normalized 注入比对)。
7. §6 分模块提交。

## 6. 分模块提交方案(用户指示"阶段性分模块提交")

工作区 97 条改动 + untracked FoldDisplay。建议顺序(每个先 `git status` 复核,
`Build/ValidateBundle.sh` 过了再提交;**绝不提交** `Configuration/Developer.xcconfig`
—— 团队 ID,保持 gitignore):
1. `VPhoneGuestComponents/`(FoldDisplay 首次入库 + Makefile + SystemHook + 各 guest dylib)
2. `VPhoneDaemon/`(GuestAPI+Device/Process、pose、Native、Tests)
3. `VPhoneExecutable/VPhoneVirtualization/`(VM 窗口、折叠按钮、viewport)
4. `VPhoneExecutable/VPhoneCommand/`(固件 patcher + 测试)
5. `VPhoneKit/`
6. `VPhoneLaunchpad/`(Version.xcconfig、helper 授权等)
7. `Research/` + `Documents/`(日志与本文档)
提交信息风格沿用 `git log`(如 `fix(ota): …` / `Implement …`)。

## 7. 探针/通知注册表(现源码里,清理时对照)

SB 侧(folddisplay,均 opt-in):`presentation.inspect`、`quickaction.inspect`、
`windows.inspect`、`wallpaper.scenehost.sync`、`screen.undim`、`display.inspect`、
`display.inspect.detail`、`families.inspect`、`server.inspect`、
`server.orientation.*`、`virtual.*`、`viewport.cover/inner`、`viewport.apply.*`、
`orientation.*`(mapping/inputs/arbitration/actuation)、`presentation.wallpaper.pulse`、
`presentation.clock.refresh`、`quickaction.glyphscale`、`quickaction.buttonsize`、
`wallpaper.poster.rotate`、`wallpaper.hidelive`、`wallpaper.stretch`、
`wallpaper.replica`。诊断保留建议:前六个 + `presentation.wallpaper.pulse`。

关键函数索引:`vpExportNativeOrientationMapping`(已修的写入器,~L1150)、
`vpRefreshMainTransform`(L138,层 2 核心)、`vpSetCoverViewport`(定义横跨
StatusProfile.inc 尾部→主文件 L3726 起,inc 以开函数体结尾是故意的)、
`vpSetPersistentViewport`(L3768)、glyph transform 实验(L1921)。
