#!/bin/bash

# Script de persistance pour activer Wayland sur VS Code Flatpak (Fonctionne le 16 octobre 2025)
# Modifie le fichier .desktop système et installe le script de façon permanente
# Active le support Wayland avec les flags appropriés
# Assure la persistance via systemd

# Configuration
SYSTEM_DESKTOP_FILE="/var/lib/flatpak/exports/share/applications/com.visualstudio.code.desktop"
SCRIPT_DIR="/usr/local/bin"
SCRIPT_NAME="vscode_wayland_enabler.sh"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"
SYSTEMD_SERVICE_NAME="vscode-wayland.service"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$SYSTEMD_SERVICE_NAME"
MARKER_COMMENT="# Modified by vscode_wayland script"

# Vérifier si $0 commence par / (chemin absolu)
SCRIPT_EXEC="$(readlink -f "$0")"

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

# Fonction pour vérifier si le script est présent
is_script_present() {
    [[ -f "$SCRIPT_PATH" ]]
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
    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=VS Code Wayland Persistence Service
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_EXEC install
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

# Fonction pour modifier les lignes Exec
modify_desktop_file() {
    echo "Modification du fichier .desktop système pour Wayland"
    
    # Sauvegarder les permissions originales
    local original_perms=$(stat -c "%a" "$SYSTEM_DESKTOP_FILE")
    local original_owner=$(stat -c "%U:%G" "$SYSTEM_DESKTOP_FILE")
    
    # Créer un fichier temporaire pour les modifications
    local temp_file=$(mktemp)
    
    # Ajouter le marqueur de modification au début du fichier
    echo "$MARKER_COMMENT" > "$temp_file"
    
    # Modifier toutes les lignes Exec= pour ajouter les flags Wayland
    while IFS= read -r line; do
        if [[ "$line" =~ ^Exec= ]]; then
            # Ajouter --socket=wayland après --file-forwarding et les flags après com.visualstudio.code
            modified_line=$(echo "$line" | sed 's/--file-forwarding/--file-forwarding --socket=wayland/; s/com\.visualstudio\.code/com.visualstudio.code --enable-features=UseOzonePlatform --ozone-platform=wayland/')
            echo "$modified_line" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$SYSTEM_DESKTOP_FILE"
    
    # Vérifier que la modification a fonctionné
    if grep -q "UseOzonePlatform" "$temp_file"; then
        mv "$temp_file" "$SYSTEM_DESKTOP_FILE"
        
        # Restaurer les permissions et propriétaire originaux
        chmod "$original_perms" "$SYSTEM_DESKTOP_FILE"
        chown "$original_owner" "$SYSTEM_DESKTOP_FILE"
        
        echo "Modification du fichier .desktop réussie"
        echo "Permissions restaurées: $original_perms ($original_owner)"
        return 0
    else
        rm -f "$temp_file"
        echo "Erreur lors de la modification du fichier .desktop"
        return 1
    fi
}

# Fonction principale d'installation
install_system() {
    echo "Installation du système d'activation Wayland pour VS Code"
    echo "======================================================"
    
    # Vérifier si déjà installé
    if is_already_modified; then
        echo "Le système est déjà installé et configuré."
        
        # Vérifier si le service existe
        if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
            # Vérifier si le service est déjà actif
            if is_service_active; then
                echo "Le service systemd est déjà actif."
                exit 0
            else
                echo "Le service systemd n'est pas actif. Activation en cours..."
                enable_systemd_service
                exit 0
            fi
        else
            echo "Le service systemd est manquant. Recréation en cours..."
            # Recréer le service systemd
            echo "Création du service systemd: $SYSTEMD_SERVICE_NAME"
            create_systemd_service
            enable_systemd_service
            exit 0
        fi
        
        echo "Utilisez '$0 uninstall' pour désinstaller d'abord."
        exit 0
    fi
    
    # Étape 1: Vérifier l'existence du fichier système
    if [[ ! -f "$SYSTEM_DESKTOP_FILE" ]]; then
        echo "Erreur: Le fichier $SYSTEM_DESKTOP_FILE n'existe pas"
        echo "Assurez-vous que VS Code Flatpak est installé"
        exit 1
    fi
    
    # Afficher les lignes Exec= actuelles
    echo "Lignes Exec= trouvées dans le fichier .desktop:"
    grep "^Exec=" "$SYSTEM_DESKTOP_FILE" | nl
    echo ""
    
    # Afficher les permissions actuelles
    echo "Permissions actuelles du fichier .desktop: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
    
    # Étape 2: Créer le répertoire du script si nécessaire
    if [[ ! -d "$SCRIPT_DIR" ]]; then
        echo "Création du répertoire $SCRIPT_DIR"
        mkdir -p "$SCRIPT_DIR"
    fi
    
    # Étape 3: Copier le script courant vers le répertoire de destination
    echo "Le script est déployer ici $SCRIPT_PATH"
    
    # Définir les permissions appropriées
    chmod 755 "$SCRIPT_PATH"
    chown root:root "$SCRIPT_PATH"
    echo "Permissions définies pour le script: 755 root:root"
    
    # Étape 4: Créer et activer le service systemd
    echo "Création du service systemd: $SYSTEMD_SERVICE_NAME"
    create_systemd_service
    enable_systemd_service
    
    # Étape 5: Sauvegarder le fichier original
    if ! backup_original_file; then
        echo "Abandon de l'installation en raison de l'échec de la sauvegarde"
        exit 1
    fi
    
    # Étape 6: Modifier le fichier .desktop
    if ! modify_desktop_file; then
        echo "Erreur lors de la modification du fichier .desktop"
        exit 1
    fi
    
    # Étape 7: Afficher les nouvelles lignes Exec=
    echo ""
    echo "Nouvelles lignes Exec= après modification:"
    grep "^Exec=" "$SYSTEM_DESKTOP_FILE" | nl
    
    # Étape 8: Mettre à jour la base de données des applications
    echo ""
    echo "Mise à jour de la base de données des applications"
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    
    echo "======================================================"
    echo "Installation terminée avec succès!"
    echo ""
    echo "Résumé:"
    echo "  Script d'activation installé: $SCRIPT_PATH"
    echo "  Service systemd installé: $SYSTEMD_SERVICE_FILE"
    echo "  Fichier modifié: $SYSTEM_DESKTOP_FILE"
    echo "  Permissions conservées: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
    echo "  Sauvegarde créée avec timestamp"
    echo ""
    echo "Le support Wayland est activé pour VS Code."
    echo "Le service systemd s'exécutera au démarrage du système pour assurer la persistance."
}

# Fonction de désinstallation
uninstall_system() {
    echo "Désinstallation du système d'activation Wayland"
    echo "=============================================="
    
    # Vérifier si le système est installé
    if ! is_already_modified; then
        echo "Le système ne semble pas être installé."
        echo "Aucune action nécessaire."
        exit 0
    fi
    
    # Supprimer le service systemd
    echo "Suppression du service systemd"
    remove_systemd_service
    
    # Trouver le fichier de sauvegarde le plus récent
    local backup_file=$(find "$(dirname "$SYSTEM_DESKTOP_FILE")" -name "com.visualstudio.code_*.old" -type f | sort | tail -1)
    
    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        echo "Restauration depuis: $backup_file"
        cp "$backup_file" "$SYSTEM_DESKTOP_FILE"
        
        # Restaurer les permissions du fichier de sauvegarde
        chmod --reference="$backup_file" "$SYSTEM_DESKTOP_FILE"
        
        echo "Fichier .desktop restauré avec ses permissions originales"
    else
        echo "Aucun fichier de sauvegarde trouvé"
        echo "Suppression manuelle du marqueur et des modifications..."
        
        # Supprimer manuellement les modifications
        local temp_file=$(mktemp)
        grep -v "$MARKER_COMMENT" "$SYSTEM_DESKTOP_FILE" | \
        sed 's/--socket=wayland //g; s/ --enable-features=UseOzonePlatform --ozone-platform=wayland//g' > "$temp_file"
        
        mv "$temp_file" "$SYSTEM_DESKTOP_FILE"
        echo "Modifications supprimées manuellement"
    fi
    
    # Supprimer le script
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        echo "Script d'activation supprimé: $SCRIPT_PATH"
    fi

    # Supprimer les anciens raccourcis vscode
    echo "Suppression des anciens raccourcis vscode"
    rm -rf /var/lib/flatpak/exports/share/applications/com.visualstudio.code_*


    # Mettre à jour la base de données
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    
    echo "Désinstallation terminée"
    echo "Permissions finales: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
}

# Fonction de statut
show_status() {
    echo "Statut du système d'activation Wayland pour VS Code"
    echo "=================================================="
    
    if [[ -f "$SYSTEM_DESKTOP_FILE" ]]; then
        echo "Fichier .desktop: TROUVÉ"
        echo "Permissions: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
        
        if is_already_modified; then
            echo "État: INSTALLÉ ET CONFIGURÉ"
            echo ""
            echo "Lignes Exec= actuelles:"
            grep "^Exec=" "$SYSTEM_DESKTOP_FILE" | nl
        else
            echo "État: NON CONFIGURÉ"
        fi
    else
        echo "Fichier .desktop: NON TROUVÉ"
    fi
    
    if [[ -f "$SCRIPT_PATH" ]]; then
        echo "Script d'activation: INSTALLÉ ($SCRIPT_PATH)"
        echo "Permissions du script: $(stat -c "%a %U:%G" "$SCRIPT_PATH")"
    else
        echo "Script d'activation: NON INSTALLÉ"
    fi
    
    # Vérifier le service systemd
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        echo "Service systemd: INSTALLÉ ($SYSTEMD_SERVICE_FILE)"
        systemctl is_active --quiet "$SYSTEMD_SERVICE_NAME" && echo "Service systemd: ACTIF" || echo "Service systemd: INACTIF"
        systemctl is_enabled --quiet "$SYSTEMD_SERVICE_NAME" && echo "Service systemd: ACTIVÉ AU DÉMARRAGE" || echo "Service systemd: DÉSACTIVÉ AU DÉMARRAGE"
    else
        echo "Service systemd: NON INSTALLÉ"
    fi
    
    # Compter les sauvegardes
    local backup_count=$(find "$(dirname "$SYSTEM_DESKTOP_FILE")" -name "com.visualstudio.code_*.old" -type f 2>/dev/null | wc -l)
    echo "Sauvegardes disponibles: $backup_count"
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
    *)
        echo "Usage: $0 [install|uninstall|status]"
        echo ""
        echo "  install   - Installe le système d'activation Wayland (par défaut)"
        echo "  uninstall - Désinstalle et restaure les fichiers originaux"
        echo "  status    - Affiche l'état actuel du système"
        exit 1
        ;;
esac