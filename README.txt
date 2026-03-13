IMPORTANT — Read Before First Launch
=====================================

macOS will block this app because it is not notarized with Apple.

After dragging Barkeep to Applications, open Terminal and run:

    xattr -cr /Applications/Barkeep.app

Without this step, macOS will refuse to open the app.


ABOUT
=====================================

Barkeep is a native macOS app for managing Homebrew packages.

Browse and manage your Brewfile, view package details, and run brew
commands — all from a clean three-column interface.

Brewfile view — packages grouped by section with inline search; select
any package to see description, version, dependencies, examples, and more.
Console — streaming brew command output.
Actions — install, uninstall, upgrade, or remove from Brewfile.

Defaults to ~/mrk/Brewfile; any Brewfile location can be selected.

Companion app to mrk: https://github.com/sevmorris/mrk
