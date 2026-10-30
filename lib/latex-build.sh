# Compile and render step of the LaTeX preview, sourced by the preview
# filter. It runs either inside the filter (an unsaved document, or
# LATEX_PREVIEW_BACKGROUND=no) or in a background worker that the filter
# starts, so BBEdit isn't blocked while LaTeX runs.
#
# build_and_render expects these variables, set by the filter:
#   work         private temporary folder; buffer.tex holds the text
#   build        the document's build folder (fixed per document)
#   last_good    file with the last good render's <main> element
#   root_path    main file on disk when previewing a chapter, else empty
#   rel_dir      the chapter's folder relative to root_dir
#   doc_name     the edited file's name
#   root_dir     folder LaTeX runs in
#   job          job name (the main file's name without .tex)
#   engine       pdflatex, xelatex or lualatex
# It writes the preview's body to $work/result.html and the <body> class
# to $work/result.class.

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Paths in LaTeX's messages point into the build folder; show them
# relative to the document instead.
tidy_paths() {
    sed -e "s#$build/shadow/##g" -e "s#$build/$job\\.tex#$doc_name#g" -e "s#$build/##g" -e "s#$root_dir/##g"
}

banner() {  # banner <class> <title> <file with messages>
    printf '<div class="banner %s"><strong>%s</strong><pre>' "$1" "$2"
    tidy_paths < "$3" | escape_html
    printf '</pre></div>\n'
}

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

render_pages() {  # prints a <main> element with the pages of $pdf
    pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/ { print $2 }')
    printf '<main>\n'
    if [ -z "$pages" ] || [ "$pages" -eq 0 ]; then
        printf '<div class="empty">This document has no pages.</div>\n'
    elif [ "${LATEX_PREVIEW_FORMAT:-svg}" = png ]; then
        rm -f "$work"/page-*.png
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

build_and_render() {
    # The buffer goes into the build folder. Files are only rewritten when
    # the text changed, which keeps latexmk's view of them unchanged
    # otherwise. The shadow folder holds only this refresh's buffer, so a
    # chapter previewed earlier can't hide its saved copy from the main file.
    rm -rf "$build/shadow"
    mkdir -p "$build/shadow"
    if [ -n "$root_path" ]; then
        source_file="$root_dir/$(basename "$root_path")"
        mkdir -p "$build/shadow/$rel_dir"
        cp "$work/buffer.tex" "$build/shadow/$rel_dir/$doc_name"
    else
        source_file="$build/$job.tex"
        cmp -s "$work/buffer.tex" "$source_file" || cp "$work/buffer.tex" "$source_file"
    fi

    # \include{chapters/intro} writes chapters/intro.aux into the build
    # folder, so the folder layout must exist there.
    (cd "$root_dir" && find . -maxdepth 3 -type d ! -name '.*' 2>/dev/null) |
        while IFS= read -r d; do mkdir -p "$build/$d"; done

    TEXINPUTS="$build/shadow:${base_texinputs:-}"
    BIBINPUTS="$root_dir:${base_bibinputs:-}"
    export TEXINPUTS BIBINPUTS
    export max_print_line=10000   # one message per log line, easier to read
    pretex='\def\bbeditpreview{}'

    if [ "${LATEX_USE_LATEXMK:-yes}" != "no" ] && command -v latexmk >/dev/null; then
        case "$engine" in
            pdflatex) mode=-pdf ;;
            xelatex) mode=-xelatex ;;
            lualatex) mode=-lualatex ;;
        esac
        # shellcheck disable=SC2086
        (cd "$root_dir" && latexmk $mode -interaction=nonstopmode -halt-on-error -file-line-error \
            -outdir="$build" -jobname="$job" -usepretex="$pretex" \
            $LATEX_PREVIEW_ARGS "$source_file") > "$work/stdout" 2>&1 < /dev/null
        status=$?
    else
        # shellcheck disable=SC2086
        (cd "$root_dir" && "$engine" -interaction=nonstopmode -halt-on-error -file-line-error \
            -output-directory="$build" -jobname="$job" \
            $LATEX_PREVIEW_ARGS "$pretex\\input{\"$source_file\"}") > "$work/stdout" 2>&1 < /dev/null
        status=$?
    fi
    log="$build/$job.log"
    pdf="$build/$job.pdf"

    if [ $status -eq 0 ] && [ -s "$pdf" ]; then
        # A refresh with nothing new (latexmk had nothing to rerun) reuses
        # the pages from last time instead of converting them again.
        stamp="$(cksum < "$pdf") ${LATEX_PREVIEW_FORMAT:-svg} ${LATEX_PREVIEW_DPI:-144}"
        if [ -f "$last_good" ] && [ "$(cat "$last_good.stamp" 2>/dev/null)" = "$stamp" ]; then
            cp "$last_good" "$work/body.html"
        else
            render_pages > "$work/body.html"
            cp "$work/body.html" "$last_good"
            printf '%s\n' "$stamp" > "$last_good.stamp"
        fi

        extract_warnings > "$work/warnings"
        {
            if [ -s "$work/warnings" ]; then
                count=$(grep -c 'Warning:' "$work/warnings")
                printf '<details class="banner warning"><summary>%s warning%s</summary><pre>' \
                    "$count" "$([ "$count" -eq 1 ] || echo s)"
                tidy_paths < "$work/warnings" | escape_html
                printf '</pre></details>\n'
            fi
            cat "$work/body.html"
        } > "$work/result.html"
        : > "$work/result.class"
    else
        extract_errors > "$work/errors"
        # No LaTeX error in the log (a BibTeX/Biber failure, say): show the
        # end of the tool's own output instead.
        [ -s "$work/errors" ] || tail -n 25 "$work/stdout" > "$work/errors"
        if [ -f "$last_good" ]; then
            {
                banner error "LaTeX error (showing last good render)" "$work/errors"
                cat "$last_good"
            } > "$work/result.html"
            echo stale > "$work/result.class"
        else
            banner error "LaTeX error" "$work/errors" > "$work/result.html"
            : > "$work/result.class"
        fi
    fi
}
