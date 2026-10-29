**Homebrew Manager for macOS**

Barkeep is a native macOS app for managing Homebrew packages. Browse and manage your Brewfile, view package details, and run brew commands — all from a clean three-column interface.

**[Download v1.15.2 (DMG)](https://github.com/sevmorris/Barkeep/releases/latest/download/Barkeep-v1.15.2.dmg)**

## Features

- **Brewfile view** — packages grouped by section with inline search; select any to see description, version, dependencies, examples, man page, and more
- **Console** — streaming brew command output
- **Actions** — install, uninstall, upgrade, or remove from Brewfile for any selected package. Uninstall asks whether to remove the Brewfile entry too
- New casks follow the Brewfile's style: `greedy: true` when most of its casks carry it
- **mrk mode** — in an mrk checkout, adds, ignores and prunes go through mrk's `sync` (below)
- Defaults to `~/mrk/Brewfile`; any Brewfile location can be selected

## Companion App

Barkeep is a companion to [mrk](https://github.com/sevmorris/mrk), a macOS bootstrap system. It defaults to the mrk Brewfile at `~/mrk/Brewfile` but works with any Brewfile.

### mrk mode

When the open Brewfile is in an mrk checkout (`scripts/sync`, `scripts/check-picker-desc` and `tools/picker/descriptions.tsv` beside it), Barkeep lets mrk's own scripts make the decisions, so it keeps mrk's checks instead of copying them:

- **Untracked** lists what `sync --check --details` reports: the packages you installed that the Brewfile lacks, without the names in `~/.mrk/sync-ignore`, and the Brewfile entries whose packages are not installed.
- **Add to Brewfile** runs `sync --add`. A cask goes under the `## Casks -` section of its app's category, which Barkeep shows before you add it; a formula goes in the section you pick. Each entry gets its mrk-picker description.
- **Ignore** runs `sync --ignore`. **Remove from Brewfile** on a package that is not installed runs `sync --prune`.
- After any other edit Barkeep makes to the Brewfile, it runs `check-picker-desc --fix`, so no description is missing or left behind.
- **Commit and Push Brewfile Changes**, in the File menu, is on at first. With it, each add and each prune runs `sync --push`: sync commits the Brewfile and the description table, and pushes that commit to GitHub when it is the one commit that GitHub does not have. Otherwise sync keeps the commit and says why in the console, and `mrk-push` pushes it. With the setting off, or an mrk whose sync does not take `--push`, Barkeep does not commit. It does not commit its other edits either: commit those with `mrk-push` or `pushall`.

Barkeep runs the scripts with the environment of an interactive login zsh, as a new Terminal window has, and shows their output in the console. It reads each line of `sync --check` by mrk's line contract: it splits the output only at a newline and each line only at a tab, and undoes the `\t`, `\n` and `\\` escapes in each field. When `sync --check` prints lines and Barkeep reads none of them, the Untracked list says that this Barkeep is older than mrk's output; it does not show itself empty, which would read as nothing untracked. The mrk toolbar badge shows the mode is on. Any other Brewfile works as before.

Before it runs `sync` or `check-picker-desc`, Barkeep reads the checkout's `scripts/mrk-contract`, which lists the options each script takes. It reads it once for each checkout, and again when the file changes. When a script does not take an option that Barkeep passes, Barkeep runs nothing and says that this mrk is older than Barkeep, with `make pull`, or, when the contract is a later version than Barkeep reads, that this Barkeep is older. When a script refuses, the alert shows the line it marks ✗, not the hint after it. An mrk from before `mrk-contract` (2026-10-29) works as before.

## Requirements

- macOS 15.0+
- [Homebrew](https://brew.sh) installed

## License
Copyright © 2026 Seven Morris.
Distributed under the [GNU General Public License v3.0](LICENSE).
