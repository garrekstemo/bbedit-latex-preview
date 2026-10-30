#!/bin/bash
#
# LaTeX Preview: a BBEdit preview filter.
#
# BBEdit pipes the current (possibly unsaved) document text to stdin and
# shows whatever HTML this script writes to stdout in its Preview window,
# refreshing as you type. We compile the text to PDF (with latexmk when
# available, so bibliographies and cross-references settle), convert each
# page to SVG with poppler's pdftocairo and wrap the pages in a small HTML
# page.
#
# BBEdit waits for the filter before it responds again, so for a saved
# document the filter prints the last render at once and compiles in a
# background worker; the page then fetches the new render itself.
#
# When the document has an error mid-edit, the last good render is kept
# on screen under an error banner, so the preview doesn't blank out while
# you type.
#
# Each document builds in a fixed folder under ~/Library/Caches, so aux
# files (.aux, .toc, .bbl, ...) persist between refreshes and latexmk
# reruns only what changed: usually a single LaTeX run.
#
# A file that is part of a larger document is previewed through its main
# file: put "% !TEX root = ../main.tex" near the top, or let the filter
# find a .tex file with \documentclass in the same or parent folder that
# includes it. The main file is read from disk, and the buffer you are
# editing is swapped in for its saved copy.
#
# Optional settings live in ~/.config/bbedit-latex-preview/config, which
# is sourced as a shell file. Recognised variables:
#   LATEX_ENGINE          lualatex (default), pdflatex or xelatex. A
#                         "% !TEX program = xelatex" line in the document wins.
#   LATEX_USE_LATEXMK     "no" to run the engine once instead of latexmk
#   LATEX_PREVIEW_ARGS    extra arguments for latexmk or the engine (word-split)
#   LATEX_PREVIEW_WIDTH   page width as CSS: "100%" fits the window (default),
#                         "700px" is a fixed size, "150%" zooms past the window
#   LATEX_PREVIEW_FORMAT  svg (default, sharp at any zoom) or png (faster for
#                         long documents)
#   LATEX_PREVIEW_DPI     resolution for png pages (default 144)
#   LATEX_PREVIEW_BACKGROUND  "no" to compile inside the filter, which makes
#                         BBEdit wait for LaTeX on every refresh

CONFIG="$HOME/.config/bbedit-latex-preview/config"
[ -f "$CONFIG" ] && . "$CONFIG"

# BBEdit's filter environment can have a short PATH, so also look in the
# usual install locations. /Library/TeX/texbin is where MacTeX puts its
# binaries.
PATH="$PATH:/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/bin"

work=$(mktemp -d "${TMPDIR:-/tmp}/latex-preview.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

cache_root="${XDG_CACHE_HOME:-$HOME/Library/Caches}/bbedit-latex-preview"
mkdir -p "$cache_root"

# Relative \input, \includegraphics and chapter previews need the
# document's folder. BBEdit doesn't tell preview filters which file they're
# rendering, and it can't answer AppleScript while a filter runs. So a
# background helper (lib/bbedit-docwatch.sh) keeps a list of BBEdit's open
# files, and we pick the .tex file whose saved text is closest to the text
# we were given.
self="$0"
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case "$link" in
        /*) self="$link" ;;
        *) self="$(dirname "$self")/$link" ;;
    esac
done
lib="$(cd "$(dirname "$self")/.." && pwd)/lib"
. "$lib/latex-build.sh"

# take_lock <pid>: one compile at a time per document. The lock is a
# symlink whose target is the holder's process id; a lock left by a
# process that died is taken over.
take_lock() {
    ln -s "$1" "$lock" 2>/dev/null && return 0
    kill -0 "$(readlink "$lock")" 2>/dev/null && return 1
    rm -f "$lock"
    ln -s "$1" "$lock" 2>/dev/null
}

# --- Background worker ---------------------------------------------------

# The filter queues the text in $build.next.tex (first line: a sequence
# number) and starts this worker, which compiles whatever is queued until
# the queue is empty. Each result is published as two small scripts that
# the open preview page fetches through bbedit-latex-serve.pl.
publish() {  # publish <sequence number>
    out="$cache_root/$cache_key"
    cp "$work/result.html" "$out.result.html.tmp" && mv "$out.result.html.tmp" "$out.result.html"
    cp "$work/result.class" "$out.result.class"
    printf '%s\n' "$1" > "$out.result.seq"
    {
        printf 'bbLatexUpdate(%s,"' "$1"
        perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\r/\\r/g; s/\n/\\n/g' "$work/result.html"
        printf '","%s");\n' "$(cat "$work/result.class")"
    } > "$out.update.js.tmp" && mv "$out.update.js.tmp" "$out.update.js"
    printf 'bbLatexState(%s);\n' "$1" > "$out.state.js.tmp" && mv "$out.state.js.tmp" "$out.state.js"
}

if [ "${1:-}" = --worker ]; then
    lock="$build.lock"
    next="$build.next.tex"
    take_lock $$ || exit 0
    trap 'rm -rf "$work"; [ "$(readlink "$lock")" = $$ ] && rm -f "$lock"' EXIT
    while :; do
        if mv "$next" "$work/queued.tex" 2>/dev/null; then
            seq=$(head -n 1 "$work/queued.tex")
            tail -n +2 "$work/queued.tex" > "$work/buffer.tex"
            build_and_render
            publish "$seq"
            cp "$work/buffer.tex" "$build.done.tex"
            continue
        fi
        rm -f "$lock"
        # Text queued while the lock was being released.
        [ -f "$next" ] && take_lock $$ && continue
        break
    done
    exit 0
fi

cat > "$work/buffer.tex"

docwatch="$lib/bbedit-docwatch.sh"
open_docs="$cache_root/open-documents.txt"
docwatch_pid="$cache_root/docwatch.pid"
if [ -x "$docwatch" ] && command -v osascript >/dev/null &&
   ! { [ -f "$docwatch_pid" ] && kill -0 "$(cat "$docwatch_pid")" 2>/dev/null; }; then
    nohup "$docwatch" "$open_docs" "$docwatch_pid" </dev/null >/dev/null 2>&1 &
fi

# closest_file < list of paths: prints the .tex file whose text is closest
# to the buffer, or nothing.
closest_file() {
    best="" best_diff=""
    while IFS= read -r candidate; do
        case "$candidate" in *.tex) ;; *) continue ;; esac
        [ -f "$candidate" ] || continue
        if cmp -s "$work/buffer.tex" "$candidate"; then
            best="$candidate"
            break
        fi
        # Skip files that share less than half their lines with the text,
        # so an unsaved new document doesn't borrow another file's folder.
        changed=$(diff "$work/buffer.tex" "$candidate" | grep -c '^[<>]')
        total=$(cat "$work/buffer.tex" "$candidate" | wc -l)
        [ $((changed * 2)) -le "$total" ] || continue
        if [ -z "$best_diff" ] || [ "$changed" -lt "$best_diff" ]; then
            best_diff="$changed"
            best="$candidate"
        fi
    done
    printf '%s' "$best"
}

doc_path="${BB_DOC_PATH:-}"
if [ -z "$doc_path" ] && [ -f "$open_docs" ]; then
    doc_path=$(closest_file < "$open_docs")
fi
# The helper's list lags a second or more behind BBEdit, and BBEdit can't
# answer it while a filter runs, so a document that was just opened (or
# reopened with its preview at launch) isn't on it yet. Ask Spotlight for
# saved .tex files that contain the buffer's most common long words
# instead (common words, so a word typed since the last save doesn't
# rule the saved copy out).
if [ -z "$doc_path" ] && command -v mdfind >/dev/null; then
    words=$(sed -e 's/%.*//' -e 's/\\[[:alpha:]]*//g' "$work/buffer.tex" | tr -cs '[:alpha:]' '\n' |
        awk 'length >= 7 { n[tolower($0)]++ } END { for (w in n) print n[w], w }' |
        sort -k1,1rn -k2 | head -n 4 | cut -d' ' -f2)
    if [ -n "$words" ]; then
        query='kMDItemFSName == "*.tex"c'
        for w in $words; do query="$query && kMDItemTextContent == \"$w\"cd"; done
        doc_path=$(mdfind -onlyin "$HOME" "$query" 2>/dev/null |
            grep -v "^$HOME/Library/" | head -n 20 | closest_file)
    fi
fi
if [ -n "$doc_path" ] && [ -d "$(dirname "$doc_path")" ]; then
    doc_dir=$(cd "$(dirname "$doc_path")" && pwd)
    doc_name=$(basename "$doc_path")
else
    # BBEdit runs filters in /, so an unsaved document builds in the
    # temporary folder rather than scanning the whole disk.
    doc_path=""
    doc_dir="$work"
    doc_name="untitled.tex"
fi

page_header() {
    cat <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  :root { color-scheme: light dark; --bg: #e8e8ea; --fg: #222; --shadow: rgba(0,0,0,.25);
          --err-bg: #fdecea; --err-fg: #8a1c12; --err-border: #e0a39c;
          --warn-bg: #fff6dd; --warn-fg: #6b4e00; --warn-border: #e6cf8a; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #2a2a2e; --fg: #ddd; --shadow: rgba(0,0,0,.6);
            --err-bg: #3d1f1c; --err-fg: #ffb4a9; --err-border: #7a3a32;
            --warn-bg: #3a3220; --warn-fg: #f3d58a; --warn-border: #6e5d2e; }
  }
  html, body { margin: 0; background: var(--bg); color: var(--fg);
               font: 13px -apple-system, system-ui, sans-serif; }
  main { padding: 12px; }
  .page { display: block; height: auto; margin: 0 auto 12px; background: #fff;
          box-shadow: 0 1px 4px var(--shadow); }
  .banner { position: sticky; top: 0; z-index: 1; margin: 0; padding: 8px 12px;
            border-bottom: 1px solid; max-height: 40vh; overflow: auto; }
  .banner pre { margin: 4px 0 0; font: 12px ui-monospace, Menlo, monospace; white-space: pre-wrap; }
  .banner summary { cursor: pointer; font-weight: bold; }
  .error { background: var(--err-bg); color: var(--err-fg); border-color: var(--err-border); }
  .warning { background: var(--warn-bg); color: var(--warn-fg); border-color: var(--warn-border); }
  .stale main { opacity: .55; }
  .empty { padding: 48px 16px; text-align: center; opacity: .6; }
  #bblatex-status { position: fixed; right: 10px; bottom: 10px; z-index: 2; padding: 3px 9px;
                    border-radius: 10px; background: var(--fg); color: var(--bg); opacity: .7; font-size: 11px; }
</style>
EOF
    printf '<style>.page { width: %s; }</style>\n</head>\n' "${LATEX_PREVIEW_WIDTH:-100%}"
}

fail_page() {  # fail_page <title> <message>
    page_header
    printf '<body><div class="banner error"><strong>%s</strong><pre>' "$1"
    printf '%s' "$2" | escape_html
    printf '</pre></div></body></html>\n'
    exit 0
}

# --- Which file to compile -------------------------------------------------

# "% !TEX root = main.tex" (the TeXShop / TeXstudio / VS Code convention).
magic() {  # magic <key> <file>: value of "% !TEX <key> = value" in the first 30 lines
    head -n 30 "$2" | sed -n -E "s/^[[:space:]]*%[[:space:]]*!T[eE]X[[:space:]]+(TS-)?$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\2/p" | head -n 1
}

root_path=""
if [ -n "$doc_path" ] && ! grep -q '^[^%]*\\documentclass' "$work/buffer.tex"; then
    root_rel=$(magic root "$work/buffer.tex")
    if [ -n "$root_rel" ]; then
        case "$root_rel" in /*) root_path="$root_rel" ;; *) root_path="$doc_dir/$root_rel" ;; esac
        [ -f "$root_path" ] || fail_page "Main file not found" \
            "The \"% !TEX root\" line points to $root_rel, which doesn't exist."
    else
        # Look for a main file next to this one or one folder up that
        # mentions this file's name in an \input, \include or \subfile.
        stem="${doc_name%.tex}"
        for candidate in "$doc_dir"/*.tex "$doc_dir"/../*.tex; do
            [ -f "$candidate" ] && [ "$candidate" != "$doc_dir/$doc_name" ] || continue
            if grep -q '^[^%]*\\documentclass' "$candidate" &&
               grep -Eq "^[^%]*\\\\(input|include|subfile)[[:space:]]*\\{[^}]*$stem(\\.tex)?\\}" "$candidate"; then
                root_path="$candidate"
                break
            fi
        done
    fi
fi

if [ -n "$root_path" ]; then
    # Compile the main file from disk, with the buffer placed in a shadow
    # folder that is searched before the document folder. TeX looks a
    # relative \input up along TEXINPUTS, so it finds the buffer first.
    root_dir=$(cd "$(dirname "$root_path")" && pwd)
    root_name=$(basename "$root_path")
    job="${root_name%.tex}"
    case "$doc_dir/" in
        "$root_dir/"*) rel_dir="${doc_dir#"$root_dir"}"; rel_dir="${rel_dir#/}" ;;
        *) rel_dir="" ;;
    esac
    source_file="$root_dir/$root_name"
    engine_source=$(magic program "$root_path")
    cache_name="$root_dir/$root_name"
else
    root_dir="$doc_dir"
    job="${doc_name%.tex}"
    [ -n "$job" ] || job=untitled
    engine_source=$(magic program "$work/buffer.tex")
    # With no known path there is nothing to tell documents apart by, so
    # don't cache: a shared entry would show another file's pages.
    cache_name="$doc_path"
    if ! grep -Eq '\\documentclass|\\begin\{document\}|\\bye' "$work/buffer.tex"; then
        fail_page "Nothing to preview" \
"This file has no \\documentclass. If it is part of a larger document,
add a line like this near the top so the preview builds the main file:

% !TEX root = ../main.tex"
    fi
fi

engine=$(printf '%s' "${engine_source:-${LATEX_ENGINE:-lualatex}}" | tr '[:upper:]' '[:lower:]')
case "$engine" in
    pdflatex|xelatex|lualatex) ;;
    *) engine=lualatex ;;
esac
command -v "$engine" >/dev/null ||
    fail_page "$engine not found" "Install MacTeX (brew install --cask mactex-no-gui), or set PATH in
$CONFIG"

if ! command -v pdftocairo >/dev/null || ! command -v pdfinfo >/dev/null; then
    fail_page "poppler not found" "The preview uses poppler to turn PDF pages into images.
Install it with: brew install poppler"
fi

# --- Build folder -------------------------------------------------------

# Each document builds in its own folder under the cache, at the same path
# every time. latexmk records the paths of the files it read, so a folder
# that moved would make it redo everything (Biber and a second LaTeX run)
# on every refresh; in a fixed folder it reruns only what changed.
base_texinputs="${TEXINPUTS:-}"
base_bibinputs="${BIBINPUTS:-}"
if [ -n "$cache_name" ]; then
    cache_key=$(printf '%s' "$cache_name" | cksum | cut -d' ' -f1)
    build="$cache_root/$cache_key"
    last_good="$cache_root/$cache_key.html"
else
    build="$work/build"
    last_good="$work/last-good.html"
fi
mkdir -p "$build"
lock="$build.lock"

# --- Unsaved documents, or LATEX_PREVIEW_BACKGROUND=no: compile here ------

# BBEdit waits for the filter, and stops responding, until it finishes.
# An unsaved document has no build folder to come back to, so it is
# compiled here; it is usually short.
if [ -z "$cache_name" ] || [ "${LATEX_PREVIEW_BACKGROUND:-yes}" = no ]; then
    tries=0
    until take_lock $$; do
        [ $tries -ge 120 ] && rm -f "$lock"
        sleep 0.5
        tries=$((tries + 1))
    done
    trap 'rm -rf "$work"; [ "$(readlink "$lock")" = $$ ] && rm -f "$lock"' EXIT
    build_and_render
    page_header
    printf '<body class="%s">\n' "$(cat "$work/result.class")"
    cat "$work/result.html"
    printf '</body></html>\n'
    exit 0
fi

# --- Saved documents: compile in the background ---------------------------

# The filter returns at once with the last render and leaves the compile
# to a background worker, so BBEdit keeps responding while LaTeX runs. The
# page then fetches the new render from bbedit-latex-serve.pl when it is
# ready.
out="$cache_root/$cache_key"
next="$build.next.tex"
shown=$(cat "$out.result.seq" 2>/dev/null || echo 0)
want="$shown"
if ! { [ -f "$out.result.html" ] && cmp -s "$work/buffer.tex" "$build.done.tex" &&
       [ ! -f "$next" ] && ! kill -0 "$(readlink "$lock" 2>/dev/null)" 2>/dev/null; }; then
    want=$(( $(cat "$out.queued" 2>/dev/null || echo 0) + 1 ))
    [ "$want" -gt "$shown" ] || want=$((shown + 1))
    echo "$want" > "$out.queued"
    { echo "$want"; cat "$work/buffer.tex"; } > "$next.$$" && mv "$next.$$" "$next"
    if ! kill -0 "$(readlink "$lock" 2>/dev/null)" 2>/dev/null; then
        export build last_good root_path rel_dir doc_name root_dir job engine \
            cache_root cache_key base_texinputs base_bibinputs
        nohup "$self" --worker </dev/null >/dev/null 2>&1 &
    fi
fi

# The helper that serves finished renders to the page.
server_info="$cache_root/server.txt"
if [ "$want" -gt "$shown" ] &&
   ! kill -0 "$(cut -d' ' -f3 "$server_info" 2>/dev/null)" 2>/dev/null; then
    rm -f "$server_info"
    nohup /usr/bin/perl "$lib/bbedit-latex-serve.pl" "$cache_root" "$server_info" \
        </dev/null >/dev/null 2>&1 &
    i=0
    while [ ! -f "$server_info" ] && [ $i -lt 20 ]; do sleep 0.05; i=$((i + 1)); done
fi
port="" token=""
[ -f "$server_info" ] && read -r port token _ < "$server_info"

page_header
printf '<body class="%s">\n<div id="bblatex">\n' "$(cat "$out.result.class" 2>/dev/null)"
if [ -f "$out.result.html" ]; then
    cat "$out.result.html"
else
    printf '<div class="empty">Compiling\342\200\246</div>\n'
fi
printf '</div>\n'
if [ "$want" -gt "$shown" ] && [ -n "$port" ]; then
    printf '<div id="bblatex-status">Updating\342\200\246</div>\n'
    cat <<SCRIPT
<script>
(function () {
  var base = "http://127.0.0.1:$port/$token/$cache_key", shown = $shown, want = $want;
  var status = document.getElementById("bblatex-status"), polls = 0, timer;
  function load(url) {
    var s = document.createElement("script");
    s.src = url;
    s.onload = s.onerror = function () { s.remove(); };
    document.head.appendChild(s);
  }
  window.bbLatexState = function (seq) {
    if (seq > shown) load(base + ".update.js?" + seq);
  };
  window.bbLatexUpdate = function (seq, html, cls) {
    if (seq <= shown) return;
    shown = seq;
    var y = window.scrollY;
    document.getElementById("bblatex").innerHTML = html;
    document.body.className = cls;
    window.scrollTo(0, y);
    if (shown >= want) { status.remove(); clearInterval(timer); }
  };
  // Give up after ten minutes, in case the compile was killed.
  timer = setInterval(function () {
    if (++polls > 1200) { clearInterval(timer); return; }
    load(base + ".state.js?" + Date.now());
  }, 500);
})();
</script>
SCRIPT
fi
printf '</body></html>\n'
