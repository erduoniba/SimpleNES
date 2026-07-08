# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概况

SimpleNES 是一个用 C++11 编写的 NES 模拟器，依赖 SFML 2（图形/窗口/输入）与 vendored 的 miniaudio（音频输出）。上游仓库已归档（README 顶部有 **ARCHIVED** 说明），此 fork 会继续接收本地改动。构建产物是单个可执行文件 `SimpleNES`，接收一个 `.nes` ROM 路径作为参数。

## 常用命令

构建（out-of-source，`build/` 已在 `.gitignore` 中）：

```bash
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..    # 或 Debug；Debug 会开 -Wall -Wextra -g
make -j$(sysctl -n hw.ncpu)            # macOS；Linux 用 nproc
```

- SFML 装在非标准位置时用 `-DSFML_ROOT=/path/to/sfml`。
- 静态链接用 `-DBUILD_STATIC=TRUE`。
- CMake 会开启 `CMAKE_EXPORT_COMPILE_COMMANDS`，`build/compile_commands.json` 可直接给 clangd 用（把它软链到项目根便于 IDE 识别）。
- CI（`.github/workflows/compile.yml`）跑 Linux/macOS/Windows 三平台的 Release 构建；macOS 依赖 `brew install sfml@2 && brew link --force --overwrite sfml@2`。

运行：

```bash
./SimpleNES path/to/rom.nes            # 默认 3× 缩放
./SimpleNES -w 600 path/to/rom.nes     # 指定窗口宽度
./SimpleNES --mute-audio path/to/rom.nes
./SimpleNES --log-cpu path/to/rom.nes  # 生成 sn.cpudump 的完整 CPU 追踪
```

运行时热键（在 Emulator 事件循环里硬编码，见 `src/Emulator.cpp`）：`Esc` 退出，`F2` 暂停/继续，`F3`（暂停中）步进大约一帧（29781 个 CPU 周期），`F4` 切到 `Info` 日志级别，`F5` 切到 `InfoVerbose`。手柄键位在 `keybindings.conf`，CMake 会把它复制到构建目录；也可以用 `-C/--conf` 指定其他路径。

测试：**仓库没有单元测试框架**。`test/audio.cpp` 是一个手工的 miniaudio 探针程序，不会被 `CMakeLists.txt` 编译；如果需要跑它得手写命令行。默认验证方式是加载 ROM 观察行为（Super Mario Bros、Contra 等在 README 里列过的测试用例）。

代码风格：`.clang-format` 基于 Mozilla + 4 空格缩进 + Allman 大括号 + 120 列 + 大量对齐规则。提交前跑 `clang-format -i` 保持一致。`.clang-format-ignore` 用来豁免文件（`vendor/miniaudio` 已豁免）。

## 架构

模拟器采用同步、单线程的组件时钟模型。`Emulator`（`src/Emulator.cpp`）拥有所有硬件对象并驱动主循环。每个循环 tick 按 CPU 周期节拍（`cpu_clock_period_ns = 559ns`，见 `include/APU/Constants.h`）推进：`PPU.step()` 调用三次，`CPU.step()` 一次，`APU.step()` 一次。这个 3:1:1 的比例即真实 NES 的时序，请勿改动。

组件通过总线互相通讯，而不是直接持有引用：

- **`MainBus`**（CPU 地址空间）在 CPU、PPU、APU 和两个 `Controller` 之间路由读写。`0x2000-0x3FFF` 是 PPU 寄存器，`0x4000-0x4013` 是 APU 寄存器，`0x4014` 是 OAM DMA，`0x4015` 是 APU 状态，`0x4016/17` 是手柄。任何 mapper 不认识的地址在这里处理。
- **`PictureBus`**（PPU 地址空间）处理图案表 / 命名表 / 调色板；`updateMirroring()` 会在 mapper 切换命名表镜像时被调回。
- **`Mapper`**（`include/Mapper.h`）是 cartridge 端行为的抽象基类。`Mapper::createMapper` 是工厂，通过 `Mapper::Type` 枚举分派（`NROM=0, SxROM=1, UxROM=2, CNROM=3, MMC3=4, AxROM=7, ColorDreams=11, GxROM=66`）。每个 mapper 都以 `MapperXxx.h` / `MapperXxx.cpp` 成对存在——新增 mapper 时按同样的模式：加一对文件、在 `Mapper::Type` 里加常量、在 `createMapper` 的 switch 里加分支。

