#!/bin/bash

# Script de persistance pour modifier Chromium Flatpak (Fonctionne le 16 septembre 2025)
# Modifie le fichier .desktop système et installe le script de façon permanente
# Fix :
# Active l'acceleration GPU 
# résoud le problème des icone non persistante
# Version tout-en-un

# Configuration
SYSTEM_DESKTOP_FILE="/var/lib/flatpak/exports/share/applications/org.chromium.Chromium.desktop"
SYSTEMD_SERVICE_NAME="chromium-persistence.service"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$SYSTEMD_SERVICE_NAME"
MARKER_COMMENT="# Modified by chromium_persistence script"

# Vérifier les privilèges root
if [[ $EUID -ne 0 ]]; then
    echo "Erreur: Ce script doit être exécuté avec les privilèges root (sudo)."
    exit 1
fi

# Fonction pour vérifier si le fichier a déjà été modifié
is_already_modified() {
    if [[ -f "$SYSTEM_DESKTOP_FILE" ]]; then
        grep -q "$MARKER_COMMENT" "$SYSTEM_DESKTOP_FILE"
        return $?
    fi
    return 1
}

# Fonction pour vérifier si le service systemd est déjà actif
is_service_active() {
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        systemctl is-active --quiet "$SYSTEMD_SERVICE_NAME"
        return $?
    fi
    return 1
}

# Fonction pour créer le service systemd
create_systemd_service() {
    # Vérifier si $0 commence par / (chemin absolu)
    SCRIPT_EXEC="$(readlink -f "$0")"

    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=Chromium Persistence Service
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_EXEC
RemainAfterExit=yes
User=root

[Install]
WantedBy=default.target
EOF
}

# Fonction pour activer le service systemd
enable_systemd_service() {
    systemctl daemon-reload
    systemctl enable "$SYSTEMD_SERVICE_NAME"
    echo "Service systemd créé et activé: $SYSTEMD_SERVICE_FILE"
}

# Fonction pour désactiver et supprimer le service systemd
remove_systemd_service() {
    systemctl disable "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    echo "Service systemd supprimé: $SYSTEMD_SERVICE_FILE"
}

# --- LOGIQUE DE CORRECTION UTILISATEUR (INTEGRÉE) ---

process_user_fixes() {
    local username="$1"
    local home_dir="$2"
    
    echo "[$(date)] Traitement de l'utilisateur: $username" >&2
    
    target_dir="$home_dir/.local/share/applications"
    file_pattern="org.chromium.Chromium.flextop.chrome-*"
    
    # echo "[$(date)] Vérification du répertoire: $target_dir" >&2
    
    if [[ ! -d "$target_dir" ]]; then
        # echo "[$(date)] Répertoire non trouvé pour $username, passage à l'utilisateur suivant" >&2
        return
    fi
    
    # echo "[$(date)] Recherche des fichiers correspondant au motif: $file_pattern" >&2
    
    files_found=0
    files_modified=0
    
    for file in "$target_dir"/$file_pattern; do
        if [[ ! -f "$file" ]]; then
            continue
        fi
        
        files_found=$((files_found + 1))
        
        # Calculer le hash du fichier avant modification pour vérifier s'il a vraiment changé
        local md5_before=$(md5sum "$file" | cut -d' ' -f1)
        
        # 1. Corriger la classe WM
        if grep -q "^StartupWMClass=crx_" "$file"; then
            sed -i 's/^StartupWMClass=crx_\([^[:space:]]*\)$/StartupWMClass=chrome-\1-Default/' "$file"
        fi
        
        # 2. Corriger les lignes Exec=
        if grep -q "^Exec=.*org\.chromium\.Chromium" "$file"; then
             # Stratégie idempotente : on retire tout flag existant, puis on en remet un seul à la fin.
             # Cela gère les doublons, les manquants, et les fichiers multi-actions (Exec multiples).
             
             # Étape A: Supprimer toutes les occurrences du flag sur les lignes Exec
             sed -i '/^Exec=.*org\.chromium\.Chromium/ s/ --enable-features=AcceleratedVideoDecodeLinuxGL//g' "$file"
             
             # Étape B: Ajouter le flag à la fin de toutes les lignes Exec
             sed -i '/^Exec=.*org\.chromium\.Chromium/ s/$/ --enable-features=AcceleratedVideoDecodeLinuxGL/' "$file"
        fi
        
        # Calculer le hash après
        local md5_after=$(md5sum "$file" | cut -d' ' -f1)
        
        if [[ "$md5_before" != "$md5_after" ]]; then
            echo "[$(date)] Corrigé: $(basename "$file")" >&2
            files_modified=$((files_modified + 1))
        fi

    done
    
    if [[ $files_found -gt 0 ]]; then
        echo "[$(date)] Terminé pour $username. Trouvés: $files_found, Modifiés: $files_modified" >&2
    fi
}

process_user_revert() {
    local username="$1"
    local home_dir="$2"
    
    target_dir="$home_dir/.local/share/applications"
    file_pattern="org.chromium.Chromium.flextop.chrome-*"
    
    if [[ ! -d "$target_dir" ]]; then
        return
    fi
    
    files_reverted=0
    
    for file in "$target_dir"/$file_pattern; do
        if [[ ! -f "$file" ]]; then
            continue
        fi
        
        if grep -q "AcceleratedVideoDecodeLinuxGL" "$file"; then
             # Suppression du flag
             sed -i 's/ --enable-features=AcceleratedVideoDecodeLinuxGL//g' "$file"
             files_reverted=$((files_reverted + 1))
        fi
    done
    
    if [[ $files_reverted -gt 0 ]]; then
        echo "[$(date)] Nettoyage pour $username: $files_reverted fichiers restaurés." >&2
    fi
}

run_fixes_all_users() {
    echo "Démarrage du scan des correctifs utilisateurs..."
    process_all_users "fix"
    echo "Scan des correctifs terminé."
}

revert_fixes_all_users() {
    echo "Nettoyage des modifications utilisateurs..."
    process_all_users "revert"
    echo "Nettoyage terminé."
}

process_all_users() {
    local action="$1"
    # Pour chaque utilisateur avec un répertoire home
    while IFS=: read -r username _ uid gid _ home_dir _; do
        if [[ "$username" != "root" ]] && [[ -d "$home_dir" ]]; then
            export HOME="$home_dir"
            if [[ "$action" == "fix" ]]; then
                process_user_fixes "$username" "$home_dir"
            elif [[ "$action" == "revert" ]]; then
                process_user_revert "$username" "$home_dir"
            fi
        fi
    done < /etc/passwd
}

# --- FIN LOGIQUE UTILISATEUR ---


# Fonction pour sauvegarder le fichier original
backup_original_file() {
    if [[ -f "$SYSTEM_DESKTOP_FILE" ]]; then
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        local backup_file="${SYSTEM_DESKTOP_FILE%.*}_${timestamp}.old"
        
        echo "Sauvegarde du fichier original vers: $backup_file"
        cp "$SYSTEM_DESKTOP_FILE" "$backup_file"
        
        # Conserver les permissions originales pour la sauvegarde
        chmod --reference="$SYSTEM_DESKTOP_FILE" "$backup_file"
        
        if [[ $? -eq 0 ]]; then
            echo "Sauvegarde réussie"
            return 0
        else
            echo "Erreur lors de la sauvegarde"
            return 1
        fi
    else
        echo "Erreur: Le fichier $SYSTEM_DESKTOP_FILE n'existe pas"
        return 1
    fi
}

