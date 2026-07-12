SimpleNES / HDSimpleNES
=========================

一个 C++11 写的 NES 模拟器，从上游 [amhndu/SimpleNES](https://github.com/amhndu/SimpleNES) fork 而来（原仓库已归档）。本 fork 在其之上：

- 修复了 APU/DMC/三角波/SxROM 的一批时序与 bug（见 `git log`）
- 把核心（CPU/PPU/APU/Mapper/Bus）与 SFML/miniaudio 彻底解耦
- 抽出 `libSimpleNESCore.a` 静态库 + 一层 C ABI (`include/simplenes_core.h`)
- 打成 `SimpleNESCore.xcframework`，供 **iOS App (`iOS/HDSimpleNES/`, Swift + Metal + AVAudioEngine)** 消费

覆盖 mapper：0 (NROM), 1 (SxROM/MMC1), 2 (UxROM), 3 (CNROM), 4 (MMC3), 7 (AxROM), 11 (ColorDreams), 66 (GxROM)。约 50–60% 的商业游戏能跑 —— Super Mario Bros / Contra / Zelda / Battle City / Ninja Gaiden / MegaMan 1&2 等都验过。

---

## 目录

- [仓库结构](#仓库结构)
- [桌面构建（SFML）](#桌面构建sfml)
- [iOS 构建：从 C++ 到 xcframework 到 iOS App](#ios-构建从-c-到-xcframework-到-ios-app)
- [C API 概览](#c-api-概览)
- [运行 & 键位](#运行--键位)
- [已知限制](#已知限制)

---

## 仓库结构

```
├── include/                    # 公共头文件
│   ├── simplenes_core.h        # C ABI 边界（iOS/其他宿主用这个）
│   ├── CoreEmulator.h          # C++ API（桌面宿主直接用）
│   └── ...                     # 内部类（CPU/PPU/APU/Mapper/...）的头
├── src/                        # 核心实现
│   ├── APU/                    # 音频子系统（Pulse/Triangle/Noise/DMC/FrameCounter）
│   └── Mapper*.cpp             # 各 mapper
├── main.cpp                    # 桌面 SFML 入口
├── vendor/miniaudio/           # vendored 音频后端（只桌面用）
├── cmake/Modules/
│   └── ios.toolchain.cmake     # leetal/ios-cmake toolchain（本地化，无网络依赖）
├── scripts/
│   └── build_xcframework.sh    # 一键构建 xcframework
├── dist/                       # 构建产物（.gitignore）
│   └── SimpleNESCore.xcframework
├── iOS/HDSimpleNES/            # iOS App（Xcode 工程）
│   ├── HDSimpleNES/            # Swift 源码
│   │   ├── ViewController.swift, MetalFramebufferView.swift, NESAudioEngine.swift, ...
│   │   └── HDSimpleNES-Bridging-Header.h
│   └── Frameworks/SimpleNESCore.xcframework   # 从 dist/ 拷进来
└── ness/                       # 本地 ROM 测试集（.gitignore）
```

---

## 桌面构建（SFML）

依赖：

- SFML 2.x 开发头 + 库
- C++11 compiler
- CMake ≥ 3.13

```bash
brew install sfml@2 && brew link --force --overwrite sfml@2   # macOS
# 或 apt install libsfml-dev  (Debian/Ubuntu) / vcpkg install sfml (Windows)

mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(sysctl -n hw.ncpu)
./SimpleNES path/to/rom.nes
```

如果 SFML 装在非标准位置：`cmake -DSFML_ROOT=/opt/homebrew/opt/sfml@2 ..`。

静态链接：`cmake -DBUILD_STATIC=TRUE ..`。

`compile_commands.json` 会自动生成，可以 `ln -s build/compile_commands.json .` 给 clangd 用。

---

## iOS 构建：从 C++ 到 xcframework 到 iOS App

iOS 端不用 SFML/miniaudio。核心以 `SimpleNESCore.xcframework` 静态库形式提供，Swift 通过 bridging header 调 C ABI，Metal 画帧，AVAudioEngine 拉 APU 队列。

### 第 1 步：构建 xcframework

只要有 Xcode（自带 iOS SDK）+ CMake ≥ 3.13，一条命令：

```bash
./scripts/build_xcframework.sh
```

这个脚本干了什么：

1. **清掉旧产物** `build-ios/` `build-ios-sim/` `dist/SimpleNESCore.xcframework/`
2. **交叉编译 device 版 (`arm64` iOS)**
   ```bash
   cmake -G Xcode \
     -DCMAKE_TOOLCHAIN_FILE=cmake/Modules/ios.toolchain.cmake \
     -DPLATFORM=OS64 \
     -DDEPLOYMENT_TARGET=14.0 \
     ..
   cmake --build . --config Release --target SimpleNESCore
   ```
   产物：`build-ios/Release-iphoneos/libSimpleNESCore.a`
3. **交叉编译 simulator 版 (`arm64` iPhoneSimulator)**
   ```bash
   -DPLATFORM=SIMULATORARM64
   ```
   产物：`build-ios-sim/Release-iphonesimulator/libSimpleNESCore.a`
4. **`xcodebuild -create-xcframework`** 把两个 slice 合并，附上 `include/` 里的头：
   ```bash
   xcodebuild -create-xcframework \
     -library build-ios/Release-iphoneos/libSimpleNESCore.a         -headers include \
     -library build-ios-sim/Release-iphonesimulator/libSimpleNESCore.a -headers include \
     -output dist/SimpleNESCore.xcframework
   ```

成功后你会看到：

```
dist/SimpleNESCore.xcframework
├── Info.plist
├── ios-arm64/               # 真机
│   ├── libSimpleNESCore.a
│   └── Headers/simplenes_core.h + 所有内部头
└── ios-arm64-simulator/     # 模拟器
    ├── libSimpleNESCore.a
    └── Headers/...
```

CMakeLists 通过检测 `CMAKE_SYSTEM_NAME == "iOS"` 自动跳过 SFML 桌面 target，只编 `SimpleNESCore` 这一个静态库 —— 所以 iOS 构建不需要 SFML/miniaudio 环境。

### 第 2 步：把 xcframework 注入 iOS App

```bash
rm -rf iOS/HDSimpleNES/Frameworks/SimpleNESCore.xcframework
cp -R dist/SimpleNESCore.xcframework iOS/HDSimpleNES/Frameworks/
```

`iOS/HDSimpleNES/HDSimpleNES.xcodeproj` 已经把 `Frameworks/SimpleNESCore.xcframework` 加进 target 的 "Frameworks, Libraries, and Embedded Content"（Embed = **Do Not Embed**，静态库不需要 embed）。覆盖整个目录即可，Xcode 会自动挑对应 slice。

### 第 3 步：Swift 侧接线

Swift 通过一个 bridging header 看到 C API：

**`iOS/HDSimpleNES/HDSimpleNES/HDSimpleNES-Bridging-Header.h`**

```c
#import "simplenes_core.h"
```

Xcode 工程的 `SWIFT_OBJC_BRIDGING_HEADER = HDSimpleNES/HDSimpleNES-Bridging-Header.h`，`HEADER_SEARCH_PATHS` 包含 xcframework 的 `Headers/`。之后 Swift 可以直接：

```swift
guard let handle = sn_emulator_create() else { return nil }
sn_emulator_load_rom_memory(handle, romBytes, romBytes.count)
sn_emulator_reset(handle)
sn_emulator_step_frame(handle)
let fb: UnsafePointer<UInt32>? = sn_emulator_framebuffer(handle)
```

见 `iOS/HDSimpleNES/HDSimpleNES/EmulatorSession.swift` —— 这是 C API 的 Swift 包装。

### 第 4 步：编译 & 跑

```bash
cd iOS/HDSimpleNES
xcodebuild -project HDSimpleNES.xcodeproj -scheme HDSimpleNES \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

或者在 Xcode 里打开工程直接跑到 Simulator/真机。

### 修改 C++ 核心后的迭代流程

每次改了 `src/*.cpp` 或 `include/*.h`：

```bash
./scripts/build_xcframework.sh          # 重编两个 slice + 打 xcframework
rm -rf iOS/HDSimpleNES/Frameworks/SimpleNESCore.xcframework
cp -R dist/SimpleNESCore.xcframework iOS/HDSimpleNES/Frameworks/
# 然后在 Xcode 里 Build & Run
```

### 常见坑

- **`CMAKE_TOOLCHAIN_FILE` 路径要相对当前构建目录**。脚本里 cd 到 `build-ios/` 后再传 `../cmake/Modules/ios.toolchain.cmake`。
- **同一颗 App 同时装 device + simulator slice**：xcframework 会自动挑，别自己 lipo 合成一个 fat static lib —— iOS 15+ 会拒绝 arm64-device+arm64-simulator 的 fat archive。
- **改了 C API 头**：xcframework 里的 `Headers/` 是脚本从 `include/` 拷进去的快照，所以每次重跑 `build_xcframework.sh` 才会同步。Xcode 有时缓存旧的头 —— Clean Build Folder (`Cmd+Shift+K`) 一次就行。
- **`dist/`、`build-ios/`、`build-ios-sim/` 都在 `.gitignore`** —— 别把它们提交进 git。

---

## C API 概览

`include/simplenes_core.h` 是全部 iOS/其他宿主需要的对接面。核心函数：

| 函数 | 作用 |
|---|---|
| `sn_emulator_create() / _destroy()` | 生命周期，`create` 返回一个不透明 handle |
| `sn_emulator_load_rom_file(h, path)` | 从文件路径加载 iNES ROM，0 = 成功 |
| `sn_emulator_load_rom_memory(h, data, len)` | 从内存 buffer 加载（iOS 从 `NSData` / `UIDocumentPicker` 拿到 bytes 直接传） |
| `sn_emulator_reset(h)` | ROM 加载后必调 —— 分配 mapper、reset CPU/PPU |
| `sn_emulator_step_frame(h)` | 推一整帧（29781 CPU 周期） |
| `sn_emulator_framebuffer(h)` | 拿到 256×240 RGBA8 帧缓冲指针，直接喂 Metal / 任何 GPU |
| `sn_emulator_set_button(h, controller_idx, button, pressed)` | P1/P2 手柄，8 个按键 |
| `sn_emulator_pull_audio(h, out, max_samples)` | 从 SPSC 队列拉 mono float32 样本（音频线程调用） |
| `sn_emulator_audio_input_rate()` | ~894454 Hz，宿主自己重采样到硬件率 |
| `sn_last_error()` | 拿最后一次失败的原因（例如 `"Unsupported mapper #245"`） |

不导出 CPU trace / 单步 / save state —— 有需要再加。

---

## 运行 & 键位

### 桌面

```bash
./SimpleNES path/to/rom.nes                 # 默认 3× 缩放
./SimpleNES -w 600 path/to/rom.nes          # 指定宽度
./SimpleNES --mute-audio path/to/rom.nes
./SimpleNES --log-cpu path/to/rom.nes       # 输出 sn.cpudump
```

运行时热键（`src/Emulator.cpp` 硬编码）：`Esc` 退出 / `F2` 暂停切换 / `F3` 单帧步进（暂停中）/ `F4/F5` 切日志级别。

键位在 `keybindings.conf`（CMake 自动拷到 build 目录），也可以 `-C path/to/other.conf`。

**默认 P1**：Start=Enter, Select=RShift, A=J, B=K, 方向=WASD
**默认 P2**：Start/Select=Numpad9/8, A/B=Numpad5/6, 方向=方向键

### iOS

- **Open** 按钮打开 `UIDocumentPickerViewController`，从 Files.app / iCloud Drive 选 `.nes`
- 底部触摸手柄（D-Pad + A/B + Select/Start）
- MFi/Xbox/DualSense 手柄自动连接（走 GameController.framework），跟触摸并存

Dev 便利：Documents 目录里放一个 `autoload.nes` 或 `tank.nes`，启动自动加载。该行为在 `ViewController.swift` 里用 `#if DEBUG` gate 住，Release 构建整块代码不编 —— App Store 版本不会自动加载 Documents 里的任何文件。

---

## 已知限制

- **仅 NTSC**，PAL ROM 会被拒
- **Mapper 覆盖**：0/1/2/3/4/7/11/66；其他 mapper 加载时返回 `"Unsupported mapper #N"`
- **iNES header 启发式**：会尝试识别脏 header（bytes 12-15 非零的老/盗版 dump），但对 `header[7]` 本身腐烂的 ROM（例如某些中国大陆盗版汉化）无解 —— 见 `src/Cartridge.cpp` 里 `HeaderOverride` 表（预留 CRC32 覆盖机制，需要时手工加已验证的条目）
- **无 save state / 电池 RAM 持久化**
- **无 fast-forward / rewind**
- iOS App 目前只支持 P1，无 haptic feedback，无电池 SRAM 持久化 / save state / fast-forward
