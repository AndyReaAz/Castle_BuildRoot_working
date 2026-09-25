# NextGen engineering shell defaults.

# Keep the device runtime helpers directly accessible.
case ":$PATH:" in
    *:/opt/nextgen/platform/bin:*) ;;
    *) PATH="$PATH:/opt/nextgen/platform/bin" ;;
esac
export PATH

# Show user, host and full current working directory.
PS1='\u@\h:\w\$ '

alias ll='ls -alhF'
alias la='ls -Ah'
alias l='ls -CF'
alias dfh='df -h'
alias duh='du -h'

# Useful interactive history without rewriting it on every command.
HISTCONTROL=ignoredups:erasedups
HISTFILE=/run/root-bash-history
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend
