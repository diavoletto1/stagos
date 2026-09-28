# StagOS zsh config
# CLI-first, no framework. Stag-red prompt, git branch, sane history, toolkit aliases.

# ---- history ----
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS INC_APPEND_HISTORY

# ---- options ----
setopt AUTO_CD INTERACTIVE_COMMENTS PROMPT_SUBST NO_BEEP
bindkey -e                       # emacs keys (Ctrl+A/E/R...)

# ---- completion ----
autoload -Uz compinit && compinit -d "$HOME/.cache/zcompdump"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# ---- git branch in prompt ----
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '%F{244}(%b)%f '
zstyle ':vcs_info:*' enable git

# ---- prompt: stag ----
PROMPT='%F{160}stag%f %F{250}%1~%f ${vcs_info_msg_0_}%(?.%F{160}.%F{202})❯%f '
RPROMPT='%F{238}%*%f'

# ---- PATH ----
typeset -U path
path=("$HOME/.local/bin" /usr/local/bin $path)
export EDITOR=vim
export PATH

# ---- aliases: core ----
alias ls='ls --color=auto --group-directories-first'
alias ll='ls -lh'
alias la='ls -lha'
alias grep='grep --color=auto'
alias ip='ip -color=auto'
alias df='df -h'
alias free='free -h'
alias update='sudo pacman -Syu'

# ---- aliases: git ----
alias gs='git status -sb'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --decorate -20'
alias gd='git diff'

# ---- aliases: war-driving toolkit ----
alias ks='sudo kismet'
alias wf='sudo wifite'
alias air='sudo airodump-ng'
alias randmac='sudo macchanger -r'          # randomize MAC (needs iface down)
alias gpsmon='gpspipe -w | head'

# ---- monitor mode helpers (pass the interface, e.g. monup wlan1) ----
monup()   { sudo ip link set "$1" down && sudo iw dev "$1" set type monitor && sudo ip link set "$1" up && echo "$1 -> monitor"; }
mondown() { sudo ip link set "$1" down && sudo iw dev "$1" set type managed && sudo ip link set "$1" up && echo "$1 -> managed"; }

# ---- stag ----
alias stagpull='cd ~/stagos && git pull'
