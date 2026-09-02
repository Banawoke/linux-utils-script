#!/usr/bin/env bash
#
# Script de persistance pour corriger les icônes et le groupement des PWA Chromium / Chrome sur Wayland (GNOME / Mutter)
#
# Problème résolu :
# Sur Wayland, Chromium attribue aux fenêtres PWA un app_id au format 'chrome-<app_id>-<profile>'.
# Cependant, les fichiers .desktop générés par Chromium/Flatpak continuent d'écrire 'StartupWMClass=crx_<app_id>'.
# GNOME Shell ne trouvant pas de correspondance, il regroupe la fenêtre PWA sous l'icône générique du navigateur.
#
# Fonctionnalités de ce script :
# 1. 100% Espace Utilisateur (aucun droit root / sudo nécessaire).
# 2. Correction automatique du StartupWMClass selon l'app_id et le profil réel.
# 3. Autonome et persistant : installe un watcher systemd --user (Path/Service)
#    qui s'exécute automatiquement dès qu'un raccourci PWA est créé ou modifié.
# 4. Suppression des anciens hacks d'accélération matérielle obsolètes.

set -euo pipefail

# Configuration des répertoires utilisateur (XDG)
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
BIN_DIR="${HOME}/.local/bin"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

INSTALLED_SCRIPT_NAME="hotfix_chromium_pwa.sh"
INSTALLED_SCRIPT_PATH="${BIN_DIR}/${INSTALLED_SCRIPT_NAME}"

SERVICE_NAME="chromium-pwa-fix.service"
PATH_UNIT_NAME="chromium-pwa-fix.path"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
PATH_UNIT_FILE="${SYSTEMD_USER_DIR}/${PATH_UNIT_NAME}"

# Avertissement si exécuté avec sudo / root
check_not_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo "Attention : Ce script doit être exécuté avec votre utilisateur normal (sans sudo)." >&2
        echo "Les raccourcis et services concernés se trouvent dans votre espace personnel (\$HOME)." >&2
        exit 1
    fi
}