# Fonction pour modifier et corriger le fichier .desktop système
modify_desktop_file() {
    echo "Modification du fichier .desktop système"
    
    # Vérifier que le fichier existe
    if [[ ! -f "$SYSTEM_DESKTOP_FILE" ]]; then
        echo "[$(date)] Fichier système non trouvé: $SYSTEM_DESKTOP_FILE" >&2
        return 1
    fi

    echo "[$(date)] Traitement du fichier système: $SYSTEM_DESKTOP_FILE" >&2
    
    # Sauvegarder les permissions originales
    local original_perms=$(stat -c "%a" "$SYSTEM_DESKTOP_FILE")
    local original_owner=$(stat -c "%U:%G" "$SYSTEM_DESKTOP_FILE")
    
    # Créer un fichier temporaire pour les modifications
    local temp_file=$(mktemp)
    
    # Ajouter le marqueur de modification au début du fichier
    echo "$MARKER_COMMENT" > "$temp_file"
    
    # Modifier toutes les lignes Exec= pour ajouter l'accélération GPU
    # Noter : On n'utilise plus de wrapper script ici (USE_WRAPPER était false)
    while IFS= read -r line; do
        if [[ "$line" =~ ^Exec= ]]; then
            # Extraire la commande complète après "Exec="
            local exec_content="${line#Exec=}"
            
            # Vérifier si c'est une commande flatpak pour Chromium (avec ou sans chemin complet)
            if [[ "$exec_content" =~ (^|.*/)(flatpak).*org\.chromium\.Chromium ]]; then
                # Ajouter l'accélération matérielle si elle n'est pas déjà présente
                if [[ ! "$exec_content" =~ AcceleratedVideoDecodeLinuxGL ]]; then
                    echo "[$(date)] Ajout de l'accélération matérielle dans: $line" >&2
                    
                    # Toujours insérer après org.chromium.Chromium
                    exec_content=$(echo "$exec_content" | sed 's|org\.chromium\.Chromium|org.chromium.Chromium --enable-features=AcceleratedVideoDecodeLinuxGL|')
                fi

                # FIX: Suppression de "@@u %U @@" qui perturbe la detection de fenetre Gnome
                if [[ "$exec_content" =~ "@@u %U @@" ]]; then
                    echo "[$(date)] Nettoyage de @@u %U @@ -> %U" >&2
                    exec_content=${exec_content//@@u %U @@/%U}
                fi
                
                echo "Exec=$exec_content" >> "$temp_file"
            else
                # Conserver les autres lignes Exec= non-Chromium telles quelles
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$SYSTEM_DESKTOP_FILE"
    
    # Vérifier que la modification a fonctionné (accélération ajoutée)
    local verification_passed=false
    if grep -q "AcceleratedVideoDecodeLinuxGL" "$temp_file"; then
        verification_passed=true
    fi

    if [[ "$verification_passed" == "true" ]]; then
        mv "$temp_file" "$SYSTEM_DESKTOP_FILE"
        
        # Restaurer les permissions et propriétaire originaux
        chmod "$original_perms" "$SYSTEM_DESKTOP_FILE"
        chown "$original_owner" "$SYSTEM_DESKTOP_FILE"
        
        echo "Modification du fichier .desktop réussie"
        echo "Permissions restaurées: $original_perms ($original_owner)"
        echo "[$(date)] Accélération matérielle ajoutée avec succès" >&2
        return 0
    else
        rm -f "$temp_file"
        echo "Erreur lors de la modification du fichier .desktop"
        return 1
    fi
}

# Fonction principale d'installation
install_system() {
    echo "Installation du système de persistance Chromium"
    echo "=============================================="
    
    # Vérifier l'existence du fichier système
    if [[ ! -f "$SYSTEM_DESKTOP_FILE" ]]; then
        echo "Erreur: Le fichier $SYSTEM_DESKTOP_FILE n'existe pas"
        echo "Assurez-vous que Chromium Flatpak est installé"
        exit 1
    fi
    
    # Si déjà modifié, on continue quand même pour vérifier le service et lancer les fixes
    if is_already_modified; then
        echo "Le fichier .desktop semble déjà modifié."
    else
        # Afficher les permissions actuelles
        echo "Permissions actuelles du fichier .desktop: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
        
        # Sauvegarder le fichier original
        if ! backup_original_file; then
            echo "Abandon de l'installation en raison de l'échec de la sauvegarde"
            exit 1
        fi
        
        # Modifier le fichier .desktop
        if ! modify_desktop_file; then
            echo "Erreur lors de la modification du fichier .desktop"
            exit 1
        fi
        
        # Mettre à jour la base de données des applications
        echo "Mise à jour de la base de données des applications"
        update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    fi

    # Gérer le service systemd
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
         if is_service_active; then
            echo "Le service systemd est déjà actif."
        else
            echo "Réactivation du service systemd..."
            enable_systemd_service
        fi
    else
        echo "Création du service systemd: $SYSTEMD_SERVICE_NAME"
        create_systemd_service
        enable_systemd_service
    fi
    
    # Lancer les corrections immédiatement
    echo ""
    echo "Exécution des correctifs utilisateurs..."
    run_fixes_all_users
    
    echo "=============================================="
    echo "Installation terminée avec succès!"
    echo "Le service systemd ($SYSTEMD_SERVICE_NAME) est configuré"
}

# Fonction de désinstallation
uninstall_system() {
    echo "Désinstallation du système de persistance"
    echo "========================================="
    
    # Supprimer le service systemd
    echo "Suppression du service systemd"
    remove_systemd_service
    
    # Restaurer le fichier .desktop
    local backup_file=$(find "$(dirname "$SYSTEM_DESKTOP_FILE")" -name "org.chromium.Chromium_*.old" -type f | sort | tail -1)
    
    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo "Restauration depuis: $backup_file"
        cp "$backup_file" "$SYSTEM_DESKTOP_FILE"
        chmod --reference="$backup_file" "$SYSTEM_DESKTOP_FILE"
        echo "Fichier .desktop restauré avec ses permissions originales"
    else
        if grep -q "$MARKER_COMMENT" "$SYSTEM_DESKTOP_FILE"; then
            echo "Aucun fichier de sauvegarde trouvé, tentative de nettoyage manuel..."
            # On tente d'enlever le comment et les args ajoutés, mais c'est risqué avec sed complexe.
            # Pour l'instant on garde la logique précédente simple ou on avertit.
            # Ici on va juste enlever le marqueur pour dire "plus géré" mais idéalement faudrait revert les sed.
            # Comme c'est un uninstall de secours, on fait au mieux.
            sed -i "/$MARKER_COMMENT/d" "$SYSTEM_DESKTOP_FILE"
            echo "Marqueur supprimé. Vous devrez peut-être réinstaller le flatpak pour un nettoyage complet si pas de backup."
        else
             echo "Le fichier ne semble pas modifié par ce script."
        fi
    fi
    
    # Supprimer les anciens fichiers générés par l'ancienne version s'ils existent encore
    local OLD_SCRIPT_PATH="/usr/local/bin/chromium_wmclass_fixer.sh"
    local OLD_WRAPPER_PATH="/usr/local/bin/chromium_wrapper.sh"
    if [[ -f "$OLD_SCRIPT_PATH" ]]; then
        rm -f "$OLD_SCRIPT_PATH"
        echo "Ancien script supprimé: $OLD_SCRIPT_PATH"
    fi
    if [[ -f "$OLD_WRAPPER_PATH" ]]; then
        rm -f "$OLD_WRAPPER_PATH"
        echo "Ancien wrapper supprimé: $OLD_WRAPPER_PATH"
    fi

    # Mettre à jour la base de données
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    
    # Nettoyer les fichiers utilisateurs
    revert_fixes_all_users
    
    echo "Désinstallation terminée"
}

# Fonction de statut
show_status() {
    echo "Statut du système de persistance Chromium"
    echo "========================================"
    
    if [[ -f "$SYSTEM_DESKTOP_FILE" ]]; then
        if is_already_modified; then
            echo "Fichier .desktop: INSTALLÉ (Modifié)"
        else
            echo "Fichier .desktop: NON MODIFIÉ par ce script"
        fi
    else
        echo "Fichier .desktop: NON TROUVÉ"
    fi

    # Vérifier le service systemd
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        echo "Service systemd: INSTALLÉ"
        systemctl is-active --quiet "$SYSTEMD_SERVICE_NAME" && echo "  État: ACTIF" || echo "  État: INACTIF"
        systemctl is-enabled --quiet "$SYSTEMD_SERVICE_NAME" && echo "  Boot: ACTIVÉ" || echo "  Boot: DÉSACTIVÉ"
    else
        echo "Service systemd: NON INSTALLÉ"
    fi
}

# Menu principal
case "${1:-install}" in
    "install")
        install_system
        ;;
    "uninstall")
        uninstall_system
        ;;
    "status")
        show_status
        ;;
    "run-fixes")
        run_fixes_all_users
        ;;
    *)
        echo "Usage: $0 [install|uninstall|status|run-fixes]"
        echo ""
        echo "  install   - Installe le service et modifie le fichier desktop"
        echo "  uninstall - Désinstalle et restaure"
        echo "  status    - Affiche l'état"
        echo "  run-fixes - Lance manuellement les corrections utilisateurs"
        exit 1
        ;;
esac