# Login shells (SSH/serial) should use the same interactive setup.
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
