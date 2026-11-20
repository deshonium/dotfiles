# dotfiles

## etc/ — root-owned, vraća se ručno
    sudo cp etc/security/limits.d/99-nocore.conf /etc/security/limits.d/
    sudo cp etc/systemd/coredump.conf.d/90-nodump.conf /etc/systemd/coredump.conf.d/
    systemd-analyze cat-config systemd/coredump.conf | grep -E 'Storage|ProcessSizeMax'

## config/ — user-owned
    mkdir -p ~/.config/user-tmpfiles.d
    cp config/user-tmpfiles.d/cache.conf ~/.config/user-tmpfiles.d/

## local/bin/
    cp local/bin/cache-clean.sh ~/.local/bin/ && chmod +x ~/.local/bin/cache-clean.sh

## Spotify keš — tri sloja
1. ~/.config/spotify/prefs      storage.size=1024   (klijent ga ignoriše)
2. cache-clean.sh               prune_to 800/150 MB (stvarni cap, dnevni tajmer)
3. user-tmpfiles.d/cache.conf   bcm:1d              (starosna mreža)

## tmpfiles age-by sintaksa
    bcm:1d      mala slova = timestampi FAJLOVA (birth, ctime, mtime)
    bcmABM:30d  velika slova = timestampi DIREKTORIJUMA (atime, birth, mtime)
    default je abcmABM — uključuje atime fajlova, pa čitanje produžava život fajla
    'bcm' namerno izbacuje 'a': preslušavanje ne sme da podmladi keš

## Pažnja: offline slušanje
    Ako uključite offline, skinuti delovi idu u ~/.cache/spotify/Storage.
    Tada `Storage bcm:1d` briše offline sadržaj svakog dana — podignite na
    bcm:30d ili uklonite tu liniju. Danas je unutra samo index.dat (7.6K),
    koji se prepisuje pri svakom pokretanju, pa linija praktično ne radi ništa.

## systemd user tajmeri (oba su deo rešenja)
    systemctl --user enable --now cache-clean.timer
    systemctl --user enable --now systemd-tmpfiles-clean.timer
    # tmpfiles: upstream timer; OnStartupSec=5min (elapsira odmah ako je prošlo),
    # OnUnitActiveSec=1d (monotonično; sat staje u suspenziji). Bez Persistent=
    # jer on radi samo uz OnCalendar=. Pre 20.11. je bio 'disabled'.

## e linija — šta stvarno briše
    e briše FAJLOVE pojedinačno (po age-by), a (pod)direktorijum samo kad
    ostane prazan: unlinkat(AT_REMOVEDIR) na neprazan vraća ENOTEMPTY i to
    se tiho preskače. Zato npr. GPUPersistentCache ne može da nestane dok
    Spotify drži svež cache.db-wal unutra.
    --dry-run ne uzima BSD flock i ne izvršava unlinkat, pa uvek prikazuje
    kandidate koje pravi run može preskočiti (lock ili ENOTEMPTY).
    Log "age-by: bcmABM" = bcm za fajlove + ABM (default) za direktorijume.

## e linija — drugi uslov za direktorijum
    Brisanje zahteva da SVI traženi timestampovi budu stariji od praga;
    bilo koji svež timestamp odlaže brisanje ("any ... will prevent cleanup").
    Za direktorijume se podrazumevano koriste ABM (atime, btime, mtime), pa:
      - svež atime (npr. ls) odlaže brisanje direktorijuma
      - rm fajla bump-uje mtime roditelja -> direktorijum kasni jedan ciklus
    Ako atime ne treba da učestvuje: bcmBM:1d (B=birth, M=mtime za direktorijume).
    btime se ne može postaviti touch-om, pa svež direktorijum ne može biti
    obrisan pre nego što mu prođe ceo prag.

## e linija — šta ostaje
    Direktorijum iz same linije se NIKAD ne briše (samo mu se štima mode/owner
    i čisti sadržaj). Dokazano: e /tmp/tf2/d - - - 0 -> /tmp/tf2/d ostaje,
    a a/b nestaju kaskadno jer su prazni.
