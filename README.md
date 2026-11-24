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

## 24.11.2026 - prune_to prvi put obrisao u produkciji
    04:20:45 (boot catch-up, Spotify nije radio):
      Data 1023MB > 800MB - brisem najstarije ~223MB
      Data 1023MB -> 799MB
    Najstariji preziveli 23.11 11:20 = prvi posle odsecenog repa; fajlovi
    21.11-23.11 nestali SU zbog prune_to, ne zbog Spotify evikcije.

## zasto 33MB vs 23MB u istom runu - RESENO
    Skript sam poziva `systemd-tmpfiles --user --clean` (linija 113)
    IZMEDJU prune_to poziva i sumarne linije (117).
    Redosled: prune_to Data -> prune_to Browser/Cache (33MB OK) ->
    tmpfiles (bcm:1d brise ~10MB iz Browser/Cache) -> summary (23MB).
    Obe linije su tacne, ali mere razlicite tacke u vremenu.
    Zato standalone tmpfiles servis u 04:27:28 nije nasao nista.
    Hipoteze --apparent-size i "prune meri roditelja" su POGRESNE:
    du_m() i prune_to koriste isti `du -sm` na istoj putanji.

## Spotify postuje storage.size
    Data 89 min (11:15-12:44) stajao na tacno 1042 MiB = 1.018 GiB uz
    storage.size=1024 -> klijent ima LRU plafon na storage.size.
    Odluka: storage.size=768, ISPOD nase granice -> Data ~780, churn 0.
    ZAMKA: klijent upisuje prefs pri izlasku. Menjati samo dok Spotify
    NE radi; posle prve sesije proveriti da li je 768 ostalo.

## cap Data: 800 -> 850 (24.11.2026)
    storage.size=768 ocekivano slece na ~780MB (+overhead blokova).
    Sa cap 800 rezerva ~20MB (tesno); 850 daje ~70MB i cap postaje mrtva
    litera ako 768 radi. Ako 768 ne radi, Data ~1024 -> odseca 174MB/dan
    (manje od 224 sa 800). 850 je ispod 1024, pa cap i dalje ima smisla.
    Promenjena OBA call site-a: 101 (dry-run) i 106 (pravi run).

## exit code nosi dva ishoda
    `exit "$rc"` (121) je rc od systemd-tmpfiles, ne od prune_to.
    Ako tmpfiles padne, servis je failed iako je brisanje uspelo.

## merne jedinice u logu
    du_m(), prune_to: du -sm (zauzeti blokovi, MiB) - uporedivo.
    total(): du -sb po 6 direktorijuma, apparent bajtovi -> "pre:"/"posle:"
    NIJE uporedivo sa per-dir MiB linijama.

## 24.11.2026 - INCIDENT: DRY=1 nije dry-run, obrisao 210MB
    `DRY=1 ~/.local/bin/cache-clean.sh` -> skript je BRISAO.
    Uzrok: `DRY=0` bezuslovno pregazi env; ulaz je bio ISKLJUCIVO argument
    --dry-run / -n. Posledica: Data 1042->849, Browser/Cache 36->18,
    5 ostalih kesa ~17MB (~210MiB). Samo kes, Spotify nije radio.
    POPRAVKA: `DRY=${DRY:-0}` (linija 34) + `log "rezim: ..."` (linija 46).

## 24.11.2026 - sed -i je razbio symlink
    `sed -i` na symlinku pravi temp fajl i rename-uje preko njega ->
    symlink postaje regularan fajl. Posledica: dve kopije sa po POLOVINOM
    popravke. Dijagnoza: `readlink -f` vratio sopstvenu putanju.
    PRAVILO: menjati samo ~/dotfiles/local/bin/cache-clean.sh (ili
    `sed -i --follow-symlinks`). Posle izmene: readlink -f.
    Napomena: `DRY=1 bash -c '...'` NE testira skript, samo snippet.

## dry-run dokazan na grani brisanja - 24.11 12:58
    Kopija skripta sa cap 800 nad Data 849:
      rezim: DRY-RUN - nista se ne brise
      prune: (dry-run) .../Data 849MB > 800MB - obrisao bih ~49MB
      849 -> 849   (nista obrisano), rc=0
    Ovo je prvi test koji razlikuje "dry-run radi" od "slucajno no-op jer
    je kes ispod praga". Prethodni dry-runovi bili su no-op (Data 110/41MB).

