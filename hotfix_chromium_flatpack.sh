#!/bin/bash

# Script de persistance pour modifier Chromium Flatpak (Fonctionne le 16 septembre 2025)
# Modifie le fichier .desktop système et installe le script de façon permanente
# Fix :
# Active l'acceleration GPU 
# résoud le problème des icone non persistante

# Configuration
SYSTEM_DESKTOP_FILE="/var/lib/flatpak/exports/share/applications/org.chromium.Chromium.desktop"
SCRIPT_DIR="/usr/local/bin"
SCRIPT_NAME="chromium_wmclass_fixer.sh"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"
WRAPPER_SCRIPT_NAME="chromium_wrapper.sh"
WRAPPER_SCRIPT_PATH="$SCRIPT_DIR/$WRAPPER_SCRIPT_NAME"
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

# Fonction pour vérifier si les scripts sont présents
are_scripts_present() {
    if [[ -f "$SCRIPT_PATH" ]] && [[ -f "$WRAPPER_SCRIPT_PATH" ]]; then
        return 0
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

# Fonction pour créer le script de correction WMClass
create_wmclass_script() {
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# Script automatique de correction des WMClass pour Chromium Flatpak

echo "[$(date)] Démarrage du script de correction WMClass" >&2

# Fonction pour traiter un utilisateur spécifique
process_user() {
    local username="$1"
    local home_dir="$2"
    
    echo "[$(date)] Traitement de l'utilisateur: $username" >&2
    
    target_dir="$home_dir/.local/share/applications"
    file_pattern="org.chromium.Chromium.flextop.chrome-*"
    
    echo "[$(date)] Vérification du répertoire: $target_dir" >&2
    
    if [[ ! -d "$target_dir" ]]; then
        echo "[$(date)] Répertoire non trouvé pour $username, passage à l'utilisateur suivant" >&2
        return
    fi
    
    echo "[$(date)] Recherche des fichiers correspondant au motif: $file_pattern" >&2
    
    files_found=0
    files_modified=0
    
    for file in "$target_dir"/$file_pattern; do
        if [[ ! -f "$file" ]]; then
            continue
        fi
        
        files_found=$((files_found + 1))
        echo "[$(date)] Traitement du fichier: $file" >&2
        
        # Corriger la classe WM
        if grep -q "^StartupWMClass=crx_" "$file"; then
            echo "[$(date)] Correction de la classe WM dans: $file" >&2
            sed -i 's/^StartupWMClass=crx_\([^[:space:]]*\)$/StartupWMClass=chrome-\1-Default/' "$file"
            files_modified=$((files_modified + 1))
        fi
        
        # Corriger les lignes Exec= pour ajouter l'accélération matérielle
        if grep -q "^Exec=.*org\.chromium\.Chromium" "$file"; then
            # Vérifier si l'accélération n'est pas déjà présente
            if ! grep -q "AcceleratedVideoDecodeLinuxGL" "$file"; then
                echo "[$(date)] Ajout de l'accélération matérielle dans: $file" >&2
                # Ajouter l'accélération matérielle à toutes les lignes Exec= Chromium
                sed -i '/^Exec=.*org\.chromium\.Chromium/s/$/ --enable-features=AcceleratedVideoDecodeLinuxGL/' "$file"
                files_modified=$((files_modified + 1))
            else
                echo "[$(date)] Accélération matérielle déjà présente dans: $file" >&2
            fi
        fi
    done
    
    echo "[$(date)] Traitement terminé pour $username. Fichiers trouvés: $files_found, Fichiers modifiés: $files_modified" >&2
}

# Traiter tous les utilisateurs avec un répertoire home
echo "[$(date)] Recherche des utilisateurs avec répertoire home" >&2

# Pour chaque utilisateur avec un répertoire home
while IFS=: read -r username _ uid gid _ home_dir _; do
    # Vérifier que l'utilisateur n'est pas root et que le répertoire home existe
    if [[ "$username" != "root" ]] && [[ -d "$home_dir" ]]; then
        # Définir la variable HOME pour cet utilisateur
        export HOME="$home_dir"
        process_user "$username" "$home_dir"
    fi
done < /etc/passwd

echo "[$(date)] Script de correction WMClass terminé pour tous les utilisateurs" >&2
EOF
}

# Fonction pour créer le script wrapper intelligent
create_wrapper_script() {
    cat > "$WRAPPER_SCRIPT_PATH" << 'EOF'
#!/bin/bash
# Script wrapper intelligent pour lancer Chromium avec correction WMClass

# Exécuter le script de correction WMClass
bash "/usr/local/bin/chromium_wmclass_fixer.sh"

# Vérifier si l'accélération n'est pas déjà présente
has_acceleration=false
for arg in "$@"; do
    if [[ "$arg" == "--enable-features=AcceleratedVideoDecodeLinuxGL" ]]; then
        has_acceleration=true
        break
    fi
done

# Vérifier si le profil par défaut est déjà spécifié
has_default_profile=false
for arg in "$@"; do
    if [[ "$arg" == "--profile-directory=Default" ]] || [[ "$arg" == "--profile-directory=\"Default\"" ]]; then
        has_default_profile=true
        break
    fi
done

    # Construire la commande
    original_command=""
    original_args=()

    # Debug: afficher tous les arguments reçus
    echo "Arguments reçus par le wrapper:" >&2
    printf "  %s\n" "$@" >&2

    if [[ -z "$1" ]]; then
        echo "Erreur: Aucun argument fourni au script wrapper. Impossible de déterminer la commande à exécuter." >&2
        exit 1
    fi

    # Si le premier argument est /usr/bin/flatpak, enlever le chemin complet
    if [[ "$1" == "/usr/bin/flatpak" ]]; then
        echo "Premier argument est /usr/bin/flatpak, normalisation vers 'flatpak'" >&2
        set -- "flatpak" "${@:2}"
    fi

    # Check if any of the arguments contain --enable-features=AcceleratedVideoDecodeLinuxGL
    has_acceleration=false
    for arg in "$@"; do
        if [[ "$arg" == *"--enable-features=AcceleratedVideoDecodeLinuxGL"* ]]; then
            has_acceleration=true
            echo "Accélération GPU déjà présente dans les arguments" >&2
            break
        fi
    done

    echo "État de l'accélération GPU: $has_acceleration" >&2

    # Check if any of the arguments contain --profile-directory=Default
    has_default_profile=false
    for arg in "$@"; do
        if [[ "$arg" == "--profile-directory=Default" ]] || [[ "$arg" == "--profile-directory=\"Default\"" ]]; then
            has_default_profile=true
            break
        fi
    done

    if [[ "$1" == "flatpak" ]]; then
        echo "Construction de la commande avec flatpak" >&2
        original_command="/usr/bin/flatpak"
        original_args=("${@:2}")
    else
        echo "Construction de la commande avec $1" >&2
        original_command="$1"
        original_args=("${@:2}")
    fi

    echo "Commande originale: $original_command" >&2
    echo "Arguments originaux:" >&2
    printf "  %s\n" "${original_args[@]}" >&2

    command_array=("$original_command" "${original_args[@]}")

    # Rechercher la position où insérer l'accélération GPU
    insert_position=-1
    chrome_binary_pos=-1
    for ((i=0; i<${#command_array[@]}; i++)); do
        if [[ "${command_array[i]}" == "--command=/app/bin/chromium" ]]; then
            echo "Position du binaire Chromium trouvée: $i" >&2
            chrome_binary_pos=$i
        elif [[ "${command_array[i]}" == "--file-forwarding" ]]; then
            echo "Position de --file-forwarding trouvée: $i" >&2
            insert_position=$i
            break
        fi
    done

    # Si on n'a pas trouvé --file-forwarding, insérer après --command=/app/bin/chromium
    if [[ $insert_position -eq -1 ]] && [[ $chrome_binary_pos -ne -1 ]]; then
        insert_position=$((chrome_binary_pos + 1))
        echo "Utilisation de la position après --command=/app/bin/chromium: $insert_position" >&2
    fi

    # Ajouter l'accélération matérielle si nécessaire
    if [[ "$has_acceleration" == "false" ]]; then
        if [[ $insert_position -ne -1 ]]; then
            echo "Insertion de l'accélération GPU à la position $insert_position" >&2
            command_array=("${command_array[@]:0:$insert_position}" "--enable-features=AcceleratedVideoDecodeLinuxGL" "${command_array[@]:$insert_position}")
        else
            echo "Ajout de l'accélération GPU à la fin" >&2
            command_array+=("--enable-features=AcceleratedVideoDecodeLinuxGL")
        fi
    fi

    # Ajouter le profil par défaut si nécessaire
    if [[ "$has_default_profile" == "false" ]]; then
        echo "Ajout du profil par défaut" >&2
        command_array+=("--profile-directory=Default")
    fi

    # Afficher la commande finale
    echo "Commande finale:" >&2
    printf "  %s\n" "${command_array[@]}" >&2

    # Exécuter la commande
    exec -- "${command_array[@]}"
EOF
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
    
    # Modifier toutes les lignes Exec= pour ajouter l'accélération GPU et le wrapper
    while IFS= read -r line; do
        if [[ "$line" =~ ^Exec= ]] && [[ ! "$line" =~ $WRAPPER_SCRIPT_NAME ]]; then
            # Extraire la commande complète après "Exec="
            local exec_content="${line#Exec=}"
            
            # Vérifier si c'est une commande flatpak pour Chromium (avec ou sans chemin complet)
            if [[ "$exec_content" =~ (^|.*/)(flatpak).*org\.chromium\.Chromium ]]; then
                # Ajouter l'accélération matérielle si elle n'est pas déjà présente
                if [[ ! "$exec_content" =~ AcceleratedVideoDecodeLinuxGL ]]; then
                    echo "[$(date)] Ajout de l'accélération matérielle dans: $line" >&2
                    
                    # Exception pour les lignes avec --file-forwarding et @@u
                    if [[ "$exec_content" =~ --file-forwarding.*org\.chromium\.Chromium.*@@u ]]; then
                        # Insérer l'accélération avant @@u
                        exec_content=$(echo "$exec_content" | sed 's|org\.chromium\.Chromium @@u|org.chromium.Chromium --enable-features=AcceleratedVideoDecodeLinuxGL @@u|')
                    else
                        # Ajouter à la fin pour les autres cas
                        exec_content="${exec_content} --enable-features=AcceleratedVideoDecodeLinuxGL"
                    fi
                fi
                
                # Remplacer par notre wrapper en passant la commande originale comme arguments
                echo "Exec=$WRAPPER_SCRIPT_PATH $exec_content" >> "$temp_file"
            else
                # Conserver les autres lignes Exec= non-Chromium telles quelles
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$SYSTEM_DESKTOP_FILE"
    
    # Vérifier que la modification a fonctionné
    if grep -q "$WRAPPER_SCRIPT_NAME" "$temp_file"; then
        mv "$temp_file" "$SYSTEM_DESKTOP_FILE"
        
        # Restaurer les permissions et propriétaire originaux
        chmod "$original_perms" "$SYSTEM_DESKTOP_FILE"
        chown "$original_owner" "$SYSTEM_DESKTOP_FILE"
        
        echo "Modification du fichier .desktop réussie"
        echo "Permissions restaurées: $original_perms ($original_owner)"
        echo "[$(date)] Accélération matérielle et wrapper ajoutés avec succès" >&2
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
    
    # Vérifier si déjà installé
    if is_already_modified; then
        echo "Le système est déjà installé et configuré."
        
        # Vérifier si les scripts sont présents
        if ! are_scripts_present; then
            echo "Les scripts sont manquants. Recréation en cours..."
            # Recréer les scripts
            if [[ ! -d "$SCRIPT_DIR" ]]; then
                echo "Création du répertoire $SCRIPT_DIR"
                mkdir -p "$SCRIPT_DIR"
            fi
            
            echo "Création du script de correction: $SCRIPT_PATH"
            create_wmclass_script
            
            echo "Création du script wrapper: $WRAPPER_SCRIPT_PATH"
            create_wrapper_script
            
            # Définir les permissions appropriées
            chmod 755 "$SCRIPT_PATH"
            chmod 755 "$WRAPPER_SCRIPT_PATH"
            chown root:root "$SCRIPT_PATH"
            chown root:root "$WRAPPER_SCRIPT_PATH"
            echo "Permissions définies pour les scripts: 755 root:root"
        fi
        
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
        echo "Assurez-vous que Chromium Flatpak est installé"
        exit 1
    fi
    
    # Afficher les lignes Exec= actuelles
    echo "Lignes Exec= trouvées dans le fichier .desktop:"
    grep "^Exec=" "$SYSTEM_DESKTOP_FILE" | nl
    echo ""
    
    # Afficher les permissions actuelles
    echo "Permissions actuelles du fichier .desktop: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
    
    # Étape 2: Sauvegarder le fichier original AVANT toute modification
    if ! backup_original_file; then
        echo "Abandon de l'installation en raison de l'échec de la sauvegarde"
        exit 1
    fi
    
    # Étape 3: Créer le répertoire du script si nécessaire
    if [[ ! -d "$SCRIPT_DIR" ]]; then
        echo "Création du répertoire $SCRIPT_DIR"
        mkdir -p "$SCRIPT_DIR"
    fi
    
    # Étape 4: Créer le script de correction WMClass
    echo "Création du script de correction: $SCRIPT_PATH"
    create_wmclass_script
    
    # Étape 5: Créer le script wrapper
    echo "Création du script wrapper: $WRAPPER_SCRIPT_PATH"
    create_wrapper_script
    
    # Définir les permissions appropriées
    chmod 755 "$SCRIPT_PATH"
    chmod 755 "$WRAPPER_SCRIPT_PATH"
    chown root:root "$SCRIPT_PATH"
    chown root:root "$WRAPPER_SCRIPT_PATH"
    echo "Permissions définies pour les scripts: 755 root:root"
    
    # Étape 6: Créer et activer le service systemd
    echo "Création du service systemd: $SYSTEMD_SERVICE_NAME"
    create_systemd_service
    enable_systemd_service
    
    # Étape 7: Modifier le fichier .desktop (ajoute accélération GPU + wrapper)
    if ! modify_desktop_file; then
        echo "Erreur lors de la modification du fichier .desktop"
        exit 1
    fi
    
    # Étape 8: Afficher les nouvelles lignes Exec=
    echo ""
    echo "Nouvelles lignes Exec= après modification:"
    grep "^Exec=" "$SYSTEM_DESKTOP_FILE" | nl
    
    # Étape 9: Mettre à jour la base de données des applications
    echo ""
    echo "Mise à jour de la base de données des applications"
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    
    echo "=============================================="
    echo "Installation terminée avec succès!"
    echo ""
    echo "Résumé:"
    echo "  Script de correction installé: $SCRIPT_PATH"
    echo "  Script wrapper installé: $WRAPPER_SCRIPT_PATH"
    echo "  Service systemd installé: $SYSTEMD_SERVICE_FILE"
    echo "  Fichier modifié: $SYSTEM_DESKTOP_FILE"
    echo "  Permissions conservées: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
    echo "  Sauvegarde créée avec timestamp"
    echo ""
    echo "Tous les contextes d'exécution Chromium ont été préservés et modifiés."
    echo "Le script sera automatiquement exécuté à chaque lancement de Chromium."
    echo "Le service systemd s'exécutera au démarrage du système."
}

# Fonction de désinstallation
uninstall_system() {
    echo "Désinstallation du système de persistance"
    echo "========================================="
    
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
    local backup_file=$(find "$(dirname "$SYSTEM_DESKTOP_FILE")" -name "org.chromium.Chromium_*.old" -type f | sort | tail -1)
    
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
        sed "s|^Exec=$WRAPPER_SCRIPT_PATH \(.*\)|Exec=\1|g" > "$temp_file"
        
        mv "$temp_file" "$SYSTEM_DESKTOP_FILE"
        echo "Modifications supprimées manuellement"
    fi
    
    # Supprimer les scripts
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        echo "Script de correction supprimé: $SCRIPT_PATH"
    fi
    
    if [[ -f "$WRAPPER_SCRIPT_PATH" ]]; then
        rm -f "$WRAPPER_SCRIPT_PATH"
        echo "Script wrapper supprimé: $WRAPPER_SCRIPT_PATH"
    fi

    
    # Supprimer les anciens raccourcis Chromium
    echo "Suppression des anciens raccourcis Chromium"
    rm -rf /var/lib/flatpak/exports/share/applications/org.chromium.Chromium_*


    # Mettre à jour la base de données
    update-desktop-database /var/lib/flatpak/exports/share/applications/ 2>/dev/null || true
    
    echo "Désinstallation terminée"
    echo "Permissions finales: $(stat -c "%a %U:%G" "$SYSTEM_DESKTOP_FILE")"
}

# Fonction de statut
show_status() {
    echo "Statut du système de persistance Chromium"
    echo "========================================"
    
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
        echo "Script de correction: INSTALLÉ ($SCRIPT_PATH)"
        echo "Permissions du script: $(stat -c "%a %U:%G" "$SCRIPT_PATH")"
    else
        echo "Script de correction: NON INSTALLÉ"
    fi
    
    if [[ -f "$WRAPPER_SCRIPT_PATH" ]]; then
        echo "Script wrapper: INSTALLÉ ($WRAPPER_SCRIPT_PATH)"
        echo "Permissions du wrapper: $(stat -c "%a %U:%G" "$WRAPPER_SCRIPT_PATH")"
    else
        echo "Script wrapper: NON INSTALLÉ"
    fi
    
    # Vérifier le service systemd
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        echo "Service systemd: INSTALLÉ ($SYSTEMD_SERVICE_FILE)"
        systemctl is-active --quiet "$SYSTEMD_SERVICE_NAME" && echo "Service systemd: ACTIF" || echo "Service systemd: INACTIF"
        systemctl is-enabled --quiet "$SYSTEMD_SERVICE_NAME" && echo "Service systemd: ACTIVÉ AU DÉMARRAGE" || echo "Service systemd: DÉSACTIVÉ AU DÉMARRAGE"
    else
        echo "Service systemd: NON INSTALLÉ"
    fi
    
    # Compter les sauvegardes
    local backup_count=$(find "$(dirname "$SYSTEM_DESKTOP_FILE")" -name "org.chromium.Chromium_*.old" -type f 2>/dev/null | wc -l)
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
        echo "  install   - Installe le système de persistance (par défaut)"
        echo "  uninstall - Désinstalle et restaure les fichiers originaux"
        echo "  status    - Affiche l'état actuel du système"
        exit 1
        ;;
esac