# rdp-release-kit

[English](README.md) · [日本語](README.ja.md) · **Français** · [中文](README.zh.md)

Des versions reproductibles et portables de logiciels RDP libres, calées sur les
étiquettes de version amont (le client web est une préversion, compilée à partir
des pull requests amont tant qu'elles ne sont pas publiées). Il s'agit d'un kit
de compilation communautaire non officiel : il n'est affilié ni au projet FreeRDP
ni au projet xrdp, et il ne modifie aucun code source amont.

## Téléchargement

**[La dernière version](https://github.com/congzhangzh/rdp-release-kit/releases/latest)** :
la build la plus récente à avoir réussi tous les tests, nommée d'après sa date (`20261025.1`).
Décompressez le client pour votre plateforme et lancez `freerdp-tk` (Windows :
double-cliquez sur `freerdp-tk.cmd` ; macOS : `freerdp-tk.command`, après avoir levé
la quarantaine du téléchargement, voir plus bas), une fenêtre pour enregistrer et ouvrir des
connexions ; il embarque son propre Python et Tk, rien à installer. Vous pouvez aussi lancer
directement le client : `bin/sdl-freerdp /v:server /u:user` (Windows : `sdl-freerdp.exe`).
Les notes de version contiennent un tableau par plateforme, les sommes de contrôle et la façon de
vérifier l'origine d'un fichier.

Pour partager l'écran d'un ordinateur (Windows, Linux ou Mac), prenez son
archive `freerdp-host-*` : voir [Serveur shadow](#serveur-shadow--partager-lécran-de-cet-ordinateur).

## Serveur shadow : partager l'écran de cet ordinateur

Le premier produit du kit, et le plus testé. Le serveur shadow de FreeRDP partage
l'écran qu'un ordinateur affiche déjà, le bureau de la personne qui l'utilise, avec n'importe quel client RDP :
les clients FreeRDP du kit et freerdp-tk, FreeRDP Web dans un navigateur, ou la Connexion Bureau
à distance de Windows. Il fonctionne comme VNC ou l'Assistance à distance, mais par RDP, avec l'image
en AV1 4:2:0, encodée sur la carte graphique lorsqu'elle dispose d'un encodeur AV1. Il ne démarre
pas de sessions propres ; pour cela, voir [xrdp](README.md#xrdp-packages).

| | Windows (en premier) | Linux | macOS (Apple Silicon) |
|---|---|---|---|
| Fichier | `freerdp-host-<version>-windows-x86_64.zip`, `-windows-aarch64.zip` | `freerdp-host-<version>-linux-x86_64.tar.xz`, `-linux-aarch64.tar.xz` | `freerdp-host-<version>-macos-arm64.zip` |
| S'exécute comme | un service Windows, `freerdp-shadow-service`, qui exécute le serveur en tant que SYSTEM sur la session console : écrans de connexion et de verrouillage, invites UAC et Ctrl+Alt+Suppr également | le [gestionnaire de sessions](README.md#the-session-manager-runs-as-root), `freerdp-shadow-sesman` : un service système root qui confie chaque utilisateur à un serveur shadow dans sa propre session GNOME (Mutter, Wayland ou X11), et démarre un GNOME sans écran pour qui n'en a pas ; ou, sans root, une [unité utilisateur](README.md#the-user-unit-your-own-desktop-no-root) systemd, `freerdp-shadow.service`, dans la session de bureau où vous êtes : GNOME, ou tout autre bureau X11 | un LaunchDaemon root, `org.freerdp.shadow.daemon`, avec un agent (`freerdp-shadow-agent`) dans la session de la console : la fenêtre de connexion, puis votre bureau, sur une seule connexion ; ou, sans root, un LaunchAgent dans votre session de connexion (`FreeRDP-Shadow.app`) |
| AV1 4:2:0 | sur la carte graphique via Media Foundation lorsqu'elle dispose d'un encodeur AV1 (testé : un GPU d'ordinateur portable NVIDIA), sinon libaom | sur la carte graphique via VA-API (pas encore éprouvé sur un vrai GPU), sinon libaom | libaom (aucune puce Apple n'encode l'AV1) |
| Aussi | AV2 (libavm), H.264 AVC420 de Media Foundation pour les clients sans AV1, le son du PC | AV2, le son de la session (PipeWire), les touches via libei | AV2, H.264 et HEVC de VideoToolbox (HEVC : serveur `/gfx-hevc:i420` ; client FreeRDP Web, options supplémentaires `/gfx-codec-order:HEVC,AVC420`), le son du Mac |
| Connexion | un compte Windows (Network Level Authentication) | votre propre compte (PAM, sur TLS) : le gestionnaire de sessions vous confie à votre propre GNOME ; l'unité utilisateur n'accepte que le propriétaire du bureau | un compte macOS local (PAM, sur TLS) : via le daemon, tout utilisateur local sauf root à la fenêtre de connexion (puis vous vous connectez sur la fenêtre de connexion, comme devant le Mac), ou l'utilisateur de la console ; le LaunchAgent n'accepte que son propre utilisateur |
| Caméra | Caméra (Windows) : la caméra d'un client connecté apparaît dans les applications Windows sous le nom « FreeRDP Camera ». Il faut Windows 11 ou Windows Server 2025 (build 22000 ou ultérieur) ; Windows Server 2022 n'a pas de caméras virtuelles. Une seule caméra à la fois, celle du premier client qui la partage ; les clients en lecture seule ne peuvent pas la partager. La caméra du client ne fonctionne que pendant qu'une application lit la caméra virtuelle. Si une application du serveur ne voit pas de caméra, autorisez-la dans Paramètres > Confidentialité et sécurité > Caméra : activez « Accès à la caméra » et « Autoriser les applications de bureau à accéder à votre caméra ». | Caméra (serveur Linux) : la caméra d'un client connecté apparaît dans les applications de cet ordinateur sous le nom « FreeRDP Camera ». Il faut le module v4l2loopback de votre distribution, chargé avec ce nom ; le README.txt de l'archive donne les commandes. La caméra du client ne fonctionne que pendant qu'une application la lit (v4l2loopback 0.13 ou ultérieur ; avec la 0.12.7 d'Ubuntu 24.04, elle fonctionne tant que le client est connecté). Une seule caméra à la fois ; les clients en lecture seule ne peuvent pas la partager. | Caméra (serveur macOS) : nécessite la version signée, pas encore publiée ; cette version du serveur n'a pas de caméra. La caméra du client macOS fonctionne. |
| Testé en CI, à chaque version | Windows Server 2025 (x86_64) et Windows 11 sur ARM : AV1, connexions Windows, Ctrl+Alt+Suppr, écran de verrouillage, deux écrans (x86_64), FreeRDP Web | GNOME headless et Xfce, sur x86_64 et ARM64 : gestionnaire de sessions (un GNOME connecté et un GNOME sans écran), unité utilisateur, AV1, AV2, touches, son, autre compte refusé | un runner macOS de GitHub : une session AV1 et une session AV2 face au LaunchAgent, et le daemon installé comme ci-dessous (le runner ne peut pas afficher sa fenêtre de connexion) |

### Installation

**Windows**, dans un PowerShell administrateur, dans le dossier décompressé :

```powershell
.\freerdp-shadow-service.exe install --allow-sas -- /bind-address:127.0.0.1 /port:3388 /gfx-av1 /gfx-av2 -gfx-avc444
```

Il démarre aussitôt et avec Windows, sur le port 3388 : le serveur shadow écoute sur 3388 sous
tous les systèmes, et 3389 reste libre pour le Bureau à distance de Windows. AV1 uniquement : `/gfx-av2:off` à la place de `/gfx-av2`.
`--allow-sas` permet au service d'envoyer Ctrl+Alt+Suppr (la stratégie SoftwareSASGeneration) ; omettez-le
si vous ne le souhaitez pas. Désinstallez-le avec `.\freerdp-shadow-service.exe uninstall`,
qui remet aussi cette stratégie dans l'état où l'installation l'avait trouvée. Sans service, pour le bureau
de l'utilisateur connecté uniquement : `.\freerdp-shadow-cli.exe /bind-address:127.0.0.1 /port:3388 /gfx-av1 /gfx-av2`.

**Linux** avec GNOME, en root : le gestionnaire de sessions. Un seul service pour tous les
utilisateurs de l'ordinateur, présent avant toute connexion ; un utilisateur sans session GNOME peut
en obtenir une sans écran (détails dans [The session manager](README.md#the-session-manager-runs-as-root)) :

```sh
sudo tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz -C /opt
sudo mv /opt/freerdp-host-*-linux-$(uname -m) /opt/freerdp-host
sudo chown -R root:root /opt/freerdp-host
sudo cp /opt/freerdp-host/freerdp-shadow-sesman.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now freerdp-shadow-sesman.service
```

Sans root, ou sur un autre bureau X11 : l'unité utilisateur, sous votre propre compte, dans la
session de bureau que vous voulez partager (détails dans [The user unit](README.md#the-user-unit-your-own-desktop-no-root)) :

```sh
tar -xJf freerdp-host-*-linux-$(uname -m).tar.xz
mkdir -p ~/.local/opt ~/.config/systemd/user
mv freerdp-host-*-linux-$(uname -m) ~/.local/opt/freerdp-host
cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now freerdp-shadow.service
```

Les deux écoutent sur 3388 : installez l'un ou l'autre.

**macOS**, après la décompression, en administrateur : le daemon. Un seul serveur pour le Mac, présent avant toute
connexion : il affiche la fenêtre de connexion et vous suit jusqu'à votre bureau sur la même connexion :

```sh
sudo bash ./install-daemon.sh
```

Il installe l'app dans /Applications, le serveur comme LaunchDaemon root sur 127.0.0.1:3388, et son agent comme
LaunchAgent à la fenêtre de connexion et dans chaque session. Autorisez ensuite `freerdp-shadow-agent`
(dans /Applications/FreeRDP-Shadow.app/Contents/MacOS) dans Réglages Système > Confidentialité et sécurité, à la fois
sous Enregistrement de l'écran et de l'audio système et sous Accessibilité, puis redémarrez l'agent, sous votre propre
compte (sans sudo) : `launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow.agent`. L'autorisation vaut aussi à la fenêtre de connexion. Journaux : /var/log/freerdp-shadow/. Désinstallez-le avec
`sudo bash /Applications/FreeRDP-Shadow.app/Contents/Resources/uninstall-daemon.sh`
(`--app` retire aussi
l'app, `--logs` ses journaux).

Sans root, pour votre propre session seulement : l'app LaunchAgent.

```sh
cp -R FreeRDP-Shadow.app /Applications/
xattr -dr com.apple.quarantine /Applications/FreeRDP-Shadow.app
cp org.freerdp.shadow.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.freerdp.shadow.plist
```

Autorisez ensuite FreeRDP Shadow dans Réglages Système > Confidentialité et sécurité, à la fois sous Enregistrement de
l'écran et de l'audio système et sous Accessibilité, puis redémarrez-le :
`launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow`.

Les deux écoutent sur 3388 : installez l'un ou l'autre (`install-daemon.sh` refuse tant que l'app écoute ;
`launchctl bootout gui/$(id -u)/org.freerdp.shadow` l'arrête). Les deux sont signés ad hoc, si bien que macOS
redemande les deux autorisations après chaque mise à jour.

Le `README.txt` de chaque archive donne tous les détails pour sa plateforme : journaux, options, désinstallation.

### Connexion

Les trois n'écoutent que sur 127.0.0.1:3388. Gardez-le ainsi, et accédez au serveur par SSH (voir
[Déploiement d'un serveur](#déploiement-dun-serveur--ne-pas-exposer-rdp-sur-internet)) :

```sh
ssh -N -L 13388:127.0.0.1:3388 user@host &
sdl-freerdp /v:127.0.0.1:13388 /u:user
```

Ou utilisez freerdp-tk avec 127.0.0.1:13388. Pour FreeRDP Web, démarrez une passerelle WebSocket sur
l'hôte (`websockify 127.0.0.1:3390 127.0.0.1:3388`) et redirigez plutôt le port 3390.
`freerdp-shadow-cli /codec-list` affiche les encodeurs dont dispose l'ordinateur, et
`/codec-first:software` ou `/codec-first:hardware:<id>` en choisit un. Le journal indique l'encodeur
utilisé, par exemple : `AV1 encoder: Media Foundation 0 NVIDIA AV1 Encoder MFT (hardware, …), libaom as fallback`.

### Ce qu'il ne fait pas

- **Il conserve la taille propre de l'écran.** Les moniteurs, leur résolution et leur échelle restent
  tels que l'ordinateur les a, et la fenêtre du client montre cet écran, réduit s'il est plus petit.
  Les options `/dynamic-resolution`, la disposition `/multimon` et l'échelle HiDPI d'un client ne changent rien ici.
- **Une fenêtre par écran seulement dans le client SDL.** Windows partage tous ses écrans par défaut (`/monitors:<N>` n'en partage qu'un ; 0 est l'écran principal). Un Mac partage un seul écran. Linux en partage un par défaut : sous X11, `/monitors:all` les partage tous, et une session GNOME (Mutter) en partage un. Quand le serveur partage plusieurs écrans, le client SDL avec `/multimon` affiche chacun dans sa propre fenêtre, sur un écran du client (avec des bandes noires si les tailles diffèrent) ; sans `/multimon`, et dans FreeRDP Web et freerdp-tk, ils sont côte à côte dans une seule fenêtre.
- **Un Mac redémarré avec FileVault activé** affiche l'écran de déverrouillage du disque avant le démarrage de macOS :
  aucun serveur RDP ne peut l'afficher (`sudo fdesetup authrestart` pour les redémarrages prévus). L'app LaunchAgent
  ne démarre qu'une fois que vous êtes connecté ; le daemon affiche la fenêtre de connexion.

Pour une session qui suit les fenêtres et les moniteurs du client, HiDPI compris, utilisez un serveur
qui démarre ses propres sessions : [xrdp](README.md#xrdp-packages), ou le Bureau à distance de Windows sur
une édition Pro.

## Ce que le kit construit

| Artefact | Canal | S'exécute sur |
|---|---|---|
| `sdl-freerdp` (le client SDL3 de FreeRDP), avec AV1 (dav1d) et Opus, plus [freerdp-tk](https://github.com/congzhangzh/freerdp-tk) et son Python | préversion : notre préversion de FreeRDP, la même que celle du client web (voir les versions épinglées plus bas) | Linux x86_64 / aarch64 avec glibc ≥ 2.34 et `libpulse.so.0` de PulseAudio : RHEL/Rocky/Alma 9, Debian 12, Ubuntu 22.04, Fedora 35 et plus récentes |
| `sdl-freerdp.exe`, le même client pour Windows, avec freerdp-tk et son Python | préversion, la même | Windows 10 et 11, x86_64 et ARM64 |
| `sdl-freerdp`, le même client pour macOS, avec freerdp-tk et son Python | préversion, la même | macOS 12 et plus récent, Apple Silicon (arm64) ; plus les Mac Intel (la dernière : version 20261122.6) |
| Client web FreeRDP (WebAssembly) avec la page [freerdp-web](https://github.com/congzhangzh/freerdp-web) | préversion : FreeRDP master + pull requests ouvertes (voir les versions épinglées plus bas) | un navigateur récent (testé : Chrome) ; servi depuis GitHub Pages |
| Le serveur shadow de FreeRDP (`freerdp-shadow-cli`), avec `freerdp-shadow-service` sous Windows, le gestionnaire de sessions ou une unité utilisateur systemd sous Linux, un LaunchDaemon et son agent, ou une app LaunchAgent, sous macOS : AV1 (GPU ou libaom), AV2, H.264 sous Windows et macOS, son | préversion, le même FreeRDP | Windows 10 et 11 x86_64 et ARM64 ; Linux x86_64 / aarch64 avec glibc ≥ 2.34 (GNOME, ou tout bureau X11) ; macOS sur Apple Silicon |
| Paquets natifs xrdp + xorgxrdp (.deb / .rpm) | stable | x86_64 et ARM64 : Debian testing, 13, 12 ; Ubuntu 26.10, 26.04, 24.04 ; Fedora 45, 44, 43 |

## Plus

Le reste de ce README n'existe qu'en anglais, car il change à chaque version : compilation
et tests ([Build](README.md#build)), les versions épinglées ([The pins at a glance](README.md#the-pins-at-a-glance)),
le [client Windows](README.md#windows-client), le [client web](README.md#web-client-preview),
l'[hôte Linux en détail](README.md#linux-host) et son [gestionnaire de sessions](README.md#the-session-manager-runs-as-root),
les [paquets xrdp](README.md#xrdp-packages) et les [performances](README.md#performance-on-different-hardware).

## Déploiement d'un serveur : ne pas exposer RDP sur Internet

Les serveurs RDP sont une cible d'attaque fréquente, et xrdp en particulier évolue
rapidement. N'exposez pas un port RDP (3389, ou le 3388 du serveur shadow) au réseau. Faites écouter le serveur sur
l'interface de bouclage uniquement, et accédez-y par SSH, qui gère déjà
l'authentification, les clés et la protection contre la force brute :

```ini
; /etc/xrdp/xrdp.ini
port=tcp://.:3389          ; 127.0.0.1:3389 only
```

```sh
# on the client
ssh -N -L 3389:127.0.0.1:3389 user@server &
sdl-freerdp /v:127.0.0.1:3389 /u:user
```

Cela vaut aussi pour gnome-remote-desktop et tout autre serveur RDP.

## Licences

Le kit lui-même (ses scripts, workflows et documents) est placé sous
la licence Apache 2.0 : voir [LICENSE](LICENSE) et [NOTICE](NOTICE).

Le client combine FreeRDP (Apache-2.0), SDL3 et SDL3_ttf (zlib),
FreeType (FTL), OpenSSL (Apache-2.0), Opus et dav1d (BSD), zlib et
jansson (style MIT). Le texte de leurs licences se trouve dans chaque archive sous
`licenses/`.
