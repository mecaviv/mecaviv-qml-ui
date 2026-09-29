#!/usr/bin/env bash
#
# pedalier-ctl — installation et mise à jour du pédalier Sirenium sur le Raspberry.
#
# Le même code sert au premier démarrage sur une Debian vierge et aux mises à
# jour : chaque phase vérifie ce qui est déjà en place et ne fait que ce qui
# manque. Rejouer la commande sur une machine à jour ne doit rien modifier.
#
# S'exécute SUR le Pi. Le wrapper Mac (pedalier-deploy.sh) l'appelle en SSH
# depuis une copie dans /tmp — le script ne doit donc jamais supposer qu'il se
# trouve dans le dépôt cloné (un `git merge` réécrirait le fichier en cours
# d'exécution).
#
#   pedalier-ctl bootstrap        installation complète
#   pedalier-ctl update           mise à jour (mêmes phases, chacune s'auto-saute)
#   pedalier-ctl doctor           diagnostic, lecture seule
#   pedalier-ctl --help

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MANIFEST_DIR="$SCRIPT_DIR/manifest"
DEVICE_DIR="$SCRIPT_DIR/device"

CONFIG_DIR="$HOME/.config/pedalier"
ENV_FILE="$CONFIG_DIR/env"
UNIT_DIR="$HOME/.config/systemd/user"
AUTOSTART_FILE="$HOME/.config/autostart/pedalier-kiosk.desktop"
EXTERNALS_DIR="$HOME/pd-externals"
PD_SRC="$HOME/dev/src/pure-data"
RTPMIDID_SRC="$HOME/dev/src/rtpmidid"
LEGACY_DIR="$HOME/dev/src/mecaviv/patko-scratchpad/qtQmlSockets/pedalierSirenium"

# Valeurs par défaut, écrasées par ~/.config/pedalier/env s'il existe.
PEDALIER_REPO="$HOME/dev/src/mecaviv-qml-ui"
PD_REPO="$HOME/dev/src/mecaviv/puredata-abstractions"
PD_PATCH="pedalier.pd"
PEDALIER_PD_BIN="/usr/local/bin/pd"
WEB_PORT=8010
WS_PORT=10000
KIOSK_URL="http://localhost:8010/qmlwebsocketserver.html"
PEDALIER_DATA="$HOME/pedalier-data"

# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

WEB_DIR="$PEDALIER_REPO/pedalierSirenium/webfiles"
SCRIPTS_DIR="$PEDALIER_REPO/pedalierSirenium/scripts"
# Tout ce qui est installé et activé…
UNITS=(pedalier-rtpmidid.service pedalier-pd.service pedalier-node.service
       pedalier-midi-connect.service pedalier-midi-connect.timer
       pedalier-audio-connect.service pedalier-audio-connect.timer)
# …et parmi ça, ce qui doit tourner en permanence. Le câblage MIDI est un
# oneshot rejoué par son timer : il est normalement inactif entre deux passages.
SERVICES=(pedalier-rtpmidid.service pedalier-pd.service pedalier-node.service)

SKIP_PHASES=""
ONLY_PHASE=""
NO_RESTART=false
FORCE_PD=false

# Fichiers de données runtime que Pd écrit dans l'arbre git de puredata-abstractions.
# sirenspec.txt n'en fait PAS partie : c'est de la configuration, éditée en amont
# et versionnée, elle doit descendre par git comme le reste du patch.
# Fichiers que le patch réécrit lui-même sur la machine : les morceaux, et la
# configuration que le pédalier enregistre depuis son interface (clic). Ils sont
# suivis par git, donc un pull les écraserait et un arbre sale bloquerait toute
# mise à jour du dépôt — d'où le skip-worktree posé par protect_runtime_files.
RUNTIME_PATHS=(
    examples/looper.scenes
    examples/looper.scenes.txt
    examples/pedal.presets
    examples/pedals.preset.name
    examples/config.json
)

usage() {
    cat <<'EOF'
pedalier-ctl — installation et mise à jour du pédalier (à exécuter sur le Pi)

  bootstrap            installation complète (from scratch ou machine déjà installée)
  update               idem bootstrap : chaque phase se saute si rien n'a bougé
  doctor               diagnostic complet, lecture seule
  preflight            vérifications préalables seules

  Phases individuelles :
  deps repos migrate pd-build externals web midi autostart

  Runtime :
  start | stop [--orphans] | restart | status | logs [unité]

  Morceaux :
  songs save | songs restore <archive> | songs list

Options :
  --dry-run        n'exécute rien, affiche ce qui serait fait
  --yes            ne pose aucune question
  --verbose        affiche les commandes
  --only <phase>   n'exécute que cette phase
  --skip <phase>   saute cette phase (répétable)
  --no-restart     ne relance pas les services à la fin
  --force-pd       recompile Pure Data même si la version attendue est en place
EOF
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

phase_preflight() {
    phase "Vérifications préalables"
    local blocking=0

    local arch; arch=$(uname -m)
    case "$arch" in
        aarch64|armv7l) ok "architecture $arch" ;;
        *) warn "architecture $arch inattendue (le Pi est en aarch64)" ;;
    esac

    if [ -r /etc/os-release ]; then
        local pretty; pretty=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
        ok "système : $pretty"
    fi

    local free_mb; free_mb=$(df -Pm "$HOME" | awk 'NR==2{print $4}')
    if [ "${free_mb:-0}" -lt 4096 ]; then
        err "espace disque insuffisant : ${free_mb} Mo libres, 4096 attendus"
        blocking=1
    else
        ok "espace disque : $(( free_mb / 1024 )) Go libres"
    fi

    # Une horloge fausse fait échouer git et TLS de façon très peu lisible.
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
            ok "horloge synchronisée ($(date '+%F %T'))"
        else
            warn "horloge NON synchronisée ($(date '+%F %T')) — git et TLS peuvent échouer"
            warn "  correctif : sudo systemctl restart systemd-timesyncd"
        fi
    fi

    if sudo -n true 2>/dev/null; then
        ok "sudo sans mot de passe"
    else
        err "sudo demande un mot de passe — le déploiement non interactif échouera"
        blocking=1
    fi

    if timeout 15 git ls-remote https://github.com/mecaviv/mecaviv-qml-ui.git HEAD >/dev/null 2>&1; then
        ok "accès à GitHub (https)"
    else
        err "GitHub injoignable en https"
        blocking=1
    fi

    # ssh -T git@github.com sort toujours en code 1 : c'est le message qui compte,
    # et avec pipefail un `| grep` masquerait le succès derrière ce code.
    local gh; gh=$(timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)
    if printf '%s' "$gh" | grep -q "successfully authenticated"; then
        ok "accès à GitHub (clé ssh)"
    else
        warn "pas d'accès ssh à GitHub — les dépôts privés (puredata-abstractions, critapec) échoueront"
        warn "  correctif : ssh-keygen -t ed25519 puis ajouter ~/.ssh/id_ed25519.pub aux clés du compte"
    fi

    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}/systemd" ]; then
        ok "systemd --user disponible"
    elif [ -d "/run/user/$(id -u)/systemd" ]; then
        ok "systemd --user disponible (/run/user/$(id -u))"
    else
        err "systemd --user indisponible — l'autostart ne fonctionnera pas"
        blocking=1
    fi

    return "$blocking"
}

# ---------------------------------------------------------------------------
# deps — paquets système
# ---------------------------------------------------------------------------

read_manifest() { grep -vE '^\s*(#|$)' "$1"; }

apt_missing() {
    local missing=''
    local p
    for p in $(read_manifest "$1"); do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || missing="$missing $p"
    done
    printf '%s' "${missing# }"
}

# Les mises à jour automatiques prennent le verrou dpkg au pire moment et
# peuvent remplacer un paquet en pleine performance.
disarm_auto_updates() {
    local u changed=0
    for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer packagekit.service; do
        if systemctl is-enabled "$u" >/dev/null 2>&1; then
            run sudo systemctl disable --now "$u" >/dev/null 2>&1
            changed=1
        fi
    done
    [ "$changed" = 1 ] && ok "mises à jour automatiques désarmées" || skip "mises à jour automatiques"
}

apt_install() {
    local missing="$1"
    [ -z "$missing" ] && return 0
    info "installation : $missing"
    run sudo apt-get update -qq || return 1
    # shellcheck disable=SC2086
    run sudo apt-get install -y $missing || return 1
}

phase_deps() {
    phase "Paquets système"
    local missing; missing=$(apt_missing "$MANIFEST_DIR/apt-packages.txt")

    ensure_bluetooth_battery

    if [ -z "$missing" ] && [ "$(stamp_age_days apt.stamp)" -lt 7 ]; then
        skip "paquets système"
        return 0
    fi

    disarm_auto_updates
    apt_install "$missing" || die "échec de l'installation des paquets"

    # puredata reste installé (pd-lua en dépend) mais ne doit plus bouger : le
    # runtime tourne sur le Pd compilé dans /usr/local.
    if ! apt-mark showhold 2>/dev/null | grep -qx puredata; then
        run sudo apt-mark hold puredata >/dev/null
        ok "puredata figé (apt-mark hold)"
    fi

    stamp_write apt.stamp "$(date -Iseconds)"
    ok "paquets système à jour"
}

# BlueZ n'expose le niveau de batterie d'un peripherique (org.bluez.Battery1)
# qu'en mode experimental. Sans ca, `bluetoothctl info` ne dit rien de la charge
# du casque -- et le reglage vit dans /etc, donc hors du depot : il se perdrait
# a la reinstallation de la machine si le deploiement ne le reposait pas.
ensure_bluetooth_battery() {
    local f=/etc/bluetooth/main.conf
    [ -f "$f" ] || { skip "bluez absent"; return 0; }
    if grep -qE '^Experimental = true' "$f"; then
        skip "bluez: batterie des peripheriques (deja active)"
        return 0
    fi
    run sudo cp "$f" "$f.bak-$(date +%Y%m%d)"
    if grep -qE '^#Experimental' "$f"; then
        run sudo sed -i 's|^#Experimental = false|Experimental = true|' "$f"
    else
        run sudo sed -i '/^\[General\]/a Experimental = true' "$f"
    fi
    run sudo systemctl restart bluetooth \
        && ok "bluez: batterie des peripheriques activee (Experimental)"
}

# npm est absent de l'image et son paquet Debian peut vouloir aligner nodejs sur
# la version de la distribution — ce qui casserait le node 18 en place.
ensure_npm() {
    command -v npm >/dev/null 2>&1 && return 0
    info "npm absent — simulation de l'installation avant de décider"
    local sim; sim=$(sudo apt-get install -s npm 2>&1)
    # Toute ligne Inst/Remv portant sur nodejs lui-même : le paquet npm de Debian
    # peut vouloir réaligner le runtime, et c'est justement ce qu'on refuse.
    if printf '%s' "$sim" | grep -qE '^(Inst|Remv) nodejs '; then
        err "apt veut modifier nodejs pour installer npm :"
        printf '%s\n' "$sim" | grep -E '^(Inst|Remv) nodejs ' >&2
        err "installation refusée — utiliser 'pedalier-deploy.sh node-modules' depuis le Mac"
        return 1
    fi
    run sudo apt-get install -y npm || return 1
    ok "npm installé"
}

# ---------------------------------------------------------------------------
# repos — dépôts git
# ---------------------------------------------------------------------------

git_update_repo() {
    local url="$1" dir="$2" branch="$3"
    local name; name=$(basename "$dir")

    if [ ! -d "$dir/.git" ]; then
        if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
            # Le dossier existe déjà sans être un dépôt : typiquement des
            # artefacts de build poussés avant le premier bootstrap. On y greffe
            # le dépôt au lieu de refuser, et checkout -f remet les fichiers
            # suivis dans leur état attendu sans toucher au reste.
            info "adoption du dossier existant $name ($branch)"
            run git -C "$dir" init --quiet || return 1
            git -C "$dir" remote get-url origin >/dev/null 2>&1 \
                || run git -C "$dir" remote add origin "$url"
            run git -C "$dir" fetch --quiet origin "$branch" || return 1
            run git -C "$dir" checkout -f -B "$branch" "origin/$branch" || return 1
            ok "$name adopté ($(git -C "$dir" rev-parse --short HEAD 2>/dev/null))"
            return 0
        fi
        info "clonage de $name ($branch)"
        run mkdir -p "$(dirname "$dir")" || return 1
        run git clone --branch "$branch" "$url" "$dir" || return 1
        ok "$name cloné"
        return 0
    fi

    # Un arbre sale signifie du travail local non commité : on ne le touche pas.
    if [ -n "$(git -C "$dir" status --porcelain -uno)" ]; then
        warn "$name : modifications locales non commitées — mise à jour ignorée"
        git -C "$dir" status --short -uno | head -5 >&2
        return 0
    fi

    run git -C "$dir" fetch --quiet origin || { warn "$name : fetch impossible"; return 0; }

    local current; current=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
    if [ "$current" != "$branch" ]; then
        warn "$name est sur '$current', le manifeste demande '$branch' — laissé en l'état"
        return 0
    fi

    local local_sha upstream_sha
    local_sha=$(git -C "$dir" rev-parse HEAD)
    upstream_sha=$(git -C "$dir" rev-parse "origin/$branch" 2>/dev/null || echo "$local_sha")
    if [ "$local_sha" = "$upstream_sha" ]; then
        skip "$name"
        return 0
    fi

    # --ff-only : en cas de divergence on veut un échec explicite, pas un merge
    # automatique qui laisserait un conflit sur la machine.
    if run git -C "$dir" merge --ff-only "origin/$branch"; then
        ok "$name mis à jour ($(git -C "$dir" rev-parse --short HEAD))"
    else
        warn "$name : avance impossible (branches divergentes) — à régler à la main"
    fi
}

# Les clips, scènes et presets sont écrits par Pd DANS l'arbre git. Sans ça,
# chaque mise à jour entre en conflit avec ce qui a été joué sur le pédalier.
protect_runtime_files() {
    [ -d "$PD_REPO/.git" ] || return 0
    local tracked; tracked=$(git -C "$PD_REPO" ls-files -- "${RUNTIME_PATHS[@]}" 2>/dev/null)
    [ -z "$tracked" ] && return 0

    local already; already=$(git -C "$PD_REPO" ls-files -v -- "${RUNTIME_PATHS[@]}" 2>/dev/null | grep -c '^S' || true)
    local total; total=$(printf '%s\n' "$tracked" | wc -l | tr -d ' ')
    if [ "$already" = "$total" ]; then
        skip "protection des fichiers écrits par le patch ($total fichiers)"
        return 0
    fi
    # shellcheck disable=SC2086
    run_sh "git -C '$PD_REPO' update-index --skip-worktree $(printf '%s\n' "$tracked" | sed "s|^|'|;s|$|'|" | tr '\n' ' ')" \
        && ok "fichiers écrits par le patch protégés de git ($total en skip-worktree)"
}

