HDSimpleNES — iOS App
======================

SimpleNES 的 iOS 前端。UIKit + Metal 渲染 + AVAudioEngine + GameController.framework。核心 (`libSimpleNESCore.a`) 从仓库根的 C++ 代码交叉编译打成 `SimpleNESCore.xcframework`。

**打开就能跑**：如果只是想编译现有工程，跳到 [跑起来](#跑起来)。要重新构建 xcframework（改了 C++ 核心后），看 [重新生成 xcframework](#重新生成-xcframework)，或者仓库根的 [README.md](../../README.md)。

---

## 前置

- Xcode（自带 iOS SDK）
- `SimpleNESCore.xcframework` 已经在 `Frameworks/` 下（仓库带的一份是最新构建）

## 跑起来

在 Xcode 里：

```bash
open iOS/HDSimpleNES/HDSimpleNES.xcodeproj
```

选一个模拟器（例如 iPhone 16 Pro）或者插一台真机，`⌘R`。首次真机需要在 target 的 *Signing & Capabilities* 里设 Team。

命令行版本（不打开 Xcode）：

```bash
cd iOS/HDSimpleNES
xcodebuild -project HDSimpleNES.xcodeproj -scheme HDSimpleNES \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

装到已启动的模拟器：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/HDSimpleNES-* \
       -name HDSimpleNES.app -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.harry.HDSimpleNES
```

## 用法

App 启动进入 **游戏列表**：

- 右上角 **+** → `UIDocumentPickerViewController` → 从 Files.app / iCloud Drive 选 `.nes`。导入成功后 ROM 字节被拷进 `Documents/library/<sha256>.nes`，列表条目写入 `Documents/library.json`。
- 点击列表条目 → push 到播放器 VC，加载对应 ROM 的字节。
- 左滑条目 → **重命名 / 删除**。删除会同时移除 ROM 文件和它的 `.sram` 存档（避免再次导入同 ROM 时"复活"旧存档）。
- 空态提示：`还没导入 ROM / 点右上角 + 号选一个 .nes 文件`。

**重复处理**（按显示名字段判定）：

| 情况 | 处理 |
|---|---|
| 同一 ROM（hash 相同）再次导入 | 弹提示 `已在列表中`，不重复插入 |
| 不同 ROM、显示名撞车 | 弹 `覆盖 / 自定义名称 / 取消` |
| 覆盖 | 老条目 + 它的 ROM 文件 + `.sram` 全删，用新字节以老显示名重新插入 |
| 自定义名称 | 弹输入框，改名后重新预检——若还撞车会再弹一次 |

播放器页（推入后的 VC）：

- 右上角 **‖ / ▶** → 暂停 / 恢复（冻结帧循环 + 停音频引擎，画面停在最后一帧；后台/前台切换会保留用户暂停状态）
- 左上角 **↺** → Reset ROM（弹 `UIAlertController` 二次确认后调 `sn_emulator_reset`，等价于按真机 Reset 键）
- 屏幕下半是触摸手柄：D-Pad + A/B + Select/Start
- MFi/Xbox/DualSense 手柄自动接管 P1，跟触摸并存（`GameControllerBridge`）
- 加载失败会弹 `UIAlertController`，具体原因来自 `sn_last_error()`（例：`Unsupported mapper #245`）
- **返回列表**：导航栏左上角的返回按钮，或系统边缘滑动手势


## 项目结构

```
iOS/HDSimpleNES/
├── HDSimpleNES.xcodeproj
├── HDSimpleNES/
│   ├── AppDelegate.swift, SceneDelegate.swift  — UIKit 生命周期（SceneDelegate 把 LibraryVC 塞进 UINavigationController 作为根）
│   ├── LibraryViewController.swift             — 游戏列表 + 导入 + 冲突弹窗
│   ├── GameLibrary.swift                       — 列表模型 + library.json 持久化 + 沙盒 ROM 拷贝
│   ├── ViewController.swift                    — 播放器（组合根：视图 + 音频 + 输入 + 显示链路），由 Library push 传入 ROM data
│   ├── EmulatorSession.swift                   — C API 的 Swift 包装
│   ├── SRAMStore.swift                         — 电池存档持久化（SHA-256 keyed）
│   ├── MetalFramebufferView.swift              — MTKView + 全屏三角形 + 最近邻采样
│   ├── NESAudioEngine.swift                    — AVAudioSourceNode + 线性重采样 (894454→硬件率)
│   ├── TouchGamepadView.swift                  — 8 按钮触摸手柄
│   ├── GameControllerBridge.swift              — MFi/Xbox/DualSense 桥接
│   ├── HDSimpleNES-Bridging-Header.h           — 导入 simplenes_core.h 给 Swift 用
│   ├── Info.plist
│   └── Base.lproj/Main.storyboard              — 遗留 storyboard（不再使用，SceneDelegate 代码建根 VC）
└── Frameworks/
    └── SimpleNESCore.xcframework               — 从 dist/ 拷进来的核心静态库
        ├── ios-arm64/         — 真机
        └── ios-arm64-simulator/ — 模拟器
```

Xcode 是新版的 File System Synchronized Groups（`PBXFileSystemSynchronizedRootGroup`）：**扔进 `HDSimpleNES/` 目录的 `.swift` 文件会自动加入 target**，不需要手动 Add Files。

## 帧循环

`ViewController.swift` 里的 `CADisplayLink @ preferredFramesPerSecond=60`：

```
tick()
  → session.stepFrame()      # 推一整帧 = 29781 CPU 周期（C 侧循环）
  → metalView.draw()          # 从 sn_emulator_framebuffer() 拿指针，喂 Metal 纹理
```

音频独立线程：`AVAudioSourceNode` 的 render block 里调 `session.pullAudio()`，从 SPSC 队列拉 mono float32 样本，走两级 1-pole IIR 滤波（HP≈90 Hz 去 DC + LP≈14 kHz 抗混叠），再线性插值下采样到硬件率（44.1kHz / 48kHz）。跟 UI 线程只共享那个无锁队列。

**为什么需要 LP 抗混叠**：APU 混出来的原始波形在输入采样率 ~894454 Hz 下含有一路直到 Nyquist（~447 kHz）的方波谐波。20:1 直接线性插值到 44.1 kHz 会把这些超音波折叠回可听频段，听起来是刺耳的高频尖啸——就是"加载 ROM 后一直发出尖锐声音"的元凶。修得在下采样*之前*滤掉，否则混叠已经发生。

**为什么需要 HP 去 DC**：`APU::mix()` 输出恒为 ≥ 0 的正值（游戏中均值 ≈ 0.26）。真机的射频/喇叭天然滤 DC，我们得手动做，否则静音也是恒定电平，浪费喇叭动态范围，还会在启停时产生 pop。


## 生命周期

App 进后台（Home / 应用切换 / 来电 / 锁屏）会同时暂停帧循环和音频；回前台再自动恢复。逻辑在 `ViewController.swift` 里，观察两个 UIKit 通知：

- `didEnterBackgroundNotification` → `stopDisplayLink()` + `audioEngine.pause()`
- `willEnterForegroundNotification` → `startDisplayLink()` + `audioEngine.resume()`

背景暂停不重建 audio graph，只是 `engine.pause()`；`resume()` 里 `setActive(true)` 之后 `engine.start()`，保留缓冲复用。桌面版靠 `Emulator.cpp` 里的窗口 focus 事件做同样的事。

### 音频中断 & 路由变化

`NESAudioEngine` 在 `start()` 里挂上两个 `AVAudioSession` 通知观察者，`deinit` 里清掉：

- **`interruptionNotification`**：来电、Siri、其他 App 抢音频。`.began` iOS 已经帮我们停了 engine，我们只对齐状态；`.ended` 时如果 userInfo 里带 `.shouldResume` 就 `setActive(true) + engine.start()`。不带 `.shouldResume` 就等前台通知恢复。
- **`routeChangeNotification`**：耳机拔出 (`.oldDeviceUnavailable`) 就 `pause()`，避免游戏突然从公放喇叭大声播出去（会议室 / 图书馆礼仪）。

## 游戏库 (Library)

App 根页是 `LibraryViewController`。所有导入过的 ROM 都在这里，点击进入播放器。存储布局：

```
Documents/
├── library.json                                 — 索引：[{hash, displayName, importedAt}, ...]
├── library/
│   ├── <sha256>.nes                             — 每个条目一份 ROM 字节拷贝
│   └── <sha256>.nes
└── saves/
    ├── <sha256>.sram                            — SRAMStore 用同样的 hash 命名
    └── <sha256>.sram
```

- **拷进沙盒而非记 bookmark**：`UIDocumentPickerViewController` 拿到的是 `asCopy: true` 的临时副本，picker 关掉就没了。真要长期持有得走 security-scoped bookmark，但那样"原文件被移动/删除"会让列表条目失效——iOS 上不如直接把字节拷进 App 私有目录省心，代价是多一份 32KB-1MB 的存储。
- **hash 即身份**：ROM 文件名、SRAM 文件名、`GameEntry.hash` 是同一个字符串，跨模块一致。ROM 内容一变（哪怕改一 byte）hash 就变，视为新游戏。
- **重复处理**：`GameLibrary.preflight(data:proposedName:)` 返回三种状态供 `LibraryViewController` 决策：
  - `.sameContentAlreadyImported(existing)` —— hash 撞车，静默拒绝
  - `.nameConflict(conflicting)` —— 显示名撞车，弹「覆盖 / 自定义名称 / 取消」
  - `.free` —— 直接 `commit`
- **覆盖语义**：老条目 + 它的 `.nes` + `.sram` 全删，然后以老显示名插新字节。避免"两条同名条目"或"新游戏继承老存档"这两个尴尬状态。
- **`library.json` 解析失败**：日志 + 从空库启动。用户 hand-edit 一次不至于让 App 打不开——但列表里所有条目会消失，磁盘上的 `.nes` 依然在，重新导入即可恢复。



带电池的卡带（Zelda、Final Fantasy、勇者斗恶龙、合金装备 2、Kirby's Adventure 等，iNES header byte 6 bit 1 = 1）在真机上有颗纽扣电池维持 `$6000-$7FFF` 的 SRAM。iOS 侧靠 `SRAMStore` 把这块内存快照写盘：

- **文件名**：`Documents/saves/<sha256(ROM 字节)>.sram`。以 ROM 内容哈希为 key —— 跟 GameLibrary 用的 hash 是同一个，同一 ROM 在库里换个显示名不会丢档；不同内容的 ROM（比如汉化补丁）不会互相踩。
- **保存时机**：`UIApplication.didEnterBackgroundNotification`（主）、Reset 弹窗确认前、`willTerminateNotification`（兜底，不保证一定触发）。全部走 `Data.write(to:, options: .atomic)` —— 先写 tmp 再 rename，写盘中途 crash 不会毁掉上一份存档。
- **恢复时机**：`session.loadROM(data:)` 成功之后立刻 `SRAMStore.loadSaveIntoSession(_:)`。核心的 `sn_emulator_reset` 已经把 SRAM 清零，我们再把磁盘那份贴回去。
- **删除时机**：LibraryVC 删除条目、或 Import 时选「覆盖」时会调 `SRAMStore.deleteSaveFile(forHash:)` —— 避免同显示名下换了 ROM 后老存档"复活"。
- **不带电池的 ROM**：`sn_emulator_sram_size` 返回 0，`SRAMStore` 直接跳过 —— 不会为坦克大战之类的 ROM 建空存档。C++ 侧靠 `Cartridge::hasBatteryRAM()`（iNES byte 6 bit 1，跟总是返回 `true` 的 `hasExtendedRAM()` 分开）做这个判定。
- **32KB 变体**：MMC3（勇者斗恶龙 6 等）的 PRG-RAM 由 mapper 自己拥有，`sn_emulator_sram_size` 返回 32768，SRAMStore 无脑写这么多字节。

C API：`sn_emulator_sram_size` / `sn_emulator_sram_data` / `sn_emulator_set_sram_data`（见 `simplenes_core.h`）。桌面 SFML host 目前不消费这套 API —— 桌面 Reset 会保存 SRAM（`CoreEmulator::reset()` 内部快照恢复），但重开 App 会丢，因为桌面 host 没写盘逻辑。要加也是三行代码。

## 重新生成 xcframework

改了任何 `src/*.cpp` 或 `include/*.h` 后：

```bash
cd <repo-root>
./scripts/build_xcframework.sh
rm -rf iOS/HDSimpleNES/Frameworks/SimpleNESCore.xcframework
cp -R dist/SimpleNESCore.xcframework iOS/HDSimpleNES/Frameworks/
# 回 Xcode：Product → Clean Build Folder (⇧⌘K) → Run
```

`Clean Build Folder` 是必要的 —— Xcode 有时会缓存旧的 header 快照。

## 加新 Swift 文件

直接把 `.swift` 文件拖进 `HDSimpleNES/` 目录（Finder 或 IDE 都行）。File System Synchronized Group 会自动把它加进 target，不用手工编辑 `project.pbxproj`。

## 常见坑

- **符号名撞 ObjC selector**：Swift 里 `@objc` 方法叫 `release` / `retain` / `copy` 之类的 NSObject 方法名，会覆盖 ObjC runtime 的行为 —— 之前 `TouchGamepadView.GamepadButton.release()` 撞到 `-[NSObject release]`，ARC dealloc 无限递归栈溢出。**Swift 里 `@objc` 方法命名尽量避开 NSObject 家族**（`handleRelease` 就没事）。
- **Metal 视图零尺寸**：只用 `≤` 约束不给宽度定一个 defaultHigh 的等式约束，Auto Layout 会选零。见 `ViewController.buildUI()` 里的 `widthGrow` 处理。
- **同一颗 App 同时装 device + simulator slice**：xcframework 会自动挑，别自己 lipo 合成 fat archive —— iOS 15+ 会拒。
- **模拟器测试用 arm64 mac**：Intel Mac 需要额外加 `SIMULATOR64` 变体，脚本目前只出 `SIMULATORARM64`。要支持 Intel 就改 `scripts/build_xcframework.sh` 多编一个 slice。

## Deployment target

工程 `IPHONEOS_DEPLOYMENT_TARGET = 15.6`。xcframework 用 `DEPLOYMENT_TARGET=14.0` 交叉编译，比工程更低 —— 静态库对下兼容，够用。
