# rdp-release-kit

[English](README.md) · **日本語** · [Français](README.fr.md) · [中文](README.zh.md)

オープンソースのRDPソフトウェアを、再現可能でポータブルな形でビルドしたものです。
アップストリームのリリースタグに固定しています(Webクライアントはプレビュー版で、
アップストリームのプルリクエストがリリースされるまでは、そのプルリクエストからビルドしています)。
これは非公式のコミュニティ製ビルドキットです。FreeRDPおよびxrdpの各プロジェクトとは
無関係で、アップストリームのソースには一切変更を加えていません。

## ダウンロード

**[最新リリース](https://github.com/congzhangzh/rdp-release-kit/releases/latest)**:
すべてのテストに合格した最新のビルドで、日付が名前になっています(`20261025.1`)。
お使いのプラットフォーム用のクライアントを展開し、`freerdp-tk` を起動してください
(Windows: `freerdp-tk.cmd` をダブルクリック。macOS: `freerdp-tk.command`。
ダウンロードしたファイルの隔離属性を解除してから実行します。下記参照)。接続の保存と
オープンを行うウィンドウです。Python と Tk は同梱されているため、別途インストールするものはありません。
クライアントを直接実行することもできます:
`bin/sdl-freerdp /v:server /u:user`(Windows: `sdl-freerdp.exe`)。
リリースノートには、プラットフォームごとの表、チェックサム、ファイルの出所を確認する方法が載っています。

コンピューター自身の画面(Windows、Linux、Mac)を共有するには、`freerdp-host-*` アーカイブを入手してください。
[シャドウサーバー](#シャドウサーバー-このコンピューターの画面そのものを共有する)を参照してください。

## シャドウサーバー: このコンピューターの画面そのものを共有する

このキットの最初の製品で、最もよくテストされています。FreeRDPのシャドウサーバーは、
コンピューターがすでに表示している画面、つまりその前にいる人のデスクトップを、任意のRDPクライアントと共有します。
クライアントには、このキットのFreeRDPクライアントとfreerdp-tk、ブラウザー上のFreeRDP Web、
Windows標準のリモートデスクトップ接続が使えます。VNCやリモートアシスタンスのように動作しますが、RDPで通信します。
映像はAV1 4:2:0で、AV1エンコーダーを備えたグラフィックスカードではそのカード上でエンコードされます。
独自のセッションは開始しません。それが必要な場合は [xrdp](README.md#xrdp-packages) を参照してください。

| | Windows(最初) | Linux | macOS(Apple Silicon) |
|---|---|---|---|
| ファイル | `freerdp-host-<version>-windows-x86_64.zip`、`-windows-aarch64.zip` | `freerdp-host-<version>-linux-x86_64.tar.xz`、`-linux-aarch64.tar.xz` | `freerdp-host-<version>-macos-arm64.zip` |
| 実行形態 | Windowsサービス `freerdp-shadow-service`。コンソールセッション上でSYSTEMとしてサーバーを実行し、ログオン画面やロック画面、UACプロンプト、Ctrl+Alt+Delにも対応します | デスクトップセッション内のsystemdユーザーユニット `freerdp-shadow.service`。GNOMEはMutter経由(WaylandまたはX11)、それ以外はX11デスクトップに対応します。オプションとして、すべてのユーザーのGNOME(ヘッドレスを含む)向けにrootの[セッションマネージャー](README.md#the-session-manager-optional-runs-as-root)も使えます | ログインセッション内のLaunchAgent(`FreeRDP-Shadow.app`) |
| AV1 4:2:0 | AV1エンコーダーがあればMedia Foundation経由でグラフィックスカード上、なければlibaom(テスト済み: NVIDIAのノートPC用GPU) | VA-API経由でグラフィックスカード上(実際のGPUでは未検証)、なければlibaom | libaom(AV1をエンコードするAppleチップはありません) |
| その他 | AV2(libavm)、AV1非対応クライアント向けにMedia FoundationのH.264 AVC420、PCの音声 | AV2、セッションの音声(PipeWire)、libei経由のキー入力 | AV2、VideoToolboxのH.264、Macの音声 |
| ログイン | Windowsアカウント(ネットワークレベル認証) | デスクトップの所有者のアカウント(PAM、TLS経由) | お使いのmacOSアカウント(PAM、TLS経由) |
| リリースごとにCIでテスト | Windows Server 2025(x86_64)とWindows 11 on ARM: AV1、Windowsログイン、Ctrl+Alt+Del、ロック画面、FreeRDP Web | x86_64とARM64上のGNOMEヘッドレスとXfce: AV1、AV2、キー入力、音声、別アカウントの拒否、セッションマネージャー | GitHubのmacOSランナー: LaunchAgentに対するAV1とAV2のセッション(ランナー自身のログインはテストできません) |

### インストール

**Windows**: 管理者のPowerShellで、展開したフォルダー内で実行します:

```powershell
.\freerdp-shadow-service.exe install --allow-sas -- /bind-address:127.0.0.1 /gfx-av1 /gfx-av2 -gfx-avc444
```

すぐに起動し、Windowsの起動時にも自動で起動します。ポートは3389です。Windows標準のリモートデスクトップが有効な場合は、
すでに3389を使用しているため、`/port:3388` を追加してください。AV1のみにする場合は、`/gfx-av2` の代わりに `/gfx-av2:off` を指定します。
`--allow-sas` は、サービスがCtrl+Alt+Delを送信できるようにします(ポリシー SoftwareSASGeneration)。
不要な場合は付けないでください。削除は `.\freerdp-shadow-service.exe uninstall` で行います。
このときポリシーも、インストール時に見つけた状態に戻ります。サービスを使わず、ログオン中のユーザーのデスクトップだけを対象にする場合:
`.\freerdp-shadow-cli.exe /bind-address:127.0.0.1 /gfx-av1 /gfx-av2`。

**Linux**: 自分のユーザーで、共有したいデスクトップセッション内で実行します
(詳細は[Linuxホストのインストール](README.md#installing-the-linux-host)):

```sh
tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz
mkdir -p ~/.local/opt ~/.config/systemd/user
mv freerdp-host-*-linux-$(uname -m) ~/.local/opt/freerdp-host
cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now freerdp-shadow.service
```

**macOS**: 展開後に実行します:

```sh
cp -R FreeRDP-Shadow.app /Applications/
xattr -dr com.apple.quarantine /Applications/FreeRDP-Shadow.app
cp org.freerdp.shadow.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.freerdp.shadow.plist
```

次に、システム設定 > プライバシーとセキュリティで、「画面とシステムオーディオの録画」と「アクセシビリティ」の両方で
FreeRDP Shadowを許可し、再起動してください:
`launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow`。アプリはアドホック署名のため、
更新のたびにmacOSが再度許可を求めます。

各アーカイブの `README.txt` に、そのプラットフォームについてのすべてが書かれています。ログ、オプション、削除方法などです。

### 接続

3つとも127.0.0.1でのみ待ち受けます。そのままにしておき、SSH経由でサーバーに接続してください
([サーバーの配備](#サーバーの配備-rdpをインターネットに公開しない)を参照):

```sh
ssh -N -L 13389:127.0.0.1:3389 user@host &
sdl-freerdp /v:127.0.0.1:13389 /u:user
```

freerdp-tkで127.0.0.1:13389を指定して接続することもできます。FreeRDP Webの場合は、ホスト上でWebSocketゲートウェイ
(`websockify 127.0.0.1:3390 127.0.0.1:3389`)を起動し、代わりに3390を転送してください。
`freerdp-shadow-cli /codec-list` で、そのコンピューターにあるエンコーダーが表示され、
`/codec-first:software` または `/codec-first:hardware:<id>` で1つを選べます。使用中のエンコーダーはログに記録されます。例:
`AV1 encoder: Media Foundation 0 NVIDIA AV1 Encoder MFT (hardware, …), libaom as fallback`。

### できないこと

- **画面そのもののサイズのままです。** モニター、その解像度、スケールは、コンピューターの設定のままで、
  クライアントのウィンドウにはその画面が表示されます(ウィンドウのほうが小さければ縮小されます)。
  クライアント側の `/dynamic-resolution`、`/multimon` のレイアウト、HiDPIスケールは、ここでは何も変えません。
- **共有するのは1台のモニターです。** 複数のモニターがあるコンピューターでは、そのうちの1台を共有します
  (`/monitors:<N>` で選べます。既定は最初の1台です)。
- **Macのログインウィンドウは表示できません。** LaunchAgentは、ログインした後に起動します。

クライアントのウィンドウやモニター(HiDPIを含む)に追従するセッションが必要な場合は、
独自のセッションを開始するサーバーを使ってください:
[xrdp](README.md#xrdp-packages)、またはProエディションのWindows標準のリモートデスクトップです。

## ビルド内容

| 成果物 | チャネル | 動作環境 |
|---|---|---|
| `sdl-freerdp`(FreeRDPのSDL3クライアント)。AV1(dav1d)とOpus対応。[freerdp-tk](https://github.com/congzhangzh/freerdp-tk)とそのPythonも含みます | プレビュー: 当方のFreeRDPプレビュー版で、Webクライアントと同じものです(下記のピン留めを参照) | glibc 2.34以上とPulseAudioの `libpulse.so.0` を備えたLinux x86_64 / aarch64: RHEL/Rocky/Alma 9、Debian 12、Ubuntu 22.04、Fedora 35以降 |
| `sdl-freerdp.exe`。同じクライアントのWindows版で、freerdp-tkとそのPythonを含みます | プレビュー、同上 | Windows 10および11、x86_64とARM64 |
| `sdl-freerdp`。同じクライアントのmacOS版で、freerdp-tkとそのPythonを含みます | プレビュー、同上 | macOS 12以降、Apple Silicon(arm64)。Intel Macはもう対象外です(最後のリリース: 20261122.6) |
| FreeRDP Webクライアント(WebAssembly)と[freerdp-web](https://github.com/congzhangzh/freerdp-web)ページ | プレビュー: FreeRDPのmaster + オープン中のプルリクエスト(下記のピン留めを参照) | 最新のブラウザー(テスト済み: Chrome)。GitHub Pagesから配信されます |
| FreeRDPのシャドウサーバー(`freerdp-shadow-cli`)。Windowsには `freerdp-shadow-service`、Linuxにはsystemdユーザーユニット、macOSにはLaunchAgentアプリが付きます: AV1(GPUまたはlibaom)、AV2、WindowsとmacOSではH.264、音声 | プレビュー、同じFreeRDP | Windows 10および11のx86_64とARM64。glibc 2.34以上のLinux x86_64 / aarch64(GNOME、または任意のX11デスクトップ)。Apple SiliconのmacOS |
| xrdp + xorgxrdpのネイティブパッケージ(.deb / .rpm) | 安定版 | x86_64とARM64: Debian testing、13、12。Ubuntu 26.10、26.04、24.04。Fedora 45、44、43 |

## その他

このREADMEの残りの部分は、リリースのたびに変わるため、英語のみです:
ビルドとテスト([Build](README.md#build))、ピン留め([The pins at a glance](README.md#the-pins-at-a-glance))、
[Windowsクライアント](README.md#windows-client)、[Webクライアント](README.md#web-client-preview)、
[Linuxホストの詳細](README.md#linux-host)とその[セッションマネージャー](README.md#the-session-manager-optional-runs-as-root)、
[xrdpパッケージ](README.md#xrdp-packages)、[性能](README.md#performance-on-different-hardware)。

## サーバーの配備: RDPをインターネットに公開しない

RDPサーバーは攻撃の標的になりやすく、特にxrdpは変更が速いです。
ポート3389をネットワークに公開しないでください。サーバーはループバックインターフェースだけで待ち受けさせ、
SSH経由で接続します。SSHは、認証、鍵、ブルートフォース対策をすでに備えています:

```ini
; /etc/xrdp/xrdp.ini
port=tcp://.:3389          ; 127.0.0.1:3389 のみ
```

```sh
# クライアント側で
ssh -N -L 3389:127.0.0.1:3389 user@server &
sdl-freerdp /v:127.0.0.1:3389 /u:user
```

gnome-remote-desktopやその他のRDPサーバーにも、同じことが当てはまります。

## ライセンス

キット本体(スクリプト、ワークフロー、ドキュメント)は、Apache License 2.0でライセンスされています:
[LICENSE](LICENSE)と[NOTICE](NOTICE)を参照してください。

クライアントは、FreeRDP(Apache-2.0)、SDL3とSDL3_ttf(zlib)、FreeType(FTL)、OpenSSL(Apache-2.0)、
Opusとdav1d(BSD)、zlibとjansson(MIT系)を組み合わせています。各ライセンス文は、各アーカイブの
`licenses/` に入っています。
