# Prompts, for the one script here that is a conversation rather than a command.
#
# Sourced by tools/new-panel.sh. Kept out of lib/common.sh on purpose: every
# other script in this repository must run unattended, and a helper that blocks
# on a human is the wrong thing to have within easy reach of them.
#
# All of these read from /dev/tty rather than stdin. That matters because the
# wizard is often reached through a pipe - over adb, or from another script -
# and a prompt that reads a piped stdin consumes the data instead of asking.

ask_ready() {
    [ -r /dev/tty ] || die "this needs a terminal to ask questions on.
    Run it directly rather than through a pipe, or use the individual
    scripts: tools/capture-panel.sh, then scripts/16-install-derived-panel.sh."
}

# ask_yn "question" [default y|n] -> returns 0 for yes
ask_yn() {
    _q=$1; _def=${2:-n}
    case "$_def" in
        y) _hint="[Y/n]" ;;
        *) _hint="[y/N]" ;;
    esac
    while :; do
        printf '%s  %s %s ' "$C_BLD" "$_q" "$_hint" > /dev/tty
        printf '%s' "$C_OFF" > /dev/tty
        read -r _a < /dev/tty || _a=
        [ -z "$_a" ] && _a=$_def
        case "$_a" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) say "  please answer y or n" ;;
        esac
    done
}

# ask_text "question" "default" -> echoes the answer
ask_text() {
    _q=$1; _def=${2:-}
    if [ -n "$_def" ]; then
        printf '%s  %s [%s] %s' "$C_BLD" "$_q" "$_def" "$C_OFF" > /dev/tty
    else
        printf '%s  %s %s' "$C_BLD" "$_q" "$C_OFF" > /dev/tty
    fi
    read -r _a < /dev/tty || _a=
    [ -z "$_a" ] && _a=$_def
    printf '%s' "$_a"
}

# ask_menu "question" item1 item2 ...  -> echoes the chosen item
#
# Numbered rather than free text, because the things being chosen between here
# are compatible strings, and a typo in one of those produces a panel that
# fails to bind with nothing obviously wrong.
ask_menu() {
    _q=$1; shift
    _n=0
    for _it in "$@"; do
        _n=$((_n + 1))
        printf '    %2d) %s\n' "$_n" "$_it" > /dev/tty
    done
    printf '\n' > /dev/tty
    while :; do
        printf '%s  %s [1-%d] %s' "$C_BLD" "$_q" "$_n" "$C_OFF" > /dev/tty
        read -r _a < /dev/tty || _a=
        case "$_a" in
            ''|*[!0-9]*) ;;
            *) if [ "$_a" -ge 1 ] && [ "$_a" -le "$_n" ]; then
                   eval "printf '%s' \"\${$_a}\""
                   return 0
               fi ;;
        esac
        say "  please choose a number between 1 and $_n"
    done
}