# Un fichier retiré de RUNTIME_PATHS doit repasser sous git, sinon il reste figé sur
# la machine et plus aucune mise à jour ne l'atteint — sans le moindre message.
release_unprotected_files() {
    [ -d "$PD_REPO/.git" ] || return 0
    local skipped; skipped=$(git -C "$PD_REPO" ls-files -v -- examples 2>/dev/null | sed -n 's/^S //p')
    [ -z "$skipped" ] && return 0

    local path keep stale=''
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        keep=false
        local p
        for p in "${RUNTIME_PATHS[@]}"; do
            case "$path" in "$p"|"$p"/*) keep=true; break ;; esac
        done
        [ "$keep" = false ] && stale="$stale '$path'"
    done <<< "$skipped"

    [ -z "$stale" ] && return 0
    # shellcheck disable=SC2086
    run_sh "git -C '$PD_REPO' update-index --no-skip-worktree$stale" \
        && ok "rendus à git :$stale"
    # Le fichier local peut avoir divergé pendant sa protection : on le remet
    # dans l'état du dépôt, c'est lui qui fait foi pour de la configuration.
    # shellcheck disable=SC2086
    run_sh "git -C '$PD_REPO' checkout --$stale"
}

# Les artefacts du build Qt sont versionnés, mais sur la machine c'est le rsync
# depuis le Mac qui fait foi. Sans skip-worktree, l'arbre serait vu comme sale en
# permanence et plus aucune mise à jour ne passerait.
protect_build_artifacts() {
    local repo="$PEDALIER_REPO"
    [ -d "$repo/.git" ] || return 0
    local paths=(
        pedalierSirenium/webfiles/qmlwebsocketserver.js
        pedalierSirenium/webfiles/qmlwebsocketserver.html
        pedalierSirenium/webfiles/qtloader.js
        pedalierSirenium/webfiles/qtlogo.svg
        pedalierSirenium/webfiles/config.js
        pedalierSirenium/webfiles/qmlwebsocketserver
    )
    local tracked; tracked=$(git -C "$repo" ls-files -- "${paths[@]}" 2>/dev/null)
    [ -z "$tracked" ] && return 0
    local already total
    already=$(git -C "$repo" ls-files -v -- "${paths[@]}" 2>/dev/null | grep -c '^S')
    total=$(printf '%s\n' "$tracked" | wc -l | tr -d ' ')
    if [ "${already:-0}" = "$total" ]; then
        skip "artefacts de build hors de git ($total fichiers)"
        return 0
    fi
    # shellcheck disable=SC2086
    run_sh "git -C '$repo' update-index --skip-worktree $(printf '%s\n' "$tracked" | sed "s|^|'|;s|$|'|" | tr '\n' ' ')" \
        && ok "artefacts de build hors de git ($total fichiers en skip-worktree)"
}

# Les artefacts de build sont versionnes ET reecrits par le rsync depuis le Mac.
# Le skip-worktree les cache a `git status`, mais pas a `git merge` : des qu'un
# commit les touche -- c'est-a-dire a chaque build -- la mise a jour echoue avec
# « local changes would be overwritten ». On les rend a git et on les remet dans
# l'etat du depot avant de tirer ; le rsync qui suit reposera la bonne version.
release_build_artifacts_for_pull() {
    local repo="$PEDALIER_REPO"
    [ -d "$repo/.git" ] || return 0
    local skipped; skipped=$(git -C "$repo" ls-files -v | awk '/^S/ {print $2}')
    [ -z "$skipped" ] && return 0
    # shellcheck disable=SC2086
    git -C "$repo" update-index --no-skip-worktree $skipped 2>/dev/null || true
    # shellcheck disable=SC2086
    git -C "$repo" checkout -- $skipped 2>/dev/null || true
}

phase_repos() {
    phase "Dépôts git"
    release_build_artifacts_for_pull
    local url dir branch
    while read -r url dir branch; do
        [ -z "$url" ] && continue
        git_update_repo "$url" "$HOME/$dir" "$branch"
    done < <(read_manifest "$MANIFEST_DIR/repos.txt")
    protect_runtime_files
    release_unprotected_files
    protect_build_artifacts
}

# ---------------------------------------------------------------------------
# migrate — reprise de l'installation historique
# ---------------------------------------------------------------------------

phase_migrate() {
    phase "Reprise de l'ancienne installation"

    if [ ! -d "$LEGACY_DIR" ]; then
        skip "ancienne installation (absente)"
        return 0
    fi

    # Le wasm fait 40 Mo et n'est pas dans git : le copier localement évite de le
    # retransférer depuis le Mac au premier déploiement.
    local legacy_wasm="$LEGACY_DIR/webfiles/qmlwebsocketserver.wasm"
    if [ -f "$legacy_wasm" ] && [ ! -f "$WEB_DIR/qmlwebsocketserver.wasm" ] && [ -d "$WEB_DIR" ]; then
        run cp "$legacy_wasm" "$WEB_DIR/qmlwebsocketserver.wasm" \
            && ok "wasm repris de l'ancienne installation ($(du -h "$legacy_wasm" | cut -f1))"
    fi

    # L'ancien server.js est la seule source des endpoints /api/* : on l'archive
    # avant tout, il n'a jamais existé dans git.
    local legacy_server="$LEGACY_DIR/webfiles/server.js"
    if [ -f "$legacy_server" ] && [ ! -f "$PEDALIER_DATA/legacy/server.js" ]; then
        run mkdir -p "$PEDALIER_DATA/legacy"
        run cp "$legacy_server" "$PEDALIER_DATA/legacy/server.js" \
            && ok "ancien server.js archivé dans $PEDALIER_DATA/legacy/"
    fi

    ok "ancienne installation conservée en place ($LEGACY_DIR)"
    log "  ${C_DIM}suppression manuelle une fois tout validé : pedalier-ctl migrate --finalize${C_RESET}"
}

migrate_finalize() {
    [ -d "$LEGACY_DIR" ] || { ok "rien à archiver"; return 0; }
    confirm "Archiver l'ancienne installation $LEGACY_DIR ?" || return 0
    local dest="$LEGACY_DIR.deprecated-$(date +%Y%m%d)"
    run mv "$LEGACY_DIR" "$dest" && ok "déplacé vers $dest"
}

# ---------------------------------------------------------------------------
# pd-build — Pure Data 0.55 depuis les sources
# ---------------------------------------------------------------------------

phase_pd_build() {
    phase "Pure Data"
    local target; target=$(read_manifest "$MANIFEST_DIR/pd-version.txt" | head -1)
    # L'estampille porte aussi le backend : passer de --disable-jack a
    # --enable-jack ne change pas la version, et sans ca la phase se sauterait.
    local stamp="$target+jack"

    if [ "$FORCE_PD" != true ] && stamp_matches pd.version "$stamp" && [ -x "$PEDALIER_PD_BIN" ]; then
        skip "Pure Data $target ($($PEDALIER_PD_BIN -version 2>&1 | head -1))"
        return 0
    fi

    info "compilation de Pure Data $target (~5 min sur un Pi 5)"
    local missing; missing=$(apt_missing "$MANIFEST_DIR/apt-build-packages.txt")
    apt_install "$missing" || die "dépendances de compilation manquantes"

    if [ ! -d "$PD_SRC/.git" ]; then
        run mkdir -p "$(dirname "$PD_SRC")"
        run git clone --depth 1 --branch "$target" https://github.com/pure-data/pure-data.git "$PD_SRC" \
            || die "clonage de pure-data impossible"
    else
        run git -C "$PD_SRC" fetch --depth 1 origin "refs/tags/$target:refs/tags/$target" || true
        run git -C "$PD_SRC" checkout --quiet "$target" || die "tag $target introuvable"
    fi

    run_sh "cd '$PD_SRC' && ./autogen.sh" || die "autogen.sh a échoué"
    run_sh "cd '$PD_SRC' && ./configure --prefix=/usr/local --enable-alsa --enable-jack --disable-portaudio" \
        || die "configure a échoué"
    run_sh "cd '$PD_SRC' && make -j$(nproc)" || die "compilation de Pd échouée"

    # On valide le binaire fraîchement compilé AVANT de l'installer : une
    # installation ratée remplacerait un pd qui marche.
    if [ "$DRY_RUN" != true ]; then
        "$PD_SRC/src/pd" -version >/dev/null 2>&1 || die "le pd compilé ne démarre pas — rien n'est installé"
    fi
    run_sh "cd '$PD_SRC' && sudo make install" || die "make install a échoué"

    hash -r
    stamp_write pd.version "$stamp"
    if [ -x "$PEDALIER_PD_BIN" ]; then
        ok "Pure Data installé : $("$PEDALIER_PD_BIN" -version 2>&1 | head -1)"
    else
        ok "Pure Data $target installé"
    fi
    log "  ${C_DIM}0.53 de Debian reste disponible en /usr/bin/pd (repli via PEDALIER_PD_BIN)${C_RESET}"
}

# ---------------------------------------------------------------------------
# externals — ~/pd-externals
# ---------------------------------------------------------------------------

# Le patch sonde fait lire à pdjson un fichier RELATIF au patch : que l'objet se
# crée ne suffit pas. Avec le pdlua 0.7.3 de Debian, pdjson se créait très bien
# puis échouait à chaque `read` (pas de `_canvaspath`). « JSON loaded from »
# n'est posté que si le fichier a été lu et décodé.
pdjson_loads() {
    local tmp; tmp=$(mktemp -d)
    printf '{"ok": 1}\n' > "$tmp/probe.json"
    printf '%s\n' '#N canvas 0 0 200 200;' '#X obj 20 20 loadbang;' \
        '#X msg 20 50 read probe.json;' '#X obj 20 80 pdjson;' \
        '#X connect 0 0 1 0;' '#X connect 1 0 2 0;' > "$tmp/probe.pd"
    local out; out=$(timeout 20 "$PEDALIER_PD_BIN" -nogui -stderr -noprefs -path "$EXTERNALS_DIR" \
        -lib pdlua "$tmp/probe.pd" 2>&1 </dev/null)
    rm -rf "$tmp"
    printf '%s' "$out" | grep -q "JSON loaded from"
}

# pdlua compilé depuis agraef/pd-lua contre les sources du Pd de /usr/local
# (il lui faut s_stuff.h, que le paquet dev n'installe pas). On recompile si la
# version demandée ou celle de Pd a changé.
build_pdlua() {
    local target; target=$(read_manifest "$MANIFEST_DIR/pdlua-version.txt" | head -1)
    local stamp; stamp="$target+pd$(stamp_read pd.version)"
    local src="$HOME/dev/src/pd-lua"
    local dest="$EXTERNALS_DIR/pdlua"

    if stamp_matches pdlua.version "$stamp" && [ -f "$dest/pdlua.pd_linux" ]; then
        skip "pdlua $target"
        return 0
    fi
    [ -f "$PD_SRC/src/s_stuff.h" ] || { warn "sources de Pd absentes ($PD_SRC) — phase pd-build d'abord"; return 0; }

    info "compilation de pdlua $target"
    if [ ! -d "$src/.git" ]; then
        run git clone --branch "$target" https://github.com/agraef/pd-lua.git "$src" \
            || { warn "clonage de pd-lua impossible"; return 0; }
    else
        run git -C "$src" fetch --tags origin || true
        run git -C "$src" checkout --quiet "$target" || { warn "tag pdlua $target introuvable"; return 0; }
    fi
    run git -C "$src" submodule update --init --recursive || { warn "sous-module lua de pd-lua absent"; return 0; }
    run_sh "cd '$src' && make clean >/dev/null 2>&1; make -j$(nproc) PDDIR='$PD_SRC'" \
        || { warn "compilation de pdlua échouée — l'ancien reste en place"; return 0; }

    # L'ancien n'est écarté qu'une fois le nouveau compilé, et hors du chemin
    # de recherche de Pd.
    if [ -d "$dest" ]; then
        run rm -rf "$src.prev" && run mv "$dest" "$src.prev"
    fi
    run_sh "cd '$src' && make install PDDIR='$PD_SRC' objectsdir='$EXTERNALS_DIR' >/dev/null" \
        || { warn "installation de pdlua échouée — l'ancien est dans $src.prev"; return 0; }
    stamp_write pdlua.version "$stamp"
    ok "pdlua $target installé"
}

# lunajson est du Lua pur, installé à la main dans /usr/local/share/lua/5.2/
# quand pdlua venait de Debian (Lua 5.2). Le pdlua compilé embarque Lua 5.4 :
# on rend la même copie visible en 5.4 par des liens.
ensure_lunajson() {
    local lua54=/usr/local/share/lua/5.4 lua52=/usr/local/share/lua/5.2
    if [ -f "$lua54/lunajson.lua" ]; then
        skip "lunajson (Lua 5.4)"
    elif [ -f "$lua52/lunajson.lua" ]; then
        run sudo mkdir -p "$lua54" \
            && run sudo ln -sfn "$lua52/lunajson.lua" "$lua54/lunajson.lua" \
            && run sudo ln -sfn "$lua52/lunajson" "$lua54/lunajson" \
            && ok "lunajson rendu visible en Lua 5.4"
    else
        warn "lunajson absent de $lua54/ — pdjson ne pourra pas lire de JSON"
        warn "  correctif : git clone https://github.com/grafi-tt/lunajson && sudo cp -r lunajson/src/lunajson.lua lunajson/src/lunajson $lua54/"
    fi
}

# Compile un external de critapec. Meme logique pour tous : on recompile si le
# binaire manque, si Pd a change de version, ou si une source est plus recente
# que lui. Les sources sont a la racine (midifile) ou sous src/ (c-siren~).
build_critapec_external() {
    local name="$1"
    local dir="$EXTERNALS_DIR/critapec/$name"
    local binary="$dir/$name.pd_linux"
    local pd_version; pd_version=$(stamp_read pd.version)

    [ -d "$dir" ] || { warn "$name absent de critapec — dépôt à jour ?"; return 0; }

    local need_build=false
    if [ ! -f "$binary" ]; then
        need_build=true
    elif [ -n "$pd_version" ] && ! stamp_matches externals.builtfor "$pd_version"; then
        need_build=true
        info "version de Pd changée — recompilation de $name"
    elif [ -n "$(find "$dir" \( -name '*.c' -o -name '*.cpp' -o -name '*.h' \) -newer "$binary" 2>/dev/null | head -1)" ]; then
        need_build=true
    fi

    if [ "$need_build" != true ]; then
        skip "$name"
        return 0
    fi

    local missing; missing=$(apt_missing "$MANIFEST_DIR/apt-build-packages.txt")
    apt_install "$missing" || warn "dépendances de compilation incomplètes"
    # PDINCLUDEDIR : compiler contre les en-têtes du Pd réellement utilisé.
    run_sh "cd '$dir' && make clean >/dev/null 2>&1; make PDINCLUDEDIR=/usr/local/include/pd" \
        && ok "$name compilé" || warn "compilation de $name échouée"
}

# Les données de c-siren~ — courbes d'amplitude et de fréquence relevées sur les
# vraies sirènes, 575 Mo — vivent dans le dépôt ComposeSiren. Clone superficiel
# et partiel : seul le dossier Resources est matérialisé.
#
# Le chemin d'installation n'est pas négociable : c-siren~ porte
# /usr/share/ComposeSiren/Resources/ en dur comme défaut Linux, et rien dans le
# patch ne lui envoie de message `resources`. Un lien depuis ce chemin système
# vers le clone évite d'écrire un chemin de machine dans pedalier.pd.
install_siren_resources() {
    local dir="$HOME/dev/src/ComposeSiren"
    local link=/usr/share/ComposeSiren
    local url=git@github.com:patricecolet/ComposeSiren.git
    # La branche compte : les données corrigées de juin 2026 — réindexation des
    # partiels qui supprime l'artefact de crossfade — n'existent que sur
    # feat/siren-udp-bridge. La branche par défaut porte encore les données
    # d'origine, qui se chargent sans erreur et cliquent à chaque transition.
    local branch=feat/siren-udp-bridge

    if [ ! -d "$dir/.git" ]; then
        info "clonage des données de sirène (ComposeSiren, ~600 Mo)"
        run mkdir -p "$(dirname "$dir")" || return 0
        if ! run git clone --depth 1 --filter=blob:none --sparse \
                 --branch "$branch" "$url" "$dir"; then
            warn "clonage de ComposeSiren échoué — pas de son de sirène en mode DSP"
            return 0
        fi
        run git -C "$dir" sparse-checkout set Resources || return 0
        ok "données de sirène clonées ($branch)"
    else
        local current; current=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ "$current" != "$branch" ]; then
            warn "données de sirène sur '$current', attendu '$branch'"
            warn "  correctif : rm -rf '$dir' puis rejouer la phase externals"
        else
            git_update_repo "$url" "$dir" "$branch"
        fi
    fi

    if [ ! -e "$link" ]; then
        run sudo ln -s "$dir" "$link" && ok "$link → $dir"
    else
        skip "lien $link"
    fi
}

phase_externals() {
    phase "Externals Pure Data"
    local pd_version; pd_version=$(stamp_read pd.version)
    local critapec="$EXTERNALS_DIR/critapec"

    [ -d "$critapec/.git" ] || { warn "$critapec absent — phase repos d'abord"; return 0; }

    # pd-lib-builder est un sous-module : sans lui, `make` répond « No targets ».
    if [ ! -f "$critapec/pd-lib-builder/Makefile.pdlibbuilder" ]; then
        run git -C "$critapec" submodule update --init --recursive || warn "sous-modules critapec non initialisés"
    fi

    build_critapec_external midifile
    build_critapec_external "c-siren~"
    install_siren_resources

    build_pdlua

    # Pd < 0.55 ne cherche pas <nom>/<nom>.pd_lua : un lien à plat le rend
    # trouvable quelle que soit la version, pour un coût nul.
    if [ -f "$critapec/pdjson/pdjson.pd_lua" ] && [ ! -e "$EXTERNALS_DIR/pdjson.pd_lua" ]; then
        run ln -s critapec/pdjson/pdjson.pd_lua "$EXTERNALS_DIR/pdjson.pd_lua" \
            && ok "pdjson.pd_lua lié à plat dans $EXTERNALS_DIR"
    fi

    # lunajson doit rester hors du dossier de pdjson : le chemin de recherche de
    # pdlua essaie le répertoire `lunajson/` avant `lunajson.lua`.
    ensure_lunajson

    if [ "$DRY_RUN" != true ] && [ -x "$PEDALIER_PD_BIN" ]; then
        if pdjson_loads; then
            ok "pdjson lit un JSON"
            stamp_write externals.builtfor "$pd_version"
        else
            err "pdjson ne lit PAS de JSON — pedalier.pd démarrera sans ses compositions"
            err "  vérifier : $EXTERNALS_DIR/pdjson.pd_lua, la version de $EXTERNALS_DIR/pdlua et lunajson en Lua 5.4"
        fi
    fi
}

# ---------------------------------------------------------------------------
# web — serveur node
# ---------------------------------------------------------------------------

phase_web() {
    phase "Serveur web"
    [ -d "$WEB_DIR" ] || { warn "$WEB_DIR absent — phase repos d'abord"; return 0; }

    local lock="$WEB_DIR/package-lock.json"
    local lock_sha; lock_sha=$(sha_of "$lock")

    if [ -d "$WEB_DIR/node_modules" ] && stamp_matches npm.lock.sha256 "$lock_sha"; then
        skip "dépendances node"
    else
        ensure_npm || return 1
        if [ -f "$lock" ]; then
            run_sh "cd '$WEB_DIR' && npm ci --omit=dev" || run_sh "cd '$WEB_DIR' && npm install --omit=dev" \
                || { warn "npm a échoué"; return 1; }
        else
            run_sh "cd '$WEB_DIR' && npm install --omit=dev" || { warn "npm a échoué"; return 1; }
        fi
        stamp_write npm.lock.sha256 "$lock_sha"
        ok "dépendances node installées"
    fi

    if [ -f "$WEB_DIR/qmlwebsocketserver.wasm" ]; then
        ok "wasm présent ($(du -h "$WEB_DIR/qmlwebsocketserver.wasm" | cut -f1))"
    else
        warn "qmlwebsocketserver.wasm absent — le déployer depuis le Mac :"
        warn "  ./deploy/pedalier-deploy.sh wasm"
    fi
}

# ---------------------------------------------------------------------------
# midi
# ---------------------------------------------------------------------------

phase_midi() {
    phase "MIDI"

    # Ports MIDI virtuels utilisés pour le câblage interne côté Pd.
    if lsmod 2>/dev/null | grep -q '^snd_virmidi'; then
        skip "module snd-virmidi"
    else
        run sudo modprobe snd-virmidi && ok "snd-virmidi chargé"
    fi
    if grep -qx 'snd-virmidi' /etc/modules-load.d/pedalier.conf 2>/dev/null; then
        skip "chargement de snd-virmidi au démarrage"
    else
        run_sh "echo snd-virmidi | sudo tee /etc/modules-load.d/pedalier.conf >/dev/null" \
            && ok "snd-virmidi chargé au démarrage"
    fi

    if id -nG "$USER" | tr ' ' '\n' | grep -qx audio; then
        skip "groupe audio"
    else
        run sudo usermod -aG audio "$USER" && warn "ajouté au groupe audio — effectif après reconnexion"
    fi

    if [ -x /usr/local/bin/rtpmidid ]; then
        skip "rtpmidid"
        return 0
    fi

    info "compilation de rtpmidid"
    local missing; missing=$(apt_missing "$MANIFEST_DIR/apt-build-packages.txt")
    apt_install "$missing" || warn "dépendances de compilation incomplètes"
    if [ ! -d "$RTPMIDID_SRC/.git" ]; then
        run git clone --recursive https://github.com/davidmoreno/rtpmidid.git "$RTPMIDID_SRC" \
            || { warn "clonage de rtpmidid impossible"; return 1; }
    fi
    run_sh "cd '$RTPMIDID_SRC' && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc)" \
        || { warn "compilation de rtpmidid échouée"; return 1; }
    run_sh "sudo install -m755 '$RTPMIDID_SRC/build/src/rtpmidid' /usr/local/bin/rtpmidid" \
        && ok "rtpmidid installé"
}

# ---------------------------------------------------------------------------
# autostart
# ---------------------------------------------------------------------------

render_unit() {
    sed -e "s|@PEDALIER_REPO@|$PEDALIER_REPO|g" \
        -e "s|@PD_REPO@|$PD_REPO|g" \
        -e "s|@PD_BIN@|$PEDALIER_PD_BIN|g" \
        -e "s|@PD_PATCH@|$PD_PATCH|g" \
        -e "s|@WEB_PORT@|$WEB_PORT|g" \
        -e "s|@KIOSK_URL@|$KIOSK_URL|g" \
        "$1"
}

# L'ancien démarrage (crontab @reboot + cron de recâblage toutes les 5 s) doit
# partir en même temps que le nouveau arrive : les deux en parallèle, ce sont
# deux Pure Data et deux rtpmidid qui pilotent les mêmes sirènes.
retire_legacy_cron() {
    local current; current=$(crontab -l 2>/dev/null)
    [ -z "$current" ] && return 0
    local cleaned; cleaned=$(printf '%s\n' "$current" | grep -v -e 'start\.pedalier\.sh' -e 'rtpmidi_connect')
    if [ "$cleaned" = "$current" ]; then
        skip "ancien démarrage par cron (déjà retiré)"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        printf '%s  [simulation] retrait des lignes crontab de l'\''ancien démarrage :%s\n' "$C_DIM" "$C_RESET"
        printf '%s\n' "$current" | grep -e 'start\.pedalier\.sh' -e 'rtpmidi_connect' | sed 's/^/    /'
        return 0
    fi
    mkdir -p "$PEDALIER_DATA/legacy"
    printf '%s\n' "$current" > "$PEDALIER_DATA/legacy/crontab.$(date +%Y%m%d-%H%M%S)"
    printf '%s\n' "$cleaned" | crontab -
    ok "ancien démarrage par cron retiré (sauvegarde dans $PEDALIER_DATA/legacy/)"
}

phase_autostart() {
    phase "Démarrage automatique"
    retire_legacy_cron

    # La configuration est écrite une fois puis respectée : une valeur modifiée à
    # la main sur la machine ne doit pas disparaître à la mise à jour suivante.
    if [ ! -f "$ENV_FILE" ]; then
        install_file "$ENV_FILE" "$(sed "s|@HOME@|$HOME|g" "$DEVICE_DIR/env.example")" \
            && ok "configuration créée : $ENV_FILE"
    else
        # Exception à la règle du « jamais écrasé », et une seule fois : piloter un
        # PCM ALSA sur du Bluetooth expose Pd à une boucle de xrun dont il ne
        # revient jamais, qui le coupe du WebSocket. En JACK c'est PipeWire qui
        # tient le lien. L'estampille garantit qu'un choix manuel ultérieur
        # (repli ALSA) ne sera pas réécrit au déploiement suivant.
        if ! stamp_matches audio.backend jack \
           && grep -q '^PD_AUDIO_OPTS=.*-alsa' "$ENV_FILE"; then
            run sed -i 's|^PD_AUDIO_OPTS=.*|PD_AUDIO_OPTS="-jack -noadc"|' "$ENV_FILE"
            ok "sortie audio confiée à JACK/PipeWire"
        fi
        stamp_write audio.backend jack
        local candidate; candidate=$(sed "s|@HOME@|$HOME|g" "$DEVICE_DIR/env.example")
        if [ "$candidate" != "$(cat "$ENV_FILE")" ]; then
            install_file "$ENV_FILE.new" "$candidate" >/dev/null
            warn "le modèle de configuration a changé : comparer $ENV_FILE et $ENV_FILE.new"
        else
            skip "configuration"
        fi
    fi

    local changed=0 unit
    for unit in "${UNITS[@]}" pedalier.target; do
        install_file "$UNIT_DIR/$unit" "$(render_unit "$DEVICE_DIR/units/$unit")" && changed=1
    done
    if [ "$changed" = 1 ]; then
        run systemctl --user daemon-reload
        ok "units systemd installées dans $UNIT_DIR"
    else
        skip "units systemd"
    fi

    # Sans linger, les services s'arrêtent à la déconnexion et ne démarrent pas
    # au boot tant que personne n'a ouvert de session.
    if loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -q yes; then
        skip "linger"
    else
        run sudo loginctl enable-linger "$USER" && ok "linger activé (services au démarrage, sans session)"
    fi

    local u
    for u in "${UNITS[@]}" pedalier.target; do
        systemctl --user is-enabled "$u" >/dev/null 2>&1 || run systemctl --user enable "$u" >/dev/null 2>&1
    done

    # Kiosque : autostart XDG, PAS ~/.config/labwc/autostart — un fichier
    # utilisateur y remplacerait l'autostart système (bureau, panneau, et le
    # lancement des .desktop justement).
    local desktop; desktop="[Desktop Entry]
Type=Application
Name=Pédalier Sirenium (kiosque)
Comment=Chromium plein écran sur l'interface du pédalier
Exec=$PEDALIER_REPO/pedalierSirenium/deploy/device/pedalier-kiosk.sh
X-GNOME-Autostart-enabled=true"
    if install_file "$AUTOSTART_FILE" "$desktop"; then
        ok "kiosque au démarrage de la session ($AUTOSTART_FILE)"
    else
        skip "kiosque"
    fi
}

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------

uctl() { systemctl --user "$@"; }

cmd_start() {
    phase "Démarrage"
    run uctl start pedalier.target
    if wait_tcp "$WS_PORT" 20; then ok "Pure Data écoute sur $WS_PORT"; else warn "rien sur le port $WS_PORT"; fi
    if wait_tcp "$WEB_PORT" 20; then ok "serveur web sur $WEB_PORT"; else warn "rien sur le port $WEB_PORT"; fi
}

cmd_stop() {
    phase "Arrêt"
    run uctl stop pedalier.target
    if [ "${1:-}" = "--orphans" ]; then
        # Les processus lancés à la main avant la migration ne sont pas connus de
        # systemd : ils tiendraient les ports et empêcheraient le démarrage.
        local killed=0
        pgrep -f "pd -nogui.*$PD_PATCH" >/dev/null && { run pkill -f "pd -nogui.*$PD_PATCH"; killed=1; }
        # Le motif doit attraper aussi bien `node /chemin/webfiles/server.js` que
        # le `node server.js` lancé à la main depuis webfiles/.
        pgrep -f "node .*server\.js" >/dev/null && { run pkill -f "node .*server\.js"; killed=1; }
        pgrep -x rtpmidid >/dev/null && { run pkill -x rtpmidid; killed=1; }
        [ "$killed" = 1 ] && ok "processus orphelins arrêtés" || skip "processus orphelins"
        sleep 1
        local busy; busy=$(ss -ltnp 2>/dev/null | grep -E ":($WEB_PORT|$WS_PORT) " || true)
        [ -n "$busy" ] && { warn "ports encore occupés :"; printf '%s\n' "$busy" >&2; }
    fi
}

cmd_status() {
    phase "État"
    uctl --no-pager --plain list-units 'pedalier*' 2>/dev/null | head -12
    log ""
    ss -ltnp 2>/dev/null | grep -E ":($WEB_PORT|$WS_PORT) " || log "aucun port en écoute"
    pgrep -x chromium >/dev/null && ok "kiosque lancé" || warn "kiosque non lancé"
}

cmd_logs() {
    local unit="${1:-pedalier-pd}"
    exec journalctl --user -u "$unit" -n 100 -f
}

# ---------------------------------------------------------------------------
# songs — morceaux (clips, scènes, presets)
# ---------------------------------------------------------------------------

songs_dir() { printf '%s' "$PD_REPO/examples"; }

cmd_songs_save() {
    local dir; dir=$(songs_dir)
    [ -d "$dir" ] || { warn "$dir absent"; return 0; }
    local archive="$PEDALIER_DATA/backups/morceaux-$(date +%Y%m%d-%H%M%S).tar.gz"

    if [ "$DRY_RUN" = true ]; then
        printf '%s  [simulation] sauvegarde vers %s%s\n' "$C_DIM" "$archive" "$C_RESET"
        return 0
    fi
    mkdir -p "$PEDALIER_DATA/backups"
    local manifest="$dir/MANIFEST.txt"
    {
        printf 'date       %s\n' "$(date -Iseconds)"
        printf 'machine    %s\n' "$(hostname)"
        printf 'patch      %s\n' "$(git -C "$PD_REPO" describe --always --dirty 2>/dev/null || echo inconnu)"
        printf 'scènes     %s\n' "$(grep -c ';' "$dir/looper.scenes.txt" 2>/dev/null || echo 0)"
    } > "$manifest"

    local existing=()
    local p
    for p in "${RUNTIME_PATHS[@]}" ; do
        [ -e "$PD_REPO/$p" ] && existing+=("$p")
    done
    existing+=("examples/MANIFEST.txt")
    tar -czf "$archive" -C "$PD_REPO" "${existing[@]}" 2>/dev/null \
        && ok "morceaux sauvegardés : $archive ($(du -h "$archive" | cut -f1))" \
        || { err "sauvegarde échouée"; return 1; }
    rm -f "$manifest"

    # Rotation : on garde les 10 dernières.
    ls -1t "$PEDALIER_DATA/backups"/morceaux-*.tar.gz 2>/dev/null | tail -n +11 | while read -r old; do
        rm -f "$old"
    done
}

cmd_songs_restore() {
    local archive="${1:?usage: songs restore <archive>}"
    [ -f "$archive" ] || archive="$PEDALIER_DATA/backups/$archive"
    [ -f "$archive" ] || die "archive introuvable : $1"
    confirm "Restaurer $archive par-dessus les morceaux actuels ?" || return 0
    cmd_songs_save
    run tar -xzf "$archive" -C "$PD_REPO" && ok "morceaux restaurés depuis $(basename "$archive")"
    log "  ${C_DIM}relancer Pure Data pour les prendre en compte : pedalier-ctl restart${C_RESET}"
}

cmd_songs_list() {
    local index="$(songs_dir)/looper.scenes.txt"
    phase "Morceaux"
    if [ -f "$index" ]; then
        log "${C_BOLD}slot  nom          clip${C_RESET}"
        sed 's/;$//' "$index" | awk '{printf "%-5s %-12s %s\n", $1, $4, $5}'
    else
        warn "$index absent"
    fi
    log ""
    log "${C_BOLD}Sauvegardes${C_RESET}"
    ls -1t "$PEDALIER_DATA/backups"/morceaux-*.tar.gz 2>/dev/null | head -10 | while read -r a; do
        log "  $(basename "$a")  $(du -h "$a" | cut -f1)"
    done || log "  aucune"
}

# ---------------------------------------------------------------------------
# doctor — diagnostic, aucune écriture
# ---------------------------------------------------------------------------

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else err "$label"; fi
}

cmd_doctor() {
    # Rapport lu comme un tout : les alertes doivent apparaître à leur place dans
    # le fil, pas mélangées au hasard par la bufferisation de deux flux.
    exec 2>&1
    phase "Diagnostic du pédalier — $(hostname) $(date '+%F %T')"

    log "${C_BOLD}Système${C_RESET}"
    log "  $(. /etc/os-release && printf '%s' "$PRETTY_NAME") — $(uname -m)"
    log "  disque : $(df -Ph "$HOME" | awk 'NR==2{print $4" libres sur "$2}')"
    log "  charge : $(uptime | sed 's/.*load average/load/')"
    [ -r /sys/class/thermal/thermal_zone0/temp ] && \
        log "  température : $(awk '{printf "%.1f °C", $1/1000}' /sys/class/thermal/thermal_zone0/temp)"

    log ""
    log "${C_BOLD}Pure Data${C_RESET}"
    if [ -x "$PEDALIER_PD_BIN" ]; then
        log "  binaire : $PEDALIER_PD_BIN — $("$PEDALIER_PD_BIN" -version 2>&1 | head -1)"
        local want; want=$(read_manifest "$MANIFEST_DIR/pd-version.txt" | head -1)
        [ "$(stamp_read pd.version)" = "$want" ] && ok "version attendue ($want)" || warn "jalon de version : $(stamp_read pd.version) ≠ $want"
        if pdjson_loads; then ok "pdjson lit un JSON"; else err "pdjson ne lit pas de JSON"; fi
    else
        err "binaire Pd introuvable : $PEDALIER_PD_BIN"
    fi
    local ext
    for ext in critapec pdlua zexy iemnet list-abs; do
        [ -e "$EXTERNALS_DIR/$ext" ] && ok "external $ext" || err "external $ext absent"
    done
    [ -f "$EXTERNALS_DIR/critapec/midifile/midifile.pd_linux" ] && ok "midifile compilé" || err "midifile non compilé"
    local want_lua; want_lua=$(read_manifest "$MANIFEST_DIR/pdlua-version.txt" | head -1)
    grep -q "VERSION $want_lua;" "$EXTERNALS_DIR/pdlua/pdlua-meta.pd" 2>/dev/null \
        && ok "pdlua $want_lua" || err "pdlua ≠ $want_lua (le 0.7.3 de Debian casse pdjson)"
    [ -f /usr/local/share/lua/5.4/lunajson.lua ] && ok "lunajson (Lua 5.4)" || err "lunajson absent de Lua 5.4"

    log ""
    log "${C_BOLD}Dépôts${C_RESET}"
    local url dir branch
    while read -r url dir branch; do
        [ -z "$url" ] && continue
        local d="$HOME/$dir"
        if [ -d "$d/.git" ]; then
            local state; state=$([ -n "$(git -C "$d" status --porcelain -uno)" ] && echo "${C_YELLOW}modifié${C_RESET}" || echo "propre")
            log "  $(basename "$d") : $(git -C "$d" rev-parse --abbrev-ref HEAD) @ $(git -C "$d" rev-parse --short HEAD) ($state)"
        else
            err "$d non cloné"
        fi
    done < <(read_manifest "$MANIFEST_DIR/repos.txt")
    local protected; protected=$(git -C "$PD_REPO" ls-files -v -- "${RUNTIME_PATHS[@]}" 2>/dev/null | grep -c '^S')
    [ "${protected:-0}" -gt 0 ] && ok "fichiers écrits par le patch protégés de git ($protected)" || warn "fichiers écrits par le patch NON protégés (git pull peut les écraser)"

    log ""
    log "${C_BOLD}Application web${C_RESET}"
    if [ -f "$WEB_DIR/qmlwebsocketserver.wasm" ]; then
        log "  wasm : $(du -h "$WEB_DIR/qmlwebsocketserver.wasm" | cut -f1)  sha $(sha_of "$WEB_DIR/qmlwebsocketserver.wasm" | cut -c1-12)"
    else
        err "wasm absent de $WEB_DIR"
    fi
    [ -d "$WEB_DIR/node_modules" ] && ok "node_modules" || err "node_modules absent"

    log ""
    log "${C_BOLD}Services${C_RESET}"
    local unit
    for unit in "${SERVICES[@]}"; do
        local active; active=$(uctl is-active "$unit" 2>/dev/null); active=${active:-inconnu}
        case "$active" in
            active) ok "$unit" ;;
            *) err "$unit : $active" ;;
        esac
    done
    if [ "$(uctl is-active pedalier-midi-connect.timer 2>/dev/null)" = active ]; then
        ok "câblage MIDI rejoué toutes les 60 s (dernier passage : $(uctl show pedalier-midi-connect.service -p ExecMainExitTimestamp --value 2>/dev/null | cut -d' ' -f2-3))"
    else
        err "pedalier-midi-connect.timer inactif — le câblage ne sera pas repris"
    fi
    loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -q yes && ok "linger activé" || err "linger désactivé (rien ne démarrera au boot)"
    [ -f "$AUTOSTART_FILE" ] && ok "kiosque au démarrage de session" || err "kiosque non configuré"

    # Deux moteurs qui pilotent les mêmes sirènes, c'est la panne la plus
    # difficile à lire : le symptôme est une sirène qui oscille, pas un message.
    local n_pd n_rtp
    n_pd=$(pgrep -cf "pd -nogui.*$PD_PATCH")
    n_rtp=$(pgrep -cx rtpmidid)
    [ "${n_pd:-0}" -le 1 ] && ok "un seul Pure Data" || err "$n_pd Pure Data en parallèle — ils pilotent les mêmes sirènes"
    [ "${n_rtp:-0}" -le 1 ] && ok "un seul rtpmidid" || err "$n_rtp rtpmidid en parallèle"
    if crontab -l 2>/dev/null | grep -qe 'start\.pedalier\.sh' -e 'rtpmidi_connect'; then
        err "l'ancien démarrage traîne encore dans la crontab (pedalier-ctl autostart le retire)"
        crontab -l 2>/dev/null | grep -e 'start\.pedalier\.sh' -e 'rtpmidi_connect' | sed 's/^/    /'
    else
        ok "crontab sans ancien démarrage"
    fi

    log ""
    log "${C_BOLD}Réseau et MIDI${C_RESET}"
    ss -ltn 2>/dev/null | grep -q ":$WS_PORT " && ok "WebSocket $WS_PORT (Pure Data)" || err "rien sur $WS_PORT"
    ss -ltn 2>/dev/null | grep -q ":$WEB_PORT " && ok "HTTP $WEB_PORT (node)" || err "rien sur $WEB_PORT"
    if curl -fsS --max-time 3 "http://localhost:$WEB_PORT/api/system-info" >/dev/null 2>&1; then
        ok "/api/system-info : $(curl -fsS --max-time 3 "http://localhost:$WEB_PORT/api/system-info")"
    else
        err "/api/system-info ne répond pas"
    fi
    if aconnect -l >/dev/null 2>&1; then
        local connected; connected=$(aconnect -l | grep -c "Connecting To" || true)
        log "  ports ALSA : $(aconnect -l | grep -c "^client") clients, $connected connexions"
        aconnect -l | grep -iE "rtpmidid|pure data" | sed 's/^/  /'
    fi
}

# ---------------------------------------------------------------------------
# enchaînement
# ---------------------------------------------------------------------------

should_run() {
    local p="$1"
    [ -n "$ONLY_PHASE" ] && { [ "$ONLY_PHASE" = "$p" ] && return 0 || return 1; }
    case " $SKIP_PHASES " in *" $p "*) return 1 ;; esac
    return 0
}

run_phase() { should_run "$1" && "phase_${1//-/_}"; return 0; }

cmd_bootstrap() {
    acquire_lock "$STATE_DIR/lock"
    local started; started=$(date +%s)

    if should_run preflight; then
        phase_preflight || die "vérifications préalables en échec — rien n'a été modifié"
    fi

    # Avant toute opération git : ce qui a été joué sur le pédalier ne doit jamais
    # être la victime d'une mise à jour.
    should_run songs && cmd_songs_save

    run_phase deps
    run_phase repos
    run_phase migrate
    run_phase pd-build
    run_phase externals
    run_phase web
    run_phase midi
    run_phase autostart

    if [ "$NO_RESTART" != true ] && [ -z "$ONLY_PHASE" ]; then
        cmd_stop --orphans
        cmd_start
    fi

    phase "Terminé en $(( $(date +%s) - started )) s"
    log "  ${C_DIM}vérification : pedalier-ctl doctor${C_RESET}"
}

main() {
    # Un flux unique : les avertissements doivent rester à leur place dans le
    # déroulé des phases, pas remonter en vrac à la fin d'un tube ssh.
    exec 2>&1

    local cmd=""
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --yes|-y) ASSUME_YES=true ;;
            --verbose|-v) VERBOSE=true ;;
            --no-restart) NO_RESTART=true ;;
            --force-pd) FORCE_PD=true ;;
            --only) ONLY_PHASE="${2:?}"; shift ;;
            --skip) SKIP_PHASES="$SKIP_PHASES ${2:?}"; shift ;;
            --help|-h) usage; exit 0 ;;
            -*) die "option inconnue : $1" ;;
            *) [ -z "$cmd" ] && cmd="$1" || args+=("$1") ;;
        esac
        shift
    done

    [ "$DRY_RUN" = true ] && warn "mode simulation : aucune modification ne sera faite"

    case "${cmd:-bootstrap}" in
        bootstrap|update) cmd_bootstrap ;;
        preflight)        phase_preflight ;;
        deps|repos|migrate|externals|web|midi|autostart)
            if [ "$cmd" = migrate ] && [ "${args[0]:-}" = "--finalize" ]; then
                migrate_finalize
            else
                acquire_lock "$STATE_DIR/lock"; "phase_$cmd"
            fi ;;
        pd-build)         acquire_lock "$STATE_DIR/lock"; phase_pd_build ;;
        start)            cmd_start ;;
        stop)             cmd_stop "${args[0]:-}" ;;
        restart)          cmd_stop --orphans; cmd_start ;;
        status)           cmd_status ;;
        logs)             cmd_logs "${args[0]:-}" ;;
        doctor)           cmd_doctor ;;
        songs)
            case "${args[0]:-list}" in
                save)    cmd_songs_save ;;
                restore) cmd_songs_restore "${args[1]:-}" ;;
                list)    cmd_songs_list ;;
                *)       die "songs : save | restore <archive> | list" ;;
            esac ;;
        *) err "commande inconnue : $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
