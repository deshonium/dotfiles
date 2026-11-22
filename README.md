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
      - rm fajla bump-uje mtime roditelja, ali SAM tmpfiles to ponistava:
        futimens() vraca snimljene atime/mtime na kraju obrade direktorijuma
        (log 'Would restore/Restoring ... access and modification time').
        Zato njegova brisanja ne odlazu roditelja; samo spoljni rm to radi.
    Ako atime ne treba da učestvuje: bcmBM:1d (B=birth, M=mtime za direktorijume).
    btime se ne može postaviti touch-om, pa svež direktorijum ne može biti
    obrisan pre nego što mu prođe ceo prag.

## e linija — šta ostaje
    Direktorijum iz same linije se NIKAD ne briše (samo mu se štima mode/owner
    i čisti sadržaj). Dokazano: e /tmp/tf2/d - - - 0 -> /tmp/tf2/d ostaje,
    a a/b nestaju kaskadno jer su prazni.

## restore — systemd uniti
    cp config/systemd/user/cache-clean.{service,timer} ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now cache-clean.timer systemd-tmpfiles-clean.timer
    # provera: systemctl --user list-timers 'cache-clean*' 'systemd-tmpfiles*' --all
    # Description je 'Spotify keš: prune_to granica veličine' (ne tmpfiles)

## journal: odsustvo "Removing" NIJE dokaz da nista nije obrisano
    tmpfiles loguje stvarno brisanje na DEBUG nivou:
      log_action("Would remove", "Removing", ...) ->
      log_full(arg_dry_run ? LOG_INFO : LOG_DEBUG, ...)
    Dokazano 21/22.11.2026: 0 linija "Removing", a Data 753MB -> 110MB.
    Meri se efektom (du pre/posle, najstariji mtime), ne brojem log linija.

## tmpfiles user tajmer: "Daily" je netacno, radi na svaki boot
    /usr/lib/systemd/user/systemd-tmpfiles-clean.timer je verbatim upstream:
      [Timer] OnStartupSec=5min ; OnUnitActiveSec=1d
    (system varijanta ima OnBootSec=15min - nije ovo.)
    OnStartupSec opali 5 min posle svakog starta user manager-a, a
    OnUnitActiveSec=1d se meri od poslednje aktivacije -> svaki boot
    pomeri NEXT za 24h, pa 1d prakticno nikad ne istekne.
    Izmereno: runovi 21.11 11:55:27, 21.11 21:20:49, 22.11 04:26:09,
    22.11 06:19:55 (uptime -s = 06:14:35) - svaki boot + 5 min.
    Brisanje 753->110MB desilo se u 11:55:27 (fajlovi od 20.11 07:33,
    prag 1d predjen 07:33; najstariji preziveli 21.11 11:50).
    Prag 1d drzi kes na ~110MB -> prune_to (800MB) se nikad ne aktivira.
    Odluka: bcm:3d (balans) ili bcm:7d (cap postaje primaran).

## odluka 22.11.2026: Data bcm:3d
    Data: bcm:1d -> bcm:3d (kes ~110MB je bio preagresivno; 3d ~300-400MB).
    Dry-run potvrdio: nula kandidata u Data (najstariji 21.11 11:50,
    prag istice 24.11 11:50). Jedini kandidat: GPUPersistentCache/GPUCache.
    prune_to (800MB) ostaje rezerva - relevantan samo ako 3 dana >800MB.
