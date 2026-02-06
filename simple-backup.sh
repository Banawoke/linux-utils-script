#!/bin/bash

set -euo pipefail

# Vérification des privilèges root
if [[ $EUID -ne 0 ]]; then
   echo "Ce script doit être exécuté en tant que root (sudo)"
   exit 1
fi

# Configuration
BACKUP_DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_DIR="/mnt/backup"
BACKUP_FILE="${BACKUP_DIR}/system-backup-${BACKUP_DATE}.tar.gz"

# Dossiers à exclure
EXCLUDE_DIRS=(
    "/mnt/data/Telechargements"
    "/mnt/remote-backup"
    "/mnt/media"
    "/bin"
    "/boot"
    "/dev"
    "/etc"
    "/initrd.img"
    "/initrd.img.old"
    "/lib"
    "/lib64"
    "/media"
    "/proc"
    "/root"
    "/run"
    "/sbin"
    "/srv"
    "/sys"
    "/tmp"
    "/usr"
    "/var"
    "/vmlinuz"
    "/vmlinuz.old"
    "/snap"
    "/mnt/backup"
)

# Fonction principale
main() {
    echo "=== Démarrage de la sauvegarde système ==="
    echo "Date: ${BACKUP_DATE}"
    
    # Vérifier/créer le dossier de destination
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        echo "Le dossier ${BACKUP_DIR} n'existe pas"
        read -p "Voulez-vous le créer? (o/N): " create_dir
        if [[ "${create_dir}" =~ ^[oO]$ ]]; then
            mkdir -p "${BACKUP_DIR}"
            echo "Dossier ${BACKUP_DIR} créé"
        else
            echo "Impossible de continuer sans dossier de destination"
            exit 1
        fi
    fi
    
    # Vérifier l'espace disque disponible
    echo "Vérification de l'espace disque..."
    AVAILABLE_SPACE=$(df -BG "${BACKUP_DIR}" | awk 'NR==2 {print $4}' | sed 's/G//')
    echo "Espace disponible dans ${BACKUP_DIR}: ${AVAILABLE_SPACE}G"
    
    if [[ ${AVAILABLE_SPACE} -lt 10 ]]; then
        echo "Espace disque faible (< 10G)"
        read -p "Continuer quand même? (o/N): " continue_backup
        if [[ ! "${continue_backup}" =~ ^[oO]$ ]]; then
            echo "Sauvegarde annulée"
            exit 0
        fi
    fi
    
    # Construire les exclusions pour tar
    EXCLUDE_OPTS=()
    for dir in "${EXCLUDE_DIRS[@]}"; do
        EXCLUDE_OPTS+=(--exclude="${dir}")
    done
    
    # Afficher les exclusions
    echo "Dossiers exclus de la sauvegarde:"
    for dir in "${EXCLUDE_DIRS[@]}"; do
        echo "  - ${dir}"
    done
    
    # Sauvegarde des paquets
    echo "Sauvegarde des listes de paquets et d'applications..."
    if command -v apt-mark &> /dev/null; then
        apt-mark showmanual > "/opt/apt-list.txt"
    fi
    if command -v flatpak &> /dev/null; then
        flatpak list --columns=application --app > "/opt/flatpak-list.txt"
    fi

    if [ -d "/etc/apt/sources.list.d" ]; then
        cat /etc/apt/sources.list.d/* > "/opt/repo-fallback.txt"
    fi


    
    # Créer l'archive
    echo "Création de l'archive en cours..."
    echo "Cela peut prendre beaucoup de temps selon la taille de vos données..."
    
    if tar -czpvf "${BACKUP_FILE}" \
        "${EXCLUDE_OPTS[@]}" \
        --exclude="${BACKUP_FILE}" \
        --ignore-failed-read \
        / 2>&1 | tee /tmp/backup-${BACKUP_DATE}.log; then
        
        echo "Archive créée avec succès!"
    else
        echo "Erreur lors de la création de l'archive"
        exit 1
    fi
    
    # Afficher les informations sur l'archive
    BACKUP_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    echo "=== Sauvegarde terminée ==="
    echo "Fichier: ${BACKUP_FILE}"
    echo "Taille: ${BACKUP_SIZE}"
    echo "Log: /tmp/backup-${BACKUP_DATE}.log"
    
    # Vérifier l'intégrité de l'archive
    read -p "Voulez-vous vérifier l'intégrité de l'archive? (o/N): " verify
    if [[ "${verify}" =~ ^[oO]$ ]]; then
        echo "Vérification de l'archive..."
        if tar -tzf "${BACKUP_FILE}" > /dev/null 2>&1; then
            echo "Archive valide!"
        else
            echo "L'archive semble corrompue!"
            exit 1
        fi
    fi
    
    echo "Sauvegarde complète!"
}

# Exécution
main
