#!/bin/bash
#
# LaTeX Watch PDF: a BBEdit script (Scripts menu).
#
# Toggles `latexmk -pvc` for the front document. The first run starts a
# background watcher that rebuilds <name>.pdf next to the source on every
# save and opens the PDF; running it again on the same document stops the
# watcher. A "% !TEX root = main.tex" line makes it build the main file
# instead. Use this when you want the real PDF (with SyncTeX), or for large
# documents where the as-you-type preview filter is too slow.
#
# Set PDF_VIEWER in ~/.config/latex-bbedit-preview/config to pick the app
# (Skim reloads changed PDFs automatically; set its "Check for file
# changes" preference).

CONFIG="$HOME/.config/latex-bbedit-preview/config"
[ -f "$CONFIG" ] && . "$CONFIG"

PATH="$PATH:/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/bin"

notify() {
    osascript -e "display notification \"$1\" with title \"LaTeX Watch\"" >/dev/null 2>&1
}

magic() {  # magic <key> <file>: value of "% !TEX <key> = value" in the first 30 lines
    head -n 30 "$2" | sed -n -E "s/^[[:space:]]*%[[:space:]]*!T[eE]X[[:space:]]+(TS-)?$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\2/p" | head -n 1
}

src="$BB_DOC_PATH"
case "$src" in
    *.tex) ;;
    *) notify "Save the document as a .tex file first."; exit 1 ;;
esac
if ! command -v latexmk >/dev/null; then
    notify "latexmk not found. Install MacTeX: brew install --cask mactex-no-gui"
    exit 1
fi

root=$(magic root "$src")
if [ -n "$root" ]; then
    case "$root" in /*) ;; *) root="$(dirname "$src")/$root" ;; esac
    src=$(cd "$(dirname "$root")" && pwd)/$(basename "$root")
fi

case "$(magic program "$src" | tr '[:upper:]' '[:lower:]')" in
    xelatex) mode=-xelatex ;;
    lualatex) mode=-lualatex ;;
    pdflatex) mode=-pdf ;;
    *) case "${LATEX_ENGINE:-lualatex}" in
           xelatex) mode=-xelatex ;; pdflatex) mode=-pdf ;; *) mode=-lualatex ;;
       esac ;;
esac

state_dir="$HOME/Library/Caches/latex-bbedit-preview/watch"
mkdir -p "$state_dir"
key=$(printf '%s' "$src" | cksum | cut -d' ' -f1)
pid_file="$state_dir/$key.pid"
log_file="$state_dir/$key.log"
pdf="${src%.tex}.pdf"

if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    # latexmk runs the engine as a child; stop the whole group.
    kill -- -"$(cat "$pid_file")" 2>/dev/null || kill "$(cat "$pid_file")"
    rm -f "$pid_file"
    notify "Stopped watching $(basename "$src")"
    exit 0
fi

cd "$(dirname "$src")" || exit 1
had_pdf=$([ -f "$pdf" ] && echo yes)
# set -m puts the watcher in its own process group, so it can be stopped
# together with the LaTeX run it started.
set -m
# shellcheck disable=SC2086
nohup latexmk $mode -pvc -view=none -interaction=nonstopmode -file-line-error \
    -synctex=1 $LATEX_WATCH_ARGS "$(basename "$src")" > "$log_file" 2>&1 < /dev/null &
echo $! > "$pid_file"
notify "Watching $(basename "$src")"

# Wait for the first build (LaTeX is slower to start than typst) before
# opening the viewer.
if [ -z "$had_pdf" ]; then
    for _ in $(seq 1 60); do
        [ -f "$pdf" ] && break
        sleep 0.5
    done
fi
if [ -n "$PDF_VIEWER" ]; then
    open -g -a "$PDF_VIEWER" "$pdf"
else
    open -g "$pdf"
fi
