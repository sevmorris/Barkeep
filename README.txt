IMPORTANT — Read Before First Launch
=====================================

macOS will block this app because it is not notarized with Apple.

After dragging Barkeep to Applications, open Terminal and run:

    xattr -cr /Applications/Barkeep.app

Without this step, macOS will refuse to open the app.


ABOUT
=====================================

Barkeep is a native macOS app for managing Homebrew packages.

Browse your installed packages, manage your Brewfile, and run brew
commands — all from a clean three-column interface.

Brewfile view — list tracked packages grouped by section; add/remove entries.
Installed view — brew list output with sync diff highlighting.
Console — streaming brew command output.

Defaults to ~/mrk/Brewfile; any Brewfile location can be selected.

Companion app to mrk: https://github.com/sevmorris/mrk
