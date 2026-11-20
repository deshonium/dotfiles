# dotfiles

## etc/ — root-owned, vraća se ručno
    sudo cp etc/security/limits.d/99-nocore.conf /etc/security/limits.d/
    sudo cp etc/systemd/coredump.conf.d/90-nodump.conf /etc/systemd/coredump.conf.d/
    systemd-analyze cat-config systemd/coredump.conf | grep -E 'Storage|ProcessSizeMax'

## local/bin/
    cp local/bin/cache-clean.sh ~/.local/bin/ && chmod +x ~/.local/bin/cache-clean.sh

## Spotify keš — tri sloja
1. ~/.config/spotify/prefs      storage.size=1024   (klijent ga ignoriše)
2. cache-clean.sh               prune_to 800/150 MB (stvarni cap, dnevni tajmer)
3. user-tmpfiles.d/cache.conf   bcm:1d              (starosna mreža)
