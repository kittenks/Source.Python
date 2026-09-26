# Source.Python 构建与发布

本文档记录 2026-09 的八游戏修复构建方式：BLADE、BMS、CS:GO、CSS、DODS、HL2DM、L4D2、TF2。
上游源码基线为 `master`，并把下列变更固定下来：

- PR #533：合入 Linux x86-64 HL2DM 的源码级支持（提交 `ee44a0a`），并复制第二个提交 `90784a8` 中的 345 个依赖文件（合计约 122 MB）。这些 Linux x86-64 依赖不参与 Windows x86 构建；x86-64 gamedata 仍需单独做游戏内验证。
- PR #535：合入 OrangeBox 实体数据更新（头提交 `017eb604`）。
- PR #537：合入新版 OrangeBox `CBaseHandle` 兼容修复（头提交 `12006ac`）。CSS/DODS/HL2DM 编译时使用新版 HL2SDK，避免 issue #536 的 `Event.variables` 崩溃/默认值错误。
- Issue #536：运行时回归目标是 `ev.variables.get_int('userid')` 与 `ev.get_int('userid')` 一致，且不再崩溃。

## 锁定的 HL2SDK 提交

`scripts/ci/sdk-pins.json` 是唯一事实来源：每个游戏记录固定提交、要校验的 Windows/Linux 库文件以及固定原因。两个下载脚本都从这里读取，不再按分支名硬编码目录，因此 TF2（OrangeBox 布局）不会再被当成 episodic 布局。

| 游戏 | HL2SDK 分支 | 提交 | Windows 库 | Linux 库 |
| --- | --- | --- | --- | --- |
| BLADE | `blade` | `a736c9a6c676136f575af5056384851a8e1e788a` | `lib/public/tier1.lib` | `lib/linux/tier1_i486.a` |
| BMS | `bms` | `69fe26fed5ad34cb6ef032c57a54f8efbcdd8849` | `lib/public/tier1.lib` | `lib/public/linux32/tier1.a` |
| CS:GO | `csgo` | `9cf2f325ea273559c7cae27b4f98518c18b8e322` | `lib/public/tier1.lib` | `lib/linux/tier1_i486.a` |
| CSS | `css` | `47f0ea659bc70718f9c41a7830b6ad943a68ba09` | `lib/public/x86/tier1.lib` | `lib/public/linux/tier1_i486.a` |
| DODS | `dods` | `cbc97391097ed5c2790ab3fac6f9d05661d3a10f` | `lib/public/x86/tier1.lib` | `lib/public/linux/tier1_i486.a` |
| HL2DM | `hl2dm` | `11dca0f12e53089b9dee6511f6b8ff4d02c9d51d` | `lib/public/x86/tier1.lib` | `lib/public/linux/tier1_i486.a`（x86-64：`lib/public/linux64/tier1.a`） |
| L4D2 | `l4d2` | `2a31cd007b2d7d2f964dc093eedcf7a812cf9dd6` | `lib/public/tier1.lib` | `lib/linux/tier1_i486.a` |
| TF2 | `tf2` | `0f358777e7a7f0ad4c6ed6595de1e4e81c15fa4e` | `lib/public/x86/tier1.lib` | `lib/public/linux/tier1_i486.a` |

CSS/DODS/HL2DM/TF2 在 2026-09-20 收到同一批 KeyValues 更新（对应 2026-09 游戏更新）；BMS 含 EmitGameSound 崩溃修复（#404）；BLADE/CS:GO 的最新提交是 2026-04-28 的 Windows tier1 重建，官方没有后续更新。

各分支最后一次提交（2026-09-25 巡检 `alliedmodders/hl2sdk` 分支列表）：

