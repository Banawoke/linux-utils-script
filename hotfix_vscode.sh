#!/bin/bash

# Script de persistance pour activer Wayland sur VS Code Flatpak (Fonctionne le 6 décembre 2025)
# Modifie le fichier .desktop système et installe le script de façon permanente
# Active le support Wayland avec les flags appropriés
# Assure la persistance via systemd

# TODO: ajouter vscodium flatpak/non-flatpak

# Configuration
# Configuration
DESKTOP_FILES=(
    "/var/lib/flatpak/exports/share/applications/com.visualstudio.code.desktop"
    "/usr/share/applications/code.desktop"
    "/usr/share/applications/antigravity.desktop"
)
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

# Fonction pour vérifier si un fichier spécifique a déjà été modifié
is_file_modified() {
    local file="$1"
    if [[ -f "$file" ]]; then
        grep -q "$MARKER_COMMENT" "$file"
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
    local file="$1"
    if [[ -f "$file" ]]; then
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        local backup_file="${file%.*}_${timestamp}.old"
        
        echo "Sauvegarde du fichier original vers: $backup_file"
        cp "$file" "$backup_file"
        
        # Conserver les permissions originales pour la sauvegarde
        chmod --reference="$file" "$backup_file"
        
        if [[ $? -eq 0 ]]; then
            echo "Sauvegarde réussie de $file"
            return 0
        else
            echo "Erreur lors de la sauvegarde de $file"
            return 1
        fi
    else
        echo "Information: Le fichier $file n'existe pas, ignoré."
        return 1
    fi
}

# Fonction pour modifier les lignes Exec
modify_desktop_file() {
    local file="$1"
    echo "Modification du fichier .desktop système pour Wayland: $file"
    
    # Sauvegarder les permissions originales
    local original_perms=$(stat -c "%a" "$file")
    local original_owner=$(stat -c "%U:%G" "$file")
    
    # Créer un fichier temporaire pour les modifications
    local temp_file=$(mktemp)
    
    # Ajouter le marqueur de modification au début du fichier
    echo "$MARKER_COMMENT" > "$temp_file"
    
    # Modifier toutes les lignes Exec= pour ajouter les flags Wayland
    while IFS= read -r line; do
        if [[ "$line" =~ ^Exec= ]]; then
            # Ajouter --socket=wayland après --file-forwarding (pour Flatpak)
            # Ajouter --enable-features=UseOzonePlatform --ozone-platform=wayland pour tous
            modified_line="$line"
            
            # Gestion Flatpak
            if [[ "$modified_line" == *"--file-forwarding"* ]]; then
                 modified_line=$(echo "$modified_line" | sed 's/--file-forwarding/--file-forwarding --socket=wayland/')
            fi

            # Gestion des arguments
            if [[ "$modified_line" != *"UseOzonePlatform"* ]]; then
                 # On ajoute les arguments à la fin de la commande ou avant %F/%U si présents
                 if [[ "$modified_line" =~ (%[a-zA-Z]) ]]; then
                    # Insérer avant le paramètre %
                    modified_line=$(echo "$modified_line" | sed 's/ %\([a-zA-Z]\)/ --enable-features=UseOzonePlatform --ozone-platform=wayland %\1/')
                 else
                    # Ajouter à la fin
                    modified_line="$modified_line --enable-features=UseOzonePlatform --ozone-platform=wayland"
                 fi
            fi
            
            echo "$modified_line" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$file"
    
    # Vérifier que la modification a fonctionné
    if grep -q "UseOzonePlatform" "$temp_file"; then
        mv "$temp_file" "$file"
        
        # Restaurer les permissions et propriétaire originaux
        chmod "$original_perms" "$file"
        chown "$original_owner" "$file"
        
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
    echo "Installation du système d'activation Wayland pour VS Code et Antigravity"
    echo "======================================================================="
    
    local any_files_found=false
    
    # Étape 1: Créer le répertoire du script si nécessaire
    if [[ ! -d "$SCRIPT_DIR" ]]; then
        echo "Création du répertoire $SCRIPT_DIR"
        mkdir -p "$SCRIPT_DIR"
    fi
    
    # Étape 2: Copier le script courant vers le répertoire de destination
    echo "Le script est déployé ici $SCRIPT_PATH"
    
    # Définir les permissions appropriées
    chmod 755 "$SCRIPT_PATH"
    chown root:root "$SCRIPT_PATH"
    echo "Permissions définies pour le script: 755 root:root"
    
    # Étape 3: Créer et activer le service systemd
    if ! is_service_active; then
         echo "Création du service systemd: $SYSTEMD_SERVICE_NAME"
         create_systemd_service
         enable_systemd_service
    else
         echo "Le service systemd est déjà actif."
    fi

    # Étape 4: Traiter chaque fichier desktop
    for desktop_file in "${DESKTOP_FILES[@]}"; do
        if [[ -f "$desktop_file" ]]; then
            any_files_found=true
            echo ""
            echo "Traitement de: $desktop_file"
            
            if is_file_modified "$desktop_file"; then
                echo "  Déjà configuré."
            else
                if backup_original_file "$desktop_file"; then
                     modify_desktop_file "$desktop_file"
                fi
            fi
        fi
    done

    if [[ "$any_files_found" == "false" ]]; then
        echo "Aucun fichier desktop compatible trouvé."
        echo "Cherché: ${DESKTOP_FILES[*]}"
    fi
    
    # Étape 5: Mettre à jour la base de données des applications
    echo ""
    echo "Mise à jour de la base de données des applications"
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    update-desktop-database /usr/share/applications/ 2>/dev/null || true
    
    echo "======================================================"
    echo "Opérations terminées."
}

# Fonction de désinstallation
uninstall_system() {
    echo "Désinstallation du système d'activation Wayland"
    echo "=============================================="
    
    # Supprimer le service systemd
    echo "Suppression du service systemd"
    remove_systemd_service
    
    # Restaurer les fichiers desktop
    for desktop_file in "${DESKTOP_FILES[@]}"; do
        if [[ -f "$desktop_file" ]]; then
             echo "Restauration de $desktop_file..."
             
             # Trouver le fichier de sauvegarde le plus récent
             local backup_file=$(find "$(dirname "$desktop_file")" -name "$(basename "${desktop_file%.*}")_*.old" -type f | sort | tail -1)
             
             if [[ -n "$backup_file" && -f "$backup_file" ]]; then
                echo "  Restauration depuis: $backup_file"
                cp "$backup_file" "$desktop_file"
                chmod --reference="$backup_file" "$desktop_file"
                echo "  Restauré."
             elif grep -q "$MARKER_COMMENT" "$desktop_file"; then
                echo "  Pas de sauvegarde, nettoyage manuel..."
                local temp_file=$(mktemp)
                grep -v "$MARKER_COMMENT" "$desktop_file" | \
                sed 's/--socket=wayland //g; s/ --enable-features=UseOzonePlatform --ozone-platform=wayland//g' > "$temp_file"
                mv "$temp_file" "$desktop_file"
                echo "  Nettoyé."
             else
                echo "  Fichier non modifié par ce script."
             fi
        fi
    done
    
    # Supprimer le script
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        echo "Script d'activation supprimé: $SCRIPT_PATH"
    fi

    # Mettre à jour la base de données
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    update-desktop-database /usr/share/applications/ 2>/dev/null || true
    
    echo "Désinstallation terminée"
}

# Fonction de statut
show_status() {
    echo "Statut du système d'activation Wayland"
    echo "=================================================="
    
    for desktop_file in "${DESKTOP_FILES[@]}"; do
        if [[ -f "$desktop_file" ]]; then
            echo "Fichier: $desktop_file"
            if is_file_modified "$desktop_file"; then
                echo "  État: MODIFIÉ (Wayland actif)"
            else
                echo "  État: STANDARD"
            fi
        else
             echo "Fichier: $desktop_file (NON TROUVÉ)"
        fi
    done
    
    echo ""
    if [[ -f "$SCRIPT_PATH" ]]; then
        echo "Script d'activation: INSTALLÉ ($SCRIPT_PATH)"
    else
        echo "Script d'activation: NON INSTALLÉ"
    fi
    
    # Vérifier le service systemd
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        echo "Service systemd: INSTALLÉ"
        systemctl is-active --quiet "$SYSTEMD_SERVICE_NAME" && echo "  État: ACTIF" || echo "  État: INACTIF"
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
    *)
        echo "Usage: $0 [install|uninstall|status]"
        echo ""
        echo "  install   - Installe le système d'activation Wayland (par défaut)"
        echo "  uninstall - Désinstalle et restaure les fichiers originaux"
        echo "  status    - Affiche l'état actuel du système"
        exit 1
        ;;
esac