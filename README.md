**Homebrew Manager for macOS**

Barkeep is a native macOS app for managing Homebrew packages. Browse and manage your Brewfile, view package details, and run brew commands — all from a clean three-column interface.

**[Download v1.6 (DMG)](https://github.com/sevmorris/Barkeep/releases/latest/download/Barkeep-v1.6.dmg)**

> ⚠️ **Important: Read Before First Launch**
>
> macOS will block the app because it is not notarized with Apple. After dragging Barkeep to Applications, **run this command in Terminal:**
>
> ```
> xattr -cr /Applications/Barkeep.app
> ```
>
> Without this step, macOS will refuse to open the app.

## Features

- **Brewfile view** — packages grouped by section with inline search; select any to see description, version, dependencies, examples, man page, and more
- **Console** — streaming brew command output
- **Actions** — install, uninstall, upgrade, or remove from Brewfile for any selected package
- Defaults to `~/mrk/Brewfile`; any Brewfile location can be selected

## Companion App

Barkeep is a companion to [mrk](https://github.com/sevmorris/mrk), a macOS bootstrap system. It defaults to the mrk Brewfile at `~/mrk/Brewfile` but works with any Brewfile.

## Requirements

- macOS 14.0+
- [Homebrew](https://brew.sh) installed