| HL2SDK 分支 | 最后提交 | 说明 |
| --- | --- | --- |
| `css` | 2026-09-20 | Update KeyValues for most recent update |
| `dods` | 2026-09-20 | Update KeyValues for most recent update |
| `hl2dm` | 2026-09-20 | Tweak KeyValues |
| `tf2` | 2026-09-20 | Tweak KeyValues |
| `bms` | 2026-07-22 | BMS EmitGameSound crash fix (#404) |
| `l4d2` | 2026-07-21 | More CI fixes |
| `blade` | 2026-04-28 | Rebuild Windows tier1 |
| `csgo` | 2026-04-28 | Rebuild Windows tier1 |

仓库里还有 `cs2`（2026 新分支）等其它 HL2SDK 分支，但本仓库没有对应的 `src/makefiles/branch/<game>.cmake`，因此不在本次八游戏范围内。

不要在 CI 中直接执行 `git checkout <branch>` 后再拉取最新提交；这会在 Valve 更新后悄悄改变 ABI。下载脚本会在解压后覆盖 `src/patches/<branch>`，并验证固定提交的顶层目录名与上述库文件，验证失败会继续尝试下一个下载来源。

## 压缩包命名与构建日期

打包脚本按当天日期给每个压缩包加日期后缀：

```text
dist/source-python-blade-2026-0925.zip
dist/source-python-bms-2026-0925.zip
dist/source-python-csgo-2026-0925.zip
dist/source-python-css-2026-0925.zip
dist/source-python-dods-2026-0925.zip
dist/source-python-hl2dm-2026-0925.zip
dist/source-python-l4d2-2026-0925.zip
dist/source-python-tf2-2026-0925.zip
dist/source-python-source-2026-0925.zip
dist/SHA256SUMS.txt
```

日期格式为 `yyyy-MMdd`（年份 + 当天月日），默认自动检测构建当天；需要固定日期时设置环境变量 `SOURCEPYTHON_BUILD_DATE=2026-0925` 或传 `-BuildDate 2026-0925`。`BUILD-MANIFEST.json` 里也记录同一个 `build_date`，便于日后核对。含更新与修复的完整源码放在 `source-python-source-<日期>.zip` 中。

打包后可用 `scripts\ci\verify-packages.ps1` 复核：逐个解压检查 `core.dll` / `core.so` / `source-python.dll` / `source-python.so`、PR #533 的 `plat-linux64` 运行时、`BUILD-MANIFEST.json` 是否齐全，并重新计算 SHA-256 与 `SHA256SUMS.txt` 比对。Actions 的 `package` job 也会自动执行这一步。

两个脚本都接受逗号分隔的列表（`-Branches bms,css,blade`），并在生成 `SHA256SUMS.txt` 时写入该日期下**所有**已存在的归档，因此可以分次打包：

```powershell
# 只生成源码包（不需要 natives，适合其余游戏还在构建时）
.\scripts\ci\package.ps1 -SourceOnly -BuildDate 2026-0926

# 只复核已完成的游戏包，跳过源码包
.\scripts\ci\verify-packages.ps1 -Branches bms,css,dods,hl2dm,l4d2,tf2 -SkipSourceArchive
```

包内布局与官方 release 一致：

```text
addons/source-python.dll                 # Windows loader
addons/source-python.so                   # Linux loader
addons/source-python/bin/core.dll         # Windows core
addons/source-python/bin/core.so          # Linux core
addons/source-python.vdf
addons/source-python/
cfg/ logs/ resource/ sound/
BUILD-MANIFEST.json
```

## GitHub Actions

工作流文件：`.github/workflows/build-packages.yml`。

`build` job 的矩阵是 8 个游戏 × Windows/Linux（16 个 job），每个 job 拉取固定 HL2SDK、构建 x86 原生文件并上传 artifact；`package` job 下载全部原生文件后按上面的命名与布局生成 8 个游戏包、源码包和 `SHA256SUMS.txt`。

使用方法：

1. 将修复后的源码推送到 GitHub。
2. 打开 **Actions → Build Source.Python packages → Run workflow**。
3. 需要发布时填写 `release_tag` 并勾选 `create_release`；工作流会从该标签 checkout 并构建，发布名也使用该标签；也可以推送 `v*` 标签自动发布。
4. 构建失败时先查看对应 matrix job；不要改用未固定的 `master` HL2SDK。

`github_proxy` 输入是可选项。直连失败时可填 `https://ghfast.top`，脚本会先尝试代理再回退官方 `codeload.github.com`。代理只用于公开源码下载，发布仍使用 GitHub 官方 artifact/release API。

## 本地一键构建

### Windows（bat）

```bat
REM 全部八个游戏 + 打包
scripts\ci\build-all.bat

REM 只构建部分游戏
scripts\ci\build-all.bat css dods

REM 只编译，不打包
scripts\ci\build-all.bat css --no-package
```

它对每个游戏依次执行 `fetch-hl2sdk.ps1` 与 `build-windows.ps1`（自动挑选 Visual Studio 自带的 CMake，校验产物是 x86 PE），最后调用 `package.ps1` 生成带日期的压缩包。结果位于 `artifacts\native\<game>\windows` 和 `dist\`。

### Linux（sh）

```bash
sudo apt-get install -y gcc-multilib g++-multilib cmake make binutils python3 libffi7:i386 zlib1g:i386
bash ./scripts/ci/build-all.sh
bash ./scripts/ci/build-all.sh css dods --no-package
```

脚本对每个游戏执行 `fetch-hl2sdk.sh` 与 `build-linux.sh`（校验产物是 ELF32 i386）；如果系统里有 `pwsh`，会顺带调用 `package.ps1` 生成带日期的压缩包，否则只产出 `artifacts/native/<game>/linux`，把 Windows 原生文件放到同一目录后在 Windows 上执行 `package.ps1` 即可。

### Windows 上用 WSL 出 Linux 包

```powershell
wsl --install -d Ubuntu
wsl -d Ubuntu -u root -- bash ./scripts/ci/build-all.sh
```

WSL 内 `/mnt/c` 的 9p 较慢，SDK 解压和编译建议在发行版内完成；产物只有几十 MB，再复制回 `artifacts/native`。CI 使用的依赖列表见工作流中的 “Install Linux x86 build dependencies”。

服务器/虚拟机上如果 WSL2 报 `HCS_E_HYPERV_NOT_INSTALLED`（嵌套虚拟化不可用），改用 WSL1：

```powershell
wsl --install -d Ubuntu --no-launch --version 1
wsl --set-default-version 1
wsl -d Ubuntu -u root -- bash ./scripts/ci/build-all.sh
```

WSL1 不依赖 Hyper-V，编译 32 位目标不受影响。

## 单个游戏构建

```powershell
Set-Location .\Source.Python-master
.\scripts\ci\fetch-hl2sdk.ps1 -Branch css -MirrorBase https://ghfast.top
.\scripts\ci\build-windows.ps1 -Branch css
.\scripts\ci\package.ps1 -Branches css -RequiredPlatforms windows -SourceArchive
```

```bash
SP_GITHUB_PROXY=https://ghfast.top bash ./scripts/ci/fetch-hl2sdk.sh css
bash ./scripts/ci/build-linux.sh css
bash ./scripts/ci/build-linux.sh hl2dm '' '' x86_64   # PR #533 的 x86-64 目标
```

Actions 中源码包使用 `git archive` 保留提交内容和 Unix 模式；本地无 Git 时使用排除规则生成 tar/ZIP，排除 `.git`、`src/hl2sdk`、`src/Builds`、`artifacts`、`dist`。

WSL1 里把源码镜像到 ext4 编译时，`src/makefiles/branch/blade.cmake` 与 `csgo.cmake` 引用 SDK 源码用的是硬编码相对路径（`hl2sdk/<branch>/public/game/shared/.../*.pb.cc`），而镜像会排除 `src/hl2sdk`；此时需要在镜像工作区的 `src/hl2sdk/<game>` 放一个指向实际 SDK 的符号链接，否则 CMake 报 `Cannot find source file`。`.wsl-tools/wsl-build.sh` 已处理该情况，或设 `SP_COPY_SDK=1` 改为整份复制。

## 回归测试

编译成功不等于已经完成游戏内验证。部署对应游戏的包后，在测试服务器使用：

```python
from events import Event

@Event('player_death')
def _player_death(event):
    event_id = event.get_int('userid')
    variable_id = event.variables.get_int('userid')
    assert variable_id == event_id, (variable_id, event_id)
```

然后分别触发 `player_death` 和 `player_spawn`，确认 `event.variables.name`、`event.variables.get_int('userid')` 和 `event['userid']` 均不崩溃且值一致。Linux 包还要求目标系统提供 32 位 `libffi.so.7`（CPython `_ctypes`）和 32 位 zlib；这些要求会记录在 `BUILD-MANIFEST.json` 的 `runtime_requirements` 中。
