# Wallpaper Engine for KDE

Live wallpapers from [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine), running natively in KDE Plasma 6. Scene, Web, and Video wallpapers all work, with Scene wallpapers drawn by a custom Vulkan renderer — no emulation, no Windows code involved.

This is the actively maintained continuation of the original [catsout](https://github.com/catsout/wallpaper-engine-kde-plugin) plugin, rebuilt for Plasma 6 and Qt 6 with the old Python dependency gone for good.

**Full documentation lives in the [Wiki](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki).** This README is just enough to get you running.

## Install

**Arch (AUR)** — the easy path:

```sh
yay -S wallpaper-engine-kde-plugin-new-fork
systemctl --user restart plasma-plasmashell.service
```

The AUR package is maintained separately from this repo, so its dependency list can fall behind. If the build stops on a missing package, install the list from [Arch — build from source](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Installation#arch--build-from-source) first. Already have `wallpaper-engine-kde-plugin-git`? Remove it — that's the older fork, and the two conflict.

**Fedora / Bazzite / rpm-ostree** — install from the project's [COPR](https://copr.fedorainfracloud.org/coprs/captsilver666/wallpaper-engine-kde-plugin/), which builds every change on `main`:

On standard Fedora:

```sh
sudo dnf copr enable captsilver666/wallpaper-engine-kde-plugin
sudo dnf install wallpaper-engine-kde-plugin-qt6
systemctl --user restart plasma-plasmashell.service
```

On Bazzite or Kinoite:

```sh
sudo dnf5 copr enable captsilver666/wallpaper-engine-kde-plugin
sudo rpm-ostree install wallpaper-engine-kde-plugin-qt6
systemctl reboot
```

Install it by package name, not a downloaded `.rpm` — `rpm-ostree install ./some.rpm` pins that exact file and never picks up a newer build. openSUSE Tumbleweed and Mageia 10 builds from the same COPR, and a `curl` fallback for images without `dnf5`, are in [Installation](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Installation).

**Ubuntu / Debian** — grab the `.deb` from [Releases](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/releases). You'll need Ubuntu 25.04+ or Debian Trixie+ (anything older ships a Qt that's too old):

```sh
sudo apt install ./wallpaper-engine-kde-plugin_*.deb
systemctl --user restart plasma-plasmashell.service
```

**Building from source?** That's all in the wiki: [Installation](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Installation).

## Set it up

1. Install [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine) on Steam and subscribe to a few wallpapers from the Workshop.
2. Right-click the desktop → **Configure Desktop and Wallpaper**.
3. Set **Wallpaper Type** to **Wallpaper Engine for KDE**.
4. Open the **Wallpapers** tab and click **Library**. Point it at the folder that holds your `steamapps` directory — usually `~/.local/share/Steam`, including on Bazzite, which ships Steam natively rather than as a Flatpak. If you did install Steam as a Flatpak, point at `~/.var/app/com.valvesoftware.Steam/.local/share/Steam` instead.
5. Pick a wallpaper and hit **Apply**.

Not sure which folder to point at? This lists every Steam library on disk, including the Flatpak one:

```sh
find $HOME /run/media -maxdepth 8 -name steamapps -type d 2>/dev/null
```

Per-screen wallpapers and subscribing from the Workshop are covered in [Usage](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Usage).

## What works

| Type | Rendered by | Needs |
|---|---|---|
| **Scene** (2D/3D) | custom Vulkan renderer | Wallpaper Engine assets |
| **Web** (HTML/JS) | QtWebEngine | Wallpaper Engine assets |
| **Video** | MPV by default, QtMultimedia as fallback | a video file |

The Scene renderer handles most of what Wallpaper Engine throws at it: particles, post-processing, SceneScript, audio reactivity, and text layers. The full feature breakdown is in [Scene Renderer](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Scene-Renderer).

## Requirements

To run it: KDE Plasma 6, Qt 6.7+, and a working Vulkan 1.1+ driver (AMD users want RADV). Building from source also needs a C++20 compiler — Clang is what we build with.

## Something not working?

[Troubleshooting](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Troubleshooting) covers the common ones — empty wallpaper lists, black desktops, missing audio. [Known Issues](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/wiki/Known-Issues) lists the standing quirks.

## Contributing

PRs are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the local build-and-test gate and a few house rules.

## Credits

Standing on the shoulders of [catsout](https://github.com/catsout/wallpaper-engine-kde-plugin)'s original plugin (no longer maintained) and the intermediate [RainyPixel](https://github.com/rainypixel/wallpaper-engine-kde-plugin) fork. Asset-format reference from [RePKG](https://github.com/notscuffed/repkg). Licensed GPL-2.0.

Wallpaper Engine itself is a separate, proprietary app — this project isn't affiliated with or endorsed by its developers.
