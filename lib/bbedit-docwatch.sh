#!/bin/bash
#
# Background helper for the LaTeX preview filter.
#
# BBEdit gives preview filters only the document text, and it can't answer
# AppleScript while a filter runs, so the filter can't ask which file it is
# rendering. This helper asks BBEdit instead, between filter runs, and
# keeps a list of the files open in BBEdit (front window first) for the
# filter to match against. It exits when BBEdit quits.
#
# Usage: bbedit-docwatch.sh <list file> <pid file>

list_file="$1"
pid_file="$2"
echo $$ > "$pid_file"
trap 'rm -f "$pid_file"' EXIT

while pgrep -xq BBEdit; do
    if docs=$(osascript \
        -e 'tell application "BBEdit"' \
        -e '    set out to ""' \
        -e '    repeat with i from 1 to count of text documents' \
        -e '        try' \
        -e '            set out to out & POSIX path of (file of text document i as alias) & linefeed' \
        -e '        end try' \
        -e '    end repeat' \
        -e '    return out' \
        -e 'end tell' 2>/dev/null); then
        printf '%s\n' "$docs" > "$list_file.tmp" && mv "$list_file.tmp" "$list_file"
    fi
    sleep 1
done