# Fonction principale de correction des fichiers .desktop
fix_pwa_desktop_files() {
    local verbose="${1:-false}"
    local modified_count=0
    local total_count=0

    if [[ ! -d "$APP_DIR" ]]; then
        [[ "$verbose" == "true" ]] && echo "Répertoire d'applications introuvable : $APP_DIR"
        return 0
    fi

    shopt -s nullglob
    local desktop_files=("$APP_DIR"/*.desktop)
    shopt -u nullglob

    for file in "${desktop_files[@]}"; do
        [[ -f "$file" ]] || continue

        # Détecter si le fichier est un lanceur PWA Chromium / Chrome / Flatpak
        if ! grep -q -E "(--app-id=|StartupWMClass=crx_|flextop\.chrome-)" "$file"; then
            continue
        fi

        ((total_count++)) || true

        # 1. Extraire l'ID de l'application
        local app_id=""
        if grep -q -E -- "--app-id=[a-zA-Z0-9]+" "$file"; then
            app_id=$(grep -o -E -- "--app-id=[a-zA-Z0-9]+" "$file" | head -n1 | cut -d'=' -f2)
        elif grep -q -E "^StartupWMClass=crx_[a-zA-Z0-9]+" "$file"; then
            app_id=$(grep -o -E "^StartupWMClass=crx_[a-zA-Z0-9]+" "$file" | head -n1 | sed 's/^StartupWMClass=crx_//')
        elif [[ "$file" =~ flextop\.chrome-([a-zA-Z0-9]+)- ]]; then
            app_id="${BASH_REMATCH[1]}"
        fi

        [[ -z "$app_id" ]] && continue

        # 2. Extraire le profil utilisateur (ex: Default, Profile_1)
        local profile="Default"
        if grep -q -E -- "--profile-directory=" "$file"; then
            profile=$(grep -o -E -- "--profile-directory=['\"]?[^'\" ]+['\"]?" "$file" | head -n1 | sed -E "s/--profile-directory=['\"]?//; s/['\"]?$//")
            profile="${profile// /_}" # Normalisation des espaces en underscore pour Wayland
        elif grep -q -E "^Icon=chrome-[a-zA-Z0-9]+-" "$file"; then
            profile=$(grep -o -E "^Icon=chrome-[a-zA-Z0-9]+-[^[:space:]]+" "$file" | head -n1 | awk -F'-' '{print $NF}')
        elif [[ "$file" =~ flextop\.chrome-[a-zA-Z0-9]+-(.+)\.desktop$ ]]; then
            profile="${BASH_REMATCH[1]}"
        fi

        # 3. Déterminer le préfixe (chrome, msedge, brave)
        local prefix="chrome"
        if grep -q -i "msedge" "$file"; then
            prefix="msedge"
        elif grep -q -i "brave" "$file"; then
            prefix="brave"
        fi

        local expected_wmclass="${prefix}-${app_id}-${profile}"
        local current_wmclass=""
        if grep -q "^StartupWMClass=" "$file"; then
            current_wmclass=$(grep "^StartupWMClass=" "$file" | head -n1 | cut -d'=' -f2)
        fi

        # 4. Appliquer la correction si nécessaire
        if [[ "$current_wmclass" != "$expected_wmclass" ]]; then
            local app_name
            app_name=$(grep "^Name=" "$file" | head -n1 | cut -d'=' -f2 || basename "$file")

            if grep -q "^StartupWMClass=" "$file"; then
                sed -i "s|^StartupWMClass=.*|StartupWMClass=${expected_wmclass}|" "$file"
            else
                sed -i "/^\[Desktop Entry\]/a StartupWMClass=${expected_wmclass}" "$file"
            fi

            echo "[FIX] $app_name : StartupWMClass mis à jour ('${current_wmclass}' -> '${expected_wmclass}')"
            ((modified_count++)) || true
        fi
    done

    # 5. Mettre à jour les bases de données et le cache d'icônes si des modifications ont eu lieu
    if [[ $modified_count -gt 0 ]]; then
        echo "Succès : $modified_count raccourci(s) PWA corrigé(s) (sur $total_count analysé(s))."
        update-desktop-database "$APP_DIR" 2>/dev/null || true
        if [[ -d "$ICON_DIR" ]]; then
            gtk-update-icon-cache -q -f -t "$ICON_DIR" 2>/dev/null || true
        fi
    elif [[ "$verbose" == "true" ]]; then
        echo "Tous les raccourcis PWA ($total_count analysé(s)) ont déjà un StartupWMClass valide."
    fi
}

# Création et activation des unités systemd --user (watcher + service)
install_systemd_user() {
    echo "=== Installation de la persistance utilisateur (systemd --user) ==="

    mkdir -p "$BIN_DIR" "$SYSTEMD_USER_DIR"

    # Copier le script actuel vers ~/.local/bin/ s'il n'y est pas déjà
    local current_script
    current_script="$(readlink -f "$0")"
    if [[ "$current_script" != "$INSTALLED_SCRIPT_PATH" ]]; then
        cp "$current_script" "$INSTALLED_SCRIPT_PATH"
        chmod +x "$INSTALLED_SCRIPT_PATH"
        echo "Script copié vers : $INSTALLED_SCRIPT_PATH"
    fi

    # Création du service systemd
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Fix Chromium PWA Wayland StartupWMClass
Documentation=https://github.com/flathub/org.chromium.Chromium/issues/216

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT_PATH fix
EOF

    # Création du path watcher systemd
    cat > "$PATH_UNIT_FILE" << EOF
[Unit]
Description=Watch for new or modified Chromium PWA desktop files
Documentation=https://github.com/flathub/org.chromium.Chromium/issues/216

[Path]
PathModified=%h/.local/share/applications
Unit=$SERVICE_NAME

[Install]
WantedBy=default.target
EOF

    echo "Unités créées :"
    echo "  - Service : $SERVICE_FILE"
    echo "  - Path    : $PATH_UNIT_FILE"

    # Recharger et activer
    systemctl --user daemon-reload
    systemctl --user enable --now "$PATH_UNIT_NAME"
    echo "Watcher systemd activé avec succès !"

    # Exécution immédiate des corrections
    echo ""
    echo "Exécution initiale des correctifs..."
    fix_pwa_desktop_files true
    echo ""
    echo "Installation terminée. Vos PWA conserveront désormais leurs icônes automatiquement."
}

# Désinstallation de la persistance systemd
uninstall_systemd_user() {
    echo "=== Désinstallation de la persistance utilisateur ==="

    systemctl --user disable --now "$PATH_UNIT_NAME" 2>/dev/null || true
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE_FILE" "$PATH_UNIT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true

    if [[ -f "$INSTALLED_SCRIPT_PATH" ]]; then
        rm -f "$INSTALLED_SCRIPT_PATH"
        echo "Script supprimé : $INSTALLED_SCRIPT_PATH"
    fi

    echo "Unités systemd désactivées et supprimées."
}

# Affichage du statut
show_status() {
    echo "=== Statut du correctif PWA Chromium (Wayland) ==="
    echo "Répertoire des applications : $APP_DIR"
    echo ""

    if [[ -f "$PATH_UNIT_FILE" ]]; then
        echo "Watcher systemd ($PATH_UNIT_NAME) : INSTALLÉ"
        systemctl --user is-active --quiet "$PATH_UNIT_NAME" && echo "  État  : ACTIF" || echo "  État  : INACTIF"
        systemctl --user is-enabled --quiet "$PATH_UNIT_NAME" && echo "  Boot  : ACTIVÉ" || echo "  Boot  : DÉSACTIVÉ"
    else
        echo "Watcher systemd : NON INSTALLÉ"
    fi

    echo ""
    echo "Vérification des raccourcis PWA existants :"
    fix_pwa_desktop_files true
}

# Aide
show_help() {
    cat << EOF
Usage: $(basename "$0") [action]

Corrige les icônes et le regroupement des PWA Chromium / Flatpak sur Wayland (GNOME/Mutter).

Actions:
  install       Installe le script dans ~/.local/bin, active le watcher systemd --user
                et applique les corrections immédiatement. (Action par défaut)
  fix, run      Exécute la vérification et la correction immédiate des raccourcis PWA.
  status        Affiche l'état du service systemd et des raccourcis PWA.
  uninstall     Désactive et supprime le watcher et le service systemd --user.
  -h, --help    Affiche cette aide.

Exemples:
  $(basename "$0")          # Installe et active la persistance
  $(basename "$0") fix      # Corrige les raccourcis à la volée
  $(basename "$0") status   # Vérifie l'état
EOF
}

# Point d'entrée
check_not_root

action="${1:-install}"
case "$action" in
    install)
        install_systemd_user
        ;;
    fix|run)
        fix_pwa_desktop_files "${2:-true}"
        ;;
    status)
        show_status
        ;;
    uninstall)
        uninstall_systemd_user
        ;;
    -h|--help)
        show_help
        ;;
    *)
        echo "Erreur: Action '$action' non reconnue." >&2
        echo ""
        show_help
        exit 1
        ;;
esac