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

CONFIG="$HOME/.config/bbedit-latex-preview/config"
[ -f "$CONFIG" ] && . "$CONFIG"

# BBEdit's filter environment can have a short PATH, so also look in the
# usual install locations. /Library/TeX/texbin is where MacTeX puts its
# binaries.
PATH="$PATH:/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/bin"

work=$(mktemp -d "${TMPDIR:-/tmp}/latex-preview.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

cat > "$work/buffer.tex"

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
docwatch="$(cd "$(dirname "$self")/.." && pwd)/lib/bbedit-docwatch.sh"
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

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

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
</style>
EOF
    printf '<style>.page { width: %s; }</style>\n</head>\n' "${LATEX_PREVIEW_WIDTH:-100%}"
}

# Paths in LaTeX's messages point into the temporary build folder; show
# them relative to the document instead.
tidy_paths() {
    sed -e "s#$build/shadow/##g" -e "s#$build/$job\\.tex#$doc_name#g" -e "s#$build/##g" -e "s#$root_dir/##g"
}

banner() {  # banner <class> <title> <file with messages>
    printf '<div class="banner %s"><strong>%s</strong><pre>' "$1" "$2"
    tidy_paths < "$3" | escape_html
    printf '</pre></div>\n'
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

# --- Build folder -------------------------------------------------------

# Each document builds in its own folder under the cache, at the same path
# every time. latexmk records the paths of the files it read, so a folder
# that moved would make it redo everything (Biber and a second LaTeX run)
# on every refresh; in a fixed folder it reruns only what changed.
if [ -n "$cache_name" ]; then
    cache_key=$(printf '%s' "$cache_name" | cksum | cut -d' ' -f1)
    build="$cache_root/$cache_key"
    last_good="$cache_root/$cache_key.html"
else
    build="$work/build"
    last_good="$work/last-good.html"
fi
mkdir -p "$build"

# One refresh at a time per document, in case BBEdit starts another
# before this one ends. A lock left by a killed run is taken over.
lock="$build.lock"
tries=0
until mkdir "$lock" 2>/dev/null; do
    if ! kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null || [ $tries -ge 120 ]; then
        rm -rf "$lock"
        continue
    fi
    sleep 0.5
    tries=$((tries + 1))
done
echo $$ > "$lock/pid"
trap 'rm -rf "$work" "$lock"' EXIT

# The buffer goes into the build folder. Files are only rewritten when the
# text changed, which keeps latexmk's view of them unchanged otherwise.
put() {  # put <file>: copy the buffer there unless it already holds it
    cmp -s "$work/buffer.tex" "$1" || cp "$work/buffer.tex" "$1"
}
# The shadow folder holds only this refresh's buffer, so a chapter
# previewed earlier can't hide its saved copy from the main file.
rm -rf "$build/shadow"
mkdir -p "$build/shadow"
if [ -n "$root_path" ]; then
    mkdir -p "$build/shadow/$rel_dir"
    cp "$work/buffer.tex" "$build/shadow/$rel_dir/$doc_name"
else
    source_file="$build/$job.tex"
    put "$source_file"
fi

# \include{chapters/intro} writes chapters/intro.aux into the build
# folder, so the folder layout must exist there.
(cd "$root_dir" && find . -maxdepth 3 -type d ! -name '.*' 2>/dev/null) |
    while IFS= read -r d; do mkdir -p "$build/$d"; done

# --- Compile ----------------------------------------------------------------

export TEXINPUTS="$build/shadow:${TEXINPUTS:-}"
export BIBINPUTS="$root_dir:${BIBINPUTS:-}"
export max_print_line=10000   # one message per log line, easier to read
pretex='\def\bbeditpreview{}'

cd "$root_dir" || exit 1
if [ "${LATEX_USE_LATEXMK:-yes}" != "no" ] && command -v latexmk >/dev/null; then
    case "$engine" in
        pdflatex) mode=-pdf ;;
        xelatex) mode=-xelatex ;;
        lualatex) mode=-lualatex ;;
    esac
    # shellcheck disable=SC2086
    latexmk $mode -interaction=nonstopmode -halt-on-error -file-line-error \
        -outdir="$build" -jobname="$job" -usepretex="$pretex" \
        $LATEX_PREVIEW_ARGS "$source_file" > "$work/stdout" 2>&1 < /dev/null
    status=$?
else
    # shellcheck disable=SC2086
    "$engine" -interaction=nonstopmode -halt-on-error -file-line-error \
        -output-directory="$build" -jobname="$job" \
        $LATEX_PREVIEW_ARGS "$pretex\\input{\"$source_file\"}" > "$work/stdout" 2>&1 < /dev/null
    status=$?
fi
log="$build/$job.log"
pdf="$build/$job.pdf"

# Errors: "file:line: message" (from -file-line-error) or "! message",
# with the few context lines LaTeX prints after it.
extract_errors() {
    awk '
        /==> Fatal error occurred/ || /^Here is how much/ { n = 0; next }
        /^[^ ]*:[0-9]+: / || /^! / { n = 4; shown++ }
        n > 0 { print; n--; if ($0 == "") n = 0 }
        /^\*\*\* \(job aborted/ { print }
        shown >= 3 && n == 0 { exit }
    ' "$log" 2>/dev/null
}

extract_warnings() {
    awk '
        /^(LaTeX|Package [^ ]+|Class [^ ]+) Warning:/ && !/^LaTeX Font Warning/ {
            if (!seen[$0]++) { print; keep = 1 } else keep = 0; next
        }
        keep && /^\([^)]*\) / { print; next }
        { keep = 0 }
    ' "$log" 2>/dev/null
}

# --- Render ------------------------------------------------------------------

render_pages() {  # writes $work/body.html from $pdf
    pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/ { print $2 }')
    printf '<main>\n'
    if [ -z "$pages" ] || [ "$pages" -eq 0 ]; then
        printf '<div class="empty">This document has no pages.</div>\n'
    elif [ "${LATEX_PREVIEW_FORMAT:-svg}" = png ]; then
        pdftoppm -png -r "${LATEX_PREVIEW_DPI:-144}" "$pdf" "$work/page"
        for img in "$work"/page-*.png; do
            printf '<img class="page" alt="" src="data:image/png;base64,'
            base64 < "$img" | tr -d '\n'
            printf '">\n'
        done
    else
        # pdftocairo writes one page per SVG file, so convert the pages
        # side by side on all cores.
        seq 1 "$pages" | xargs -P "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" -I{} \
            pdftocairo -svg -f {} -l {} "$pdf" "$work/page-{}.svg"
        i=1
        while [ "$i" -le "$pages" ]; do
            # Pages go in as data-URI images rather than inline <svg> so that
            # element ids in one page's SVG can't collide with another's.
            printf '<img class="page" alt="" src="data:image/svg+xml;base64,'
            base64 < "$work/page-$i.svg" | tr -d '\n'
            printf '">\n'
            i=$((i + 1))
        done
    fi
    printf '</main>\n'
}

if ! command -v pdftocairo >/dev/null || ! command -v pdfinfo >/dev/null; then
    fail_page "poppler not found" "The preview uses poppler to turn PDF pages into images.
Install it with: brew install poppler"
fi

if [ $status -eq 0 ] && [ -s "$pdf" ]; then
    # A refresh with nothing new (latexmk had nothing to rerun) reuses the
    # pages from last time instead of converting them again.
    stamp="$(cksum < "$pdf") ${LATEX_PREVIEW_FORMAT:-svg} ${LATEX_PREVIEW_DPI:-144}"
    if [ -f "$last_good" ] && [ "$(cat "$last_good.stamp" 2>/dev/null)" = "$stamp" ]; then
        cp "$last_good" "$work/body.html"
    else
        render_pages > "$work/body.html"
        cp "$work/body.html" "$last_good"
        printf '%s\n' "$stamp" > "$last_good.stamp"
    fi

    extract_warnings > "$work/warnings"
    page_header
    printf '<body>\n'
    if [ -s "$work/warnings" ]; then
        count=$(grep -c 'Warning:' "$work/warnings")
        printf '<details class="banner warning"><summary>%s warning%s</summary><pre>' \
            "$count" "$([ "$count" -eq 1 ] || echo s)"
        tidy_paths < "$work/warnings" | escape_html
        printf '</pre></details>\n'
    fi
    cat "$work/body.html"
    printf '</body></html>\n'
else
    extract_errors > "$work/errors"
    # No LaTeX error in the log (a BibTeX/Biber failure, say): show the
    # end of the tool's own output instead.
    [ -s "$work/errors" ] || tail -n 25 "$work/stdout" > "$work/errors"
    page_header
    if [ -f "$last_good" ]; then
        printf '<body class="stale">\n'
        banner error "LaTeX error (showing last good render)" "$work/errors"
        cat "$last_good"
    else
        printf '<body>\n'
        banner error "LaTeX error" "$work/errors"
    fi
    printf '</body></html>\n'
fi
