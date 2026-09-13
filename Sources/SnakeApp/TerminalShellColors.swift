import Foundation

/// Session-local setup. Only literal, validated ls alias definitions may be changed.
/// No remote configuration files, credential material, eval of aliases or forced colors.
enum TerminalShellColors {
    static let defaults = [
        "di=34", "ln=36", "ex=32", "or=31", "pi=33", "so=35",
        "*.zip=35", "*.gz=35", "*.tar=35", "*.xz=35", "*.7z=35",
        "*.swift=32", "*.rs=32", "*.py=32", "*.js=32", "*.ts=32", "*.sh=32",
        "*.json=33", "*.yaml=33", "*.yml=33", "*.toml=33", "*.conf=33"
    ]

    static func command(for shell: String) -> String? {
        let script: String
        switch shell.lowercased() {
        case "bash", "zsh": script = posix(shell: shell.lowercased())
        case "fish": script = fish
        default: return nil
        }
        // Retain grammar line boundaries: a one-line script can exceed the remote
        // canonical TTY input limit. The complete function is defined before calling it.
        return " " + script + "\n"
    }

    private static func posix(shell: String) -> String {
        let words = shell == "zsh" ? "${=definition}" : "$definition"
        return #"""
        __snake_colors_v1() {
            local flag entry key name definition output word skip changed;
            if [ -n "${NO_COLOR-}" ]; then printf '%s\n' '[Snake] NO_COLOR 已设置，保留原有文件颜色。'; return 0; fi;
            if command ls --version >/dev/null 2>&1 && command ls --color=auto -d . >/dev/null 2>&1; then flag='--color=auto';
            elif command ls -G -d . >/dev/null 2>&1; then flag='-G';
            else printf '%s\n' '[Snake] 当前 ls 不支持已知彩色选项，已跳过。'; return 0; fi;
            for entry in \\DEFAULTS; do key=${entry%%=*}; case ":${LS_COLORS-}:" in *":$key="*) ;; *) LS_COLORS="${LS_COLORS:+$LS_COLORS:}$entry";; esac; done;
            export LS_COLORS;
            if [ "$flag" = '-G' ]; then export CLICOLOR=1; if [ -z "${LSCOLORS-}" ]; then export LSCOLORS='exfxcxdxbxegedabagacad'; fi; fi;
            if [ -z "${COLORTERM-}" ]; then export COLORTERM=truecolor; fi;
            for name in ls ll; do
                if typeset -f "$name" >/dev/null 2>&1; then printf '[Snake] 保留 %s 自定义函数，未自动调整颜色。\n' "$name"; continue; fi;
                if output=$(alias "$name" 2>/dev/null); then
                    definition=${output#*=}; definition=${definition#\'}; definition=${definition%\'};
                    case "$definition" in 'command ls'|'command ls '*) definition=${definition#command };; esac;
                    case "$definition" in ls|'ls '*) ;; *) printf '[Snake] 保留 %s 自定义别名。\n' "$name"; continue;; esac;
                    case "$definition" in *[!a-zA-Z0-9\ =_-]*) printf '[Snake] 保留 %s 复杂别名。\n' "$name"; continue;; esac;
                    skip=0;
                    for word in \\WORDS; do case "$word" in ls) ;; --color=never|--color=none|--|--color) skip=1;; -*) ;; *) skip=1;; esac; done;
                    if [ "$skip" = 1 ]; then printf '[Snake] 保留 %s 原有选项，未自动调整颜色。\n' "$name"; continue; fi;
                elif [ "$name" = ll ]; then
                    if command -v ll >/dev/null 2>&1; then printf '%s\n' '[Snake] 保留现有 ll 命令。'; continue; fi;
                    definition='ls -l';
                else definition=ls; fi;
                if [ "$name" = ll ] && typeset -f ls >/dev/null 2>&1; then printf '%s\n' '[Snake] ls 为自定义函数，未创建或修改 ll。'; continue; fi;
                case "$definition" in *" $flag") ;; *) definition="$definition $flag";; esac;
                alias "$name=command $definition";
            done;
        }; __snake_colors_v1 || printf '%s\n' '[Snake] 彩色文件列表初始化未完成，连接仍可使用。'; unset -f __snake_colors_v1;
        """#.replacingOccurrences(of: #"\\DEFAULTS"#, with: defaults.map { "'\($0)'" }.joined(separator: " "))
            .replacingOccurrences(of: #"\\WORDS"#, with: words)
    }

    private static var fish: String {
        #"""
        function __snake_colors_v1;
            if set -q NO_COLOR; and test -n "$NO_COLOR"; printf '%s\n' '[Snake] NO_COLOR 已设置，保留原有文件颜色。'; return 0; end;
            set -l flag;
            if command ls --version >/dev/null 2>&1; and command ls --color=auto -d . >/dev/null 2>&1; set flag --color=auto;
            else if command ls -G -d . >/dev/null 2>&1; set flag -G;
            else; printf '%s\n' '[Snake] 当前 ls 不支持已知彩色选项，已跳过。'; return 0; end;
            for entry in \\DEFAULTS;
                set -l key (string split -m 1 = -- "$entry")[1]; set -l found 0;
                for existing in (string split : -- "$LS_COLORS"); if test (string split -m 1 = -- "$existing")[1] = "$key"; set found 1; end; end;
                if test $found = 0; if test -n "$LS_COLORS"; set -gx LS_COLORS "$LS_COLORS:$entry"; else; set -gx LS_COLORS "$entry"; end; end;
            end;
            if test "$flag" = -G; set -gx CLICOLOR 1; if not set -q LSCOLORS; or test -z "$LSCOLORS"; set -gx LSCOLORS exfxcxdxbxegedabagacad; end; end;
            if not set -q COLORTERM; or test -z "$COLORTERM"; set -gx COLORTERM truecolor; end;
            for name in ls ll;
                set -l definition;
                if functions -q "$name";
                    set -l lines (functions "$name");
                    if not string match -rq -- "--description .*alias " $lines; printf '[Snake] 保留 %s 自定义函数，未自动调整颜色。\n' "$name"; continue; end;
                    set -l body (string trim -- $lines | string match -rv '^(#|function |end$|$)');
                    if test (count $body) != 1; or not string match -rq '^((command )?ls)( +-[a-zA-Z0-9=_-]+)* +\$argv$' -- "$body";
                        printf '[Snake] 保留 %s 复杂别名。\n' "$name"; continue;
                    end;
                    set definition (string replace -r ' +\$argv$' '' -- "$body");
                    set definition (string replace -r '^command ' '' -- "$definition");
                    if string match -rq -- '(^| )(--color=(never|none)|--color|--)( |$)' "$definition";
                        printf '[Snake] 保留 %s 原有选项，未自动调整颜色。\n' "$name"; continue;
                    end;
                else if test "$name" = ll;
                    if command -q ll; printf '%s\n' '[Snake] 保留现有 ll 命令。'; continue; end;
                    set definition 'ls -l';
                else; set definition ls; end;
                if test "$name" = ll; and functions -q ls;
                    if not string match -rq -- "--description .*alias " (functions ls); printf '%s\n' '[Snake] ls 为自定义函数，未创建或修改 ll。'; continue; end;
                end;
                if not string match -q -- "* $flag" "$definition"; set definition "$definition $flag"; end;
                alias "$name" "command $definition";
            end;
        end; __snake_colors_v1; or printf '%s\n' '[Snake] 彩色文件列表初始化未完成，连接仍可使用。'; functions -e __snake_colors_v1;
        """#.replacingOccurrences(of: #"\\DEFAULTS"#, with: defaults.map { "'\($0)'" }.joined(separator: " "))
    }
}
