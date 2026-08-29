## RPM packaging

The package is `wallpaper-engine-kde-plugin-qt6`. Two ways to get it: install from COPR, or
build it yourself.

## Install from COPR

Replace `captsilver666` with the COPR account hosting the build.

### Bazzite / Silverblue / any rpm-ostree host

```sh
sudo dnf5 copr enable captsilver666/wallpaper-engine-kde-plugin
sudo rpm-ostree install wallpaper-engine-kde-plugin-qt6
systemctl reboot
```

Install **by package name**, never from a downloaded `.rpm` file. `rpm-ostree install ./foo.rpm`
pins that exact file forever and will never pick up a newer build — packages layered by name get
re-resolved from the repo on every `rpm-ostree upgrade`.

To pick up new builds without doing it by hand:

```sh
sudo sed -i 's/^AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf
sudo rpm-ostree reload
sudo systemctl enable --now rpm-ostreed-automatic.timer
```

New builds then download and stage into the next deployment; they go live on reboot. Note that
`uupd` and `bootc upgrade` will **not** refresh a layered RPM — they only fetch the base image.
Only `rpm-ostree upgrade` re-resolves layered packages.

### Standard Fedora

```sh
sudo dnf copr enable captsilver666/wallpaper-engine-kde-plugin
sudo dnf install wallpaper-engine-kde-plugin-qt6
```

## Build it yourself

```sh
git clone https://github.com/captsilver/wallpaper-engine-kde-plugin.git
cd wallpaper-engine-kde-plugin
sudo dnf builddep ./rpm/wek.spec

# Packs the recursive submodule tarball and stamps the version into the spec.
tools/scripts/make-srpm.sh --outdir /tmp/srpm

rpmbuild --define='_topdir /tmp/rpmbuild' --rebuild /tmp/srpm/*.src.rpm
```

`tools/scripts/build-packages.sh` wraps both steps and runs them in the Fedora distrobox.

tar reads the working tree rather than HEAD, so a build from a dirty checkout gets `.dirty`
appended to its version — the package should not claim to be a commit it isn't. COPR always builds
a fresh clone and never sees this.

You do not need to init submodules first — `make-srpm.sh` does it, recursively, every time. That
is deliberate: `git checkout` never updates submodule worktrees, so a stale checkout would
otherwise pack sources from the wrong commit without complaining.

## Setting up the COPR project

One-time, with an API token from <https://copr.fedorainfracloud.org/api/> saved to
`~/.config/copr`:

```sh
copr-cli create wallpaper-engine-kde-plugin --chroot fedora-44-x86_64

copr-cli add-package-scm wallpaper-engine-kde-plugin \
    --name wallpaper-engine-kde-plugin-qt6 \
    --clone-url https://github.com/CaptSilver/wallpaper-engine-kde-plugin.git \
    --commit main \
    --spec rpm/wek.spec \
    --type git \
    --method make_srpm \
    --webhook-rebuild on
```

Then take the webhook URL from the project's Settings → Integrations page and add it to the GitHub
repo as a webhook (content type `application/json`, push and tag events). No GitHub Actions job is
involved — the webhook is a push notification, not CI, so `tools/scripts/preflight.sh` stays the
quality gate.

One catch on tags: COPR parses the pushed tag as `PKGNAME-VERSION` to work out what to rebuild,
and this repo tags `v1.4`. Append the package name to the webhook URL so tag pushes resolve:

```
https://copr.fedorainfracloud.org/webhooks/github/<id>/<uuid>/wallpaper-engine-kde-plugin-qt6/
```

Enable a chroot per release you want to serve. `fedora-44-x86_64` is what current Bazzite needs;
`fedora-42` has been retired. `opensuse-tumbleweed-x86_64` and `mageia-10-x86_64` also build — see
below.

## Building for openSUSE and Mageia

The spec builds on Fedora, openSUSE Tumbleweed and Mageia 10 from one source. Two things make that
work.

**Dependencies are capabilities, not package names.** The three distros agree on almost nothing —
Fedora's `lz4-devel` is `liblz4-devel` on openSUSE and `lib64lz4-devel` on Mageia — but they all
generate the same `cmake()` and `pkgconfig()` capabilities from the `.cmake` and `.pc` files they
ship. Asking for `pkgconfig(liblz4)` resolves correctly everywhere, which collapses what would
otherwise be three parallel dependency lists. Only runtime `Requires` still need `%if` branches,
because those name things rpm cannot derive from `DT_NEEDED`: the Plasma shell and the QML import
modules.

**Never put a bare `%macro` in a spec comment.** rpm expands macros inside comments, and Mageia
defines `%check` as a *two-line* macro — so a comment mentioning it leaks its second line into the
preamble and the spec dies with `error: line 18: Unknown tag` before any dependency is considered.
Write `%%check` in prose. This cost a full afternoon to find; it fails nowhere else.

Verifying a spec change against all three without touching COPR:

```sh
cat rpm/wek.spec | podman run --rm -i registry.opensuse.org/opensuse/tumbleweed:latest sh -c \
    'cat > /tmp/w.spec; zypper -n install rpm-build >/dev/null 2>&1; rpmspec -q --srpm /tmp/w.spec'

cat rpm/wek.spec | podman run --rm -i docker.io/library/mageia:10 sh -c \
    'cat > /tmp/w.spec; dnf -y install rpm-build >/dev/null 2>&1; rpmspec -q --srpm /tmp/w.spec'
```

Pipe the spec in rather than bind-mounting the repo: on an SELinux host a `:Z` mount relabels your
working tree.

Use the `:10` tag for Mageia, not `:cauldron` — Cauldron has moved on to Mageia 11, so it would
test something the COPR chroot isn't.

## How COPR builds this

COPR uses the SCM source type with `--method make_srpm`, which runs `.copr/Makefile` as root in a
mock chroot **with network** — the only stage that has any. That matters because the tree carries
four levels of submodules (`src/backend_scene` has seven of its own, one on gitlab.com, and
rapidcheck/SPIRV-Reflect pull more below that), and `%prep`/`%build` are offline. All of it has to
be inside the tarball before the build starts.

Two things not to rely on:

- COPR's clone is `--recursive`, but the shallow-clone retry silently drops that flag.
- The checkout COPR runs after cloning does not refresh submodule worktrees, so building a tag
  whose gitlink differs from the default branch gets stale sources with no error.

`make-srpm.sh` re-runs `git submodule update --init --force --recursive` itself rather than trust
either one.

### Versioning

Tagged commits build as the plain version (`v1.5` → `1.5`). Everything else gets a post-release
snapshot: `1.4^20260712.10.g5c9328e` — base, commit date, **commit count**, short hash.

The count is not decoration. The usual Fedora form `1.4^YYYYMMDDgit<hash>` sorts same-day commits
by hash, so roughly half the time a newer commit compares *lower* and dnf refuses the upgrade as a
downgrade. `^` marks a post-release, so a snapshot sorts above `1.4` and below `1.5`.

Version, release and the changelog date are written into the spec as literals before rpmbuild sees
it. The SRPM stores the spec verbatim and mock re-parses it later on a builder with no git checkout
and a different clock, so anything left as `%(...)` gets evaluated in the wrong place at the wrong
time. Watch for this if you edit the spec: when rpm dislikes a changelog date it discards the
entire changelog and still exits 0. `make-srpm.sh` asserts `CHANGELOGTIME` survived.
