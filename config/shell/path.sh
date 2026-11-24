# PATH dedupe: prvo pojavljivanje zadrzava prioritet.
# Sourcuje se na kraju ~/.bashrc (posle envman/nvm) i iz ~/.bash_profile.
# Idempotentno - bezbedno pri vise sourcovanja.
PATH=$(printf '%s\n' "$PATH" | awk '!seen[$0]++' ORS=:)
PATH=${PATH%:}
export PATH
