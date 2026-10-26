# LaTeX live preview for BBEdit

Live, as-you-type preview of LaTeX documents inside BBEdit's own Preview window, plus an optional "watch and open the PDF" command. It works the same way as the Typst preview in this project.

## What's included

| Piece | Linked into (`~/Library/Application Support/BBEdit/…`) | What it does |
|---|---|---|
| `Preview Filters/LaTeX Preview.sh` | `Preview Filters/` (plus a `DefaultFilter_TeX` link) | Compiles the current buffer, unsaved edits included, and shows the pages in **Markup › Preview in BBEdit**. |
| `Scripts/LaTeX Watch PDF.sh` | `Scripts/` | Toggles `latexmk -pvc` for the front document and opens the PDF (with SyncTeX) next to it. |

BBEdit already colours LaTeX syntax with its built-in TeX language module, so no language module is needed.

## Install

```sh
brew install --cask mactex-no-gui   # if you don't have TeX yet (any TeX Live works)
brew install poppler                # turns PDF pages into images for the preview
git clone https://github.com/garrekstemo/latex-bbedit-preview ~/Developer/latex-bbedit-preview
bash ~/Developer/latex-bbedit-preview/install.sh
```

The installer links BBEdit to the files in the clone rather than copying them, so keep the clone where it is. To update later, `git pull` in the clone; there's no reinstall step.

Open a `.tex` file and choose **Markup › Preview in BBEdit**. Put the preview window beside the editor; it refreshes as you type.

To remove everything: `bash install.sh --uninstall`.

## How it works

BBEdit pipes the document text to the preview filter on stdin and shows the HTML the filter prints. The filter runs `latexmk` on the buffer in a temporary folder (so nothing is written next to your file), converts each PDF page to SVG with poppler's `pdftocairo`, and puts the pages into the HTML as images.

* **Errors don't blank the preview.** When the document fails to compile mid-edit, the last good render stays on screen, dimmed, under a banner with LaTeX's error message and line number (just the error, not the whole log). Warnings, such as undefined references, are collected in a yellow bar you can click open.
* **Cross-references and bibliographies work.** `latexmk` runs BibTeX or Biber and reruns LaTeX as needed. Aux files are kept between refreshes in `~/Library/Caches/latex-bbedit-preview`, so a typical refresh is a single LaTeX run (about a second for a short article).
* **Multi-file documents work.** When you edit a chapter, the preview builds the whole document with your unsaved chapter swapped in. The main file is found from a `% !TEX root = ../main.tex` line at the top of the chapter (the TeXShop / TeXstudio / VS Code convention), or, without one, from a `.tex` file with `\documentclass` in the same or parent folder that `\input`s or `\include`s the chapter.
* **Relative paths work.** `\input`, `\includegraphics` and `\bibliography` resolve against the document's folder (taken from BBEdit's `BB_DOC_PATH`).
* **Pick the engine per document.** `% !TEX program = xelatex` (or `lualatex`) in the first lines selects the engine; the default is pdfLaTeX.
* **The document can tell it's being previewed.** `\bbeditpreview` is defined only in the preview, so `\ifdefined\bbeditpreview … \fi` can add a draft mark or skip slow parts.

Try it with `examples/demo.tex` and `examples/chapters/intro.tex`.

## Which mode to use

| | Preview filter | LaTeX Watch PDF |
|---|---|---|
| Updates | as you type | on save |
| Output | page images in BBEdit | the real PDF in Preview or Skim, with SyncTeX |
| Speed on large documents | one LaTeX run per refresh, plus page conversion | same compile, but only on save |
| Best for | writing and layout tweaks | final checks, long books and theses |

LaTeX is slower than Typst, so a long thesis (a few seconds per compile) will make the preview lag while you type. Two things help: set `LATEX_PREVIEW_FORMAT=png`, which converts pages faster, or switch to LaTeX Watch PDF with `PDF_VIEWER=Skim` and Skim's file-change checking turned on.

## Settings (optional)

Create `~/.config/latex-bbedit-preview/config`. It's a shell file, for example:

```sh
LATEX_ENGINE=lualatex          # default engine when the document doesn't say
LATEX_PREVIEW_WIDTH="100%"     # page size: 100% fits the window (default),
                               # "700px" fixed, "150%" zoom past the window
LATEX_PREVIEW_FORMAT=svg       # svg (sharp, default) or png (faster)
LATEX_PREVIEW_DPI=144          # resolution for png pages
LATEX_PREVIEW_ARGS="-shell-escape"   # extra args for latexmk (e.g. for minted)
LATEX_USE_LATEXMK=no           # run the engine once instead of latexmk
LATEX_WATCH_ARGS=""            # extra args for latexmk -pvc
PDF_VIEWER=Skim
```

## Troubleshooting

* **The preview shows plain text or HTML-escaped source.** BBEdit didn't apply the filter. Pick **LaTeX Preview** from the filter menu in the preview window's navigation bar; BBEdit remembers the choice for each document.
* **"File not found" for an image or `\input` that exists, or a chapter says "Nothing to preview".** Your BBEdit didn't pass the document path to the filter, so paths resolve against BBEdit's working directory. Please report this. A fix is to read the path through AppleScript.
* **"pdflatex not found" with MacTeX installed.** The filter looks in `/Library/TeX/texbin`. If your TeX is elsewhere, add `PATH="$PATH:/your/tex/bin"` to the config file.
* **A chapter's unsaved edits don't show.** The buffer is swapped in through `TEXINPUTS`, which works for `\input{chapters/intro}` but not for paths that start with `./` (`\input{./chapters/intro}`). Drop the `./`.
* **A stale reference or citation after a big change.** Clear the cache: `rm -r ~/Library/Caches/latex-bbedit-preview`.

## Tested

The filter, installer and watch script were tested on Linux with TeX Live 2023 (pdfLaTeX, XeLaTeX, latexmk 4.83, BibTeX) and poppler, with BBEdit's behaviour simulated (buffer on stdin, `BB_DOC_PATH` set). Tested cases: a single file with equations, references and a bibliography; editing a chapter with and without a `% !TEX root` line; errors with and without a previous good render; XeLaTeX with a folder name containing a space; the no-latexmk path; PNG output. They have not yet been run inside BBEdit on a Mac.