IRQ 走引用计数式的下拉线路：`CPU::createIRQHandler()` 分配一个 bit 位并返回一个 `IRQHandle&`（见 `include/CPU.h`）。任何组件（APU 帧计数器、DMC、MMC3 的 scanline IRQ）持有 `IRQHandle&` 并 `pull()` / `release()`，只要还有 bit 被拉低 CPU 就认为 IRQ 挂起。要加新的 IRQ 源就走这条路，别直接改 CPU 的中断标志。

DMA 通过回调传给 `Emulator`：`Emulator::OAMDMA`（`0x4014` 写）会让 CPU 跳过对应周期数并把一整页拷给 PPU；`Emulator::DMCDMA` 让 CPU 跳过周期并回读一个字节给 APU 的 DMC 通道。这两个是 CPU 的额外周期开销的所在，`skipOAMDMACycles` / `skipDMCDMACycles` 会影响 `m_skipCycles`。

音频子系统（`include/APU/`，`src/APU/`）在 CPU 时钟下运行，但每两个 CPU 周期驱动一次实际的 APU 逻辑（`APU::step` 里 `divideByTwo` 标志）。五个通道（`Pulse pulse1/pulse2`、`Triangle`、`Noise`、`DMC`）每个都有自己的 `Timer`；`FrameCounter` 按 NES 的 4 步/5 步节拍驱动 envelope、length counter、sweep。混音后的样本以 CPU 速率的一部分被 `sampling_timer` 采样，塞进一个单生产者-单消费者的无锁环形队列（`APU/spsc.hpp`），供音频线程消费。

**`AudioPlayer`**（`include/AudioPlayer.h`，`src/AudioPlayer.cpp`）在音频线程持有 miniaudio 设备，通过 `ma_resampler` 把队列里 ~1/apu_clock_period_s 的输入速率重采样到 44.1kHz。选用 miniaudio 而非 SFML SoundStream 是刻意的：注释里明确说 SFML 会引入额外缓冲和轮询延迟，改回 SFML 音频前请重看这段注释。

`Log`（`include/Log.h`）是一个单例，日志级别在 `main.cpp` 里初始化并写到 `simplenes.log` + stdout。`--log-cpu` 独立开启一个 `sn.cpudump` 里的 CPU 追踪流。`CMakeLists.txt` 会给每个源文件注入一个 `__FILENAME__` 宏用于日志前缀。

## 修改代码时的注意点

- 主循环里的 3:1:1 PPU:CPU:APU 顺序及 `cpu_clock_period_ns` 是模拟器时序的准绳，改动前理解上下游影响。
- 新加 mapper：`MapperXxx.h/.cpp` + `Mapper::Type` 枚举 + `Mapper::createMapper` switch 分支；如需 scanline IRQ（如 MMC3）就在构造时保存 `IRQHandle&` 并在 `scanlineIRQ()` 里调 `pull/release`。
- 新加 CPU 中断源：走 `CPU::createIRQHandler()` 拿一个 `IRQHandle`，不要直接读写 `m_irqPulldowns`。
- 触碰 APU/音频路径时保持 SPSC ring buffer 只有 1 个写方和 1 个读方（`APU::step` 是写方，audio callback 是读方）——`spsc.hpp` 的文档在这个前提下才成立。
- `vendor/miniaudio/` 是 vendored 的第三方源码，不要就地修改；升级请整目录替换。