## dry-run verifikovan 24.11 12:57
    --dry-run: pre 1.2GiB = posle 1.2GiB, Data 849MB, rc=0.
    tmpfiles --dry-run: "Would remove .../mozilla/firefox" + "Would restore
    atime/mtime on .../mozilla" -> potvrdjuje futimens/restore ponasanje.
    mozilla/firefox je mrtva kes (firedragon se koristi), deo od 210MB.

## QUIT_SPOTIFY - cap aktivira tako sto ugasi klijent
    Linija 77: skript gasi Spotify pre prune_to (osim --keep-spotify).
    => cache-clean.timer u 00:12 moze da prekine reprodukciju ako Data
    pređe cap. Sa storage.size=768 i Data ~780 do toga ne dolazi.

## 24.11.2026 - odluka B: --keep-spotify u timer unit-u
    Razlog: linija 77 gasi Spotify da bi primenio cap; tajmer u 00:12 moze
    prekinuti reprodukciju. Data 849 vs cap 850 = rezerva 1MB.
    Sa --keep-spotify: prune_to se preskace dok Spotify radi ("Spotify radi
    - preskacem"), pa cap deluje samo kad je klijent zatvoren.
    CENA: ako Spotify nikad ne zatvorite, skript ne prune-uje Data.
    Zato je storage.size=768 primarni mehanizam, skript je rezerva.
    CHECKPOINT: 25.11 i 26.11 izmeriti Data. Ako ostaje >850 dve sesije ->
    vratiti A ili preci na C (tajmer u 05:00).

## 24.11.2026 - unit-i su sada SYMLINKOVI (ne kopije)
    ~/.config/systemd/user/cache-clean.service -> ~/dotfiles/config/systemd/user/cache-clean.service
    ~/.config/systemd/user/cache-clean.timer   -> ~/dotfiles/config/systemd/user/cache-clean.timer
    Zasto: instalirani unit je bio kopija od 21.11 i `daemon-reload` je
    ucitavao star ExecStart bez --keep-spotify. Isti obrazac kao razbijeni
    symlink skripta - dve kopije, izmena u jednoj, izvrsava se druga.
    PRAVILO: menjati SAMO ~/dotfiles/config/systemd/user/*; `sed -i` na
    symlinku bi ga razbio (pravi temp + rename).
    Posle svake izmene unit-a: systemctl --user daemon-reload, pa
      systemctl --user show -p ExecStart cache-clean.service | tr ';' '\n' | grep argv
    Backups: ~/cache-clean.service.bak-2026-11-24, ~/cache-clean.timer.bak-2026-11-24
    Verifikovano 13:05: argv[] sadrzi --keep-spotify; tmpfiles NE dira
    Spotify (nema te putanje u cache.conf) -> samo prune_to dira Data.

## 24.11.2026 - storage.size=768 DOKAZANO (13:07)
    Spotify pokrenut 13:00; u 13:07: du -sm Data = 768, prefs storage.size=768.
    Evikcija 849 -> 768 za ~7 min, tacno na cap (nije lenja kako se mislilo).
    => Spotify interni LRU drzi Data na 768; skript cap 850 se NIKAD ne
    dostize (rezerva 82MB), prune_to uvek loguje "OK".
    => churn eliminisan: skript ne brise, Spotify eviktira po LRU, nema
    re-download ciklusa. Cap 850 ostaje kao buffer, ne kao mehanizam.
    => --keep-spotify ostaje kao sigurnost (nula cene), ali u praksi
    nikad nece biti aktiviran jer prune_to nikad ne dodje do brisanja.
    NAPOMENA: Data na tacno 768 znaci da Spotify stalno eviktira dok pise
    nove fajlove - to je normalno LRU ponasanje, ne problem.
    CHECKPOINT: 25.11 i 26.11 proveriti da Data ostaje ~768 (ne raste ka
    850). Ako raste -> storage.size se ne postuje dosledno, javiti.
