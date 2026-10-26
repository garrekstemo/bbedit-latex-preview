#!/bin/bash
#
# Links the LaTeX preview filter and watch script into BBEdit's
# Application Support folder. The links point back at this folder, so keep
# it somewhere permanent (e.g. a git clone): a `git pull` then updates
# BBEdit with no reinstall. Pass --uninstall to remove the links. BBEdit's
# own TeX language module already handles syntax colouring, so none is
# installed.

set -e
here=$(cd "$(dirname "$0")" && pwd)
support="$HOME/Library/Application Support/BBEdit"

filter="$support/Preview Filters/LaTeX Preview.sh"
default_filter="$support/Preview Filters/DefaultFilter_TeX"
script="$support/Scripts/LaTeX Watch PDF.sh"
cache="$HOME/Library/Caches/bbedit-latex-preview"

if [ "$1" = "--uninstall" ]; then
    rm -f "$filter" "$script"
    # Only remove the default-filter link if it is ours.
    if [ "$(readlink "$default_filter" 2>/dev/null)" = "LaTeX Preview.sh" ]; then
        rm -f "$default_filter"
    fi
    [ -d "$cache" ] && rm -r "$cache"
    echo "Removed."
    exit 0
fi

mkdir -p "$support/Preview Filters" "$support/Scripts"
chmod +x "$here/Preview Filters/LaTeX Preview.sh" "$here/Scripts/LaTeX Watch PDF.sh" "$here/lib/bbedit-docwatch.sh"
ln -sfn "$here/Preview Filters/LaTeX Preview.sh" "$filter"
ln -sfn "$here/Scripts/LaTeX Watch PDF.sh" "$script"
# BBEdit applies "DefaultFilter_<language>" automatically to documents in
# that language, so .tex files get the preview without picking a filter.
if [ -e "$default_filter" ] && [ "$(readlink "$default_filter")" != "LaTeX Preview.sh" ]; then
    echo "Note: $default_filter already exists and was left alone."
else
    ln -sf "LaTeX Preview.sh" "$default_filter"
fi

echo "Linked into $support from $here"
p="$PATH:/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin"
PATH="$p" command -v latexmk >/dev/null ||
    echo "Note: no TeX found. Install MacTeX: brew install --cask mactex-no-gui"
PATH="$p" command -v pdftocairo >/dev/null ||
    echo "Note: poppler isn't installed yet. Run: brew install poppler"
echo "Open a .tex file and choose Markup > Preview in BBEdit."
