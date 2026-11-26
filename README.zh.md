# rdp-release-kit

[English](README.md) · [日本語](README.ja.md) · [Français](README.fr.md) · **中文**

开源 RDP 软件的可复现、可移植构建，固定在上游发布标签上（网页客户端是预览版，
在上游 pull request 发布之前，由这些 pull request 构建）。这是一个非官方的社区构建套件：
与 FreeRDP 和 xrdp 项目没有隶属关系，也不修改任何上游源码。

## 下载

**[最新发布版](https://github.com/congzhangzh/rdp-release-kit/releases/latest)**：
通过了全部测试的最新构建，以日期命名（`20261025.1`）。
解压适合你平台的客户端，然后启动 `freerdp-tk`（Windows：双击 `freerdp-tk.cmd`；
macOS：`freerdp-tk.command`，需先清除下载文件的隔离属性，见下文），这是一个用来保存和打开连接的窗口；
它自带 Python 和 Tk，无需安装任何东西。也可以直接运行客户端：
`bin/sdl-freerdp /v:server /u:user`（Windows：`sdl-freerdp.exe`）。
发布说明中有每个平台的表格、校验和，以及如何验证文件来源。

如果要共享一台电脑自己的屏幕（Windows、Linux 或 Mac），请下载它的
`freerdp-host-*` 压缩包：见 [Shadow server：共享这台电脑自己的屏幕](#shadow-server共享这台电脑自己的屏幕)。

## Shadow server：共享这台电脑自己的屏幕

这是本套件的第一个产品，也是测试最充分的一个。FreeRDP 的 shadow server 会共享电脑当前已经显示的屏幕，
也就是正在使用它的人的桌面，任何 RDP 客户端都可以连接：
本套件的 FreeRDP 客户端和 freerdp-tk、浏览器中的 FreeRDP Web，或 Windows 自带的远程桌面连接。
它的用法类似 VNC 或远程协助，但走的是 RDP，画面采用 AV1 4:2:0，
如果显卡带有 AV1 编码器，就在显卡上编码。它不会自己启动会话；
需要这个功能的话，请看 [xrdp](README.md#xrdp-packages)。

| | Windows（优先） | Linux | macOS（Apple Silicon） |
|---|---|---|---|
| 文件 | `freerdp-host-<version>-windows-x86_64.zip`、`-windows-aarch64.zip` | `freerdp-host-<version>-linux-x86_64.tar.xz`、`-linux-aarch64.tar.xz` | `freerdp-host-<version>-macos-arm64.zip` |
| 运行方式 | Windows 服务 `freerdp-shadow-service`，以 SYSTEM 身份在控制台会话中运行服务器：登录界面和锁屏界面、UAC 提示以及 Ctrl+Alt+Del 也能共享 | [会话管理器](README.md#the-session-manager-runs-as-root) `freerdp-shadow-sesman`：以 root 身份运行的系统服务，把每个用户交给其自己 GNOME 会话（Mutter，Wayland 或 X11）里的 shadow server，并为没有 GNOME 会话的用户启动一个无显示器的 GNOME；不用 root 时，也可以用你所在桌面会话里的 systemd [用户单元](README.md#the-user-unit-your-own-desktop-no-root) `freerdp-shadow.service`：GNOME，或任何其他 X11 桌面 | 以 root 运行的 LaunchDaemon `org.freerdp.shadow.daemon`，加上在控制台会话里运行的代理（`freerdp-shadow-agent`）：先是登录窗口，然后是你的桌面，始终是同一个连接；不用 root 时，也可以用在你的登录会话中运行的 LaunchAgent（`FreeRDP-Shadow.app`） |
| AV1 4:2:0 | 显卡带有 AV1 编码器时，通过 Media Foundation 在显卡上编码（已测试：NVIDIA 笔记本 GPU），否则使用 libaom | 通过 VA-API 在显卡上编码（尚未在真实 GPU 上验证），否则使用 libaom | libaom（没有 Apple 芯片能编码 AV1） |
| 其他 | AV2（libavm）、Media Foundation 提供的 H.264 AVC420（供不支持 AV1 的客户端使用）、电脑的声音 | AV2、会话的声音（PipeWire）、通过 libei 输入按键 | AV2、VideoToolbox 提供的 H.264 和 HEVC（HEVC：服务器 `/gfx-hevc:i420`；客户端为 FreeRDP Web，在额外选项中填 `/gfx-codec-order:HEVC,AVC420`）、Mac 的声音 |
| 登录 | Windows 账户（网络级别身份验证） | 你自己的账户（PAM，通过 TLS）：会话管理器把你交给你自己的 GNOME；用户单元只接受桌面的所有者 | 本机的 macOS 账户（PAM，通过 TLS）：通过守护进程时，在登录窗口可以是除 root 以外的任何本机用户（之后像坐在 Mac 前一样在登录窗口登录），或者是控制台上的用户；LaunchAgent 只接受它自己的用户 |
| 每次发布都在 CI 中测试 | Windows Server 2025（x86_64）和 Windows 11 on ARM：AV1、Windows 登录、Ctrl+Alt+Del、锁屏界面、双显示器（x86_64）、FreeRDP Web | x86_64 和 ARM64 上的 GNOME 无显示器会话和 Xfce：会话管理器（已登录的和无显示器的 GNOME）、用户单元、AV1、AV2、按键、声音、拒绝其他账户 | GitHub 的 macOS runner：针对 LaunchAgent 的一次 AV1 会话和一次 AV2 会话，以及按下文安装的守护进程（runner 无法显示登录窗口） |

### 安装

**Windows**，在管理员的 PowerShell 中，在解压后的文件夹里：

```powershell
.\freerdp-shadow-service.exe install --allow-sas -- /bind-address:127.0.0.1 /port:3388 /gfx-av1 /gfx-av2 -gfx-avc444
```

它会立即启动，并随 Windows 一起启动，端口为 3388：shadow server 在所有系统上都监听 3388，
因此 3389 留给 Windows 自带的远程桌面。只用 AV1：用 `/gfx-av2:off` 代替 `/gfx-av2`。
`--allow-sas` 让服务可以发送 Ctrl+Alt+Del（即策略 SoftwareSASGeneration）；
如果不想要这个功能，就不要加它。用 `.\freerdp-shadow-service.exe uninstall` 卸载，
同时会把该策略恢复成安装时的状态。不使用服务、只共享已登录用户的桌面：
`.\freerdp-shadow-cli.exe /bind-address:127.0.0.1 /port:3388 /gfx-av1 /gfx-av2`。

**Linux**（GNOME），以 root 身份：会话管理器。一个服务为这台电脑的所有用户服务，在任何人登录之前就已运行；
没有 GNOME 会话的用户可以得到一个无显示器的 GNOME（详情见 [The session manager](README.md#the-session-manager-runs-as-root)）：

```sh
sudo tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz -C /opt
sudo mv /opt/freerdp-host-*-linux-$(uname -m) /opt/freerdp-host
sudo chown -R root:root /opt/freerdp-host
sudo cp /opt/freerdp-host/freerdp-shadow-sesman.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now freerdp-shadow-sesman.service
```

不用 root，或在其他 X11 桌面上：用户单元，以你自己的身份，在你想共享的桌面会话中（详情见
[The user unit](README.md#the-user-unit-your-own-desktop-no-root)）：

```sh
tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz
mkdir -p ~/.local/opt ~/.config/systemd/user
mv freerdp-host-*-linux-$(uname -m) ~/.local/opt/freerdp-host
cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now freerdp-shadow.service
```

两者都监听 3388：二选一安装。

**macOS**，解压之后，以管理员身份：守护进程方式。整台 Mac 一个服务器，在任何人登录之前就已运行：
它显示登录窗口，并在同一个连接里跟着你进入桌面：

```sh
sudo bash ./install-daemon.sh
```

它把应用装到 /Applications，把服务器作为 root 的 LaunchDaemon 运行在 127.0.0.1:3388，
并把它的代理作为 LaunchAgent 运行在登录窗口和每个会话中。然后在“系统设置 > 隐私与安全性”中，同时在
“屏幕与系统音频录制”和“辅助功能”下允许 `freerdp-shadow-agent`（在 /Applications/FreeRDP-Shadow.app/Contents/MacOS 中），
然后以你自己的身份（不用 sudo）重启代理：`launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow.agent`。这个授权在登录窗口也有效。日志：/var/log/freerdp-shadow/。用
`sudo bash /Applications/FreeRDP-Shadow.app/Contents/Resources/uninstall-daemon.sh`
卸载
（`--app` 同时删除应用，`--logs` 删除日志）。

不用 root、只共享你自己的会话：LaunchAgent 应用。

```sh
cp -R FreeRDP-Shadow.app /Applications/
xattr -dr com.apple.quarantine /Applications/FreeRDP-Shadow.app
cp org.freerdp.shadow.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.freerdp.shadow.plist
```

然后在“系统设置 > 隐私与安全性”中，同时在“屏幕与系统音频录制”和“辅助功能”下允许 FreeRDP Shadow，并重启它：
`launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow`。

两者都监听 3388：二选一安装（应用在监听时 `install-daemon.sh` 会拒绝；
`launchctl bootout gui/$(id -u)/org.freerdp.shadow` 可以停掉它）。两者都使用临时（ad hoc）签名，
所以每次更新后 macOS 都会再次询问这两项权限。

每个压缩包里的 `README.txt` 都有该平台的完整说明：日志、选项、卸载。

### 连接

三者都只监听 127.0.0.1:3388。请保持这样，并通过 SSH 访问服务器（见
[部署服务器：不要让 RDP 暴露在互联网上](#部署服务器不要让-rdp-暴露在互联网上)）：

```sh
ssh -N -L 13388:127.0.0.1:3388 user@host &
sdl-freerdp /v:127.0.0.1:13388 /u:user
```

或者在 freerdp-tk 中使用 127.0.0.1:13388。对于 FreeRDP Web，在主机上启动 WebSocket 网关
（`websockify 127.0.0.1:3390 127.0.0.1:3388`），然后转发 3390。
`freerdp-shadow-cli /codec-list` 会列出这台电脑拥有的编码器，
`/codec-first:software` 或 `/codec-first:hardware:<id>` 可以选定其中一个。日志会写出正在使用的编码器，
例如 `AV1 encoder: Media Foundation 0 NVIDIA AV1 Encoder MFT (hardware, …), libaom as fallback`。

### 它不做什么

- **保持屏幕自身的大小。** 显示器、它们的分辨率和缩放比例都保持电脑原样，
  客户端的窗口显示的就是那块屏幕，如果窗口较小则会缩小显示。
  客户端的 `/dynamic-resolution`、`/multimon` 布局和 HiDPI 缩放在这里都不起作用。
- **多个显示器，客户端只有一个窗口。** Windows 默认共享所有显示器，在客户端的一个窗口里并排显示（`/monitors:<N>` 只共享其中一个，0 是主显示器）。Mac 只共享一个显示器。Linux 默认共享一个：在 X11 上用 `/monitors:all` 可以全部共享，GNOME（Mutter）会话只共享一个。客户端里每个显示器各开一个窗口的功能还没有。
- **开启了 FileVault 的 Mac 重启后**，会在 macOS 启动之前显示磁盘解锁界面：任何 RDP 服务器都无法显示它
  （计划内的重启用 `sudo fdesetup authrestart`）。LaunchAgent 应用要在你登录之后才启动；守护进程会显示登录窗口。

如果需要会话跟随客户端的窗口和显示器（包括 HiDPI），请使用能自己启动会话的服务器：
[xrdp](README.md#xrdp-packages)，或 Pro 版 Windows 自带的远程桌面。

## 构建内容

| 产物 | 渠道 | 运行平台 |
|---|---|---|
| `sdl-freerdp`（FreeRDP 的 SDL3 客户端），带 AV1（dav1d）和 Opus，另有 [freerdp-tk](https://github.com/congzhangzh/freerdp-tk) 及其 Python | 预览版：我们的 FreeRDP 预览版，与网页客户端相同（见下面的版本固定） | Linux x86_64 / aarch64，glibc ≥ 2.34 且有 PulseAudio 的 `libpulse.so.0`：RHEL/Rocky/Alma 9、Debian 12、Ubuntu 22.04、Fedora 35 及更新版本 |
| `sdl-freerdp.exe`，Windows 版的同一个客户端，带 freerdp-tk 及其 Python | 预览版，同上 | Windows 10 和 11，x86_64 和 ARM64 |
| `sdl-freerdp`，macOS 版的同一个客户端，带 freerdp-tk 及其 Python | 预览版，同上 | macOS 12 及更新版本，Apple Silicon（arm64）；不再支持 Intel Mac（最后一个版本：20261122.6） |
| FreeRDP 网页客户端（WebAssembly），带 [freerdp-web](https://github.com/congzhangzh/freerdp-web) 页面 | 预览版：FreeRDP master + 尚未合并的 pull request（见下面的版本固定） | 较新的浏览器（已测试：Chrome）；由 GitHub Pages 提供 |
| FreeRDP 的 shadow server（`freerdp-shadow-cli`），Windows 上带 `freerdp-shadow-service`，Linux 上是会话管理器或 systemd 用户单元，macOS 上是 LaunchDaemon 及其代理，或 LaunchAgent 应用：AV1（GPU 或 libaom）、AV2、Windows 和 macOS 上的 H.264、声音 | 预览版，同样的 FreeRDP | Windows 10 和 11 x86_64 和 ARM64；Linux x86_64 / aarch64，glibc ≥ 2.34（GNOME，或任何 X11 桌面）；Apple Silicon 上的 macOS |
| xrdp + xorgxrdp 原生软件包（.deb / .rpm） | 稳定版 | x86_64 和 ARM64：Debian testing、13、12；Ubuntu 26.10、26.04、24.04；Fedora 45、44、43 |

## 更多

本 README 的其余部分只有英文，因为它每次发布都会变化：
构建与测试（[Build](README.md#build)）、版本固定（[The pins at a glance](README.md#the-pins-at-a-glance)）、
[Windows 客户端](README.md#windows-client)、[网页客户端](README.md#web-client-preview)、
[Linux 主机详解](README.md#linux-host)及其[会话管理器](README.md#the-session-manager-runs-as-root)、
[xrdp 软件包](README.md#xrdp-packages)和[不同硬件上的性能](README.md#performance-on-different-hardware)。

## 部署服务器：不要让 RDP 暴露在互联网上

RDP 服务器经常成为攻击目标，尤其是 xrdp 变化很快。
不要把 RDP 端口（3389，或 shadow server 的 3388）暴露到网络上。让服务器只监听环回接口，
并通过 SSH 访问它，SSH 本身已经处理了身份验证、密钥和暴力破解防护：

```ini
; /etc/xrdp/xrdp.ini
port=tcp://.:3389          ; 仅 127.0.0.1:3389
```

```sh
# 在客户端上
ssh -N -L 3389:127.0.0.1:3389 user@server &
sdl-freerdp /v:127.0.0.1:3389 /u:user
```

gnome-remote-desktop 和任何其他 RDP 服务器也是同样的做法。

## 许可证

本套件本身（它的脚本、工作流和文档）采用 Apache License 2.0 授权：
见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。

客户端组合了 FreeRDP（Apache-2.0）、SDL3 和 SDL3_ttf（zlib）、
FreeType（FTL）、OpenSSL（Apache-2.0）、Opus 和 dav1d（BSD）、zlib 和
jansson（MIT 风格）。它们的许可证文本在每个压缩包的
`licenses/` 目录下。
