#!/bin/bash
# Activation du mode debug (par défaut à false)
DEBUG=false
search_dir="/home"
# Fonction d'aide
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --help     Affiche cette aide"
    echo "  -u, --unmount  Démonte tous les points de montage"
    echo "  -d, --debug    Active le mode debug"
    echo "Sans option, le script monte les répertoires home distants"
}
# Fonction de debug
debug() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1"
    fi
}
# Fonction pour vérifier si c'est l'hôte local
is_local_host() {
    local ip=$1
    local hostname=$2
    
    # Obtenir l'IP locale et le hostname local
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_hostname=$(hostname)
    
    debug "Vérification hôte local: IP=$ip, hostname=$hostname vs local_ip=$local_ip, local_hostname=$local_hostname"
    
    # Vérifier si c'est localhost, l'IP locale ou le hostname local
    if [[ "$ip" == "127.0.0.1" ]] || \
       [[ "$ip" == "localhost" ]] || \
       [[ "$ip" == "$local_ip" ]] || \
       [[ "$hostname" == "$local_hostname" ]]; then
        debug "Hôte local détecté, ignoré"
        return 0  # C'est l'hôte local
    fi
    
    return 1  # Ce n'est pas l'hôte local
}

# Fonction pour parser le fichier inventory.yaml
parse_hosts() {
    local inventory_file="$1"
    debug "Analyse du fichier inventory: $inventory_file"
    
    if [ ! -f "$inventory_file" ]; then
        echo "ERREUR: Fichier inventory non trouvé: $inventory_file"
        return 1
    fi
    
    # Vérifier si yq est installé
    if ! command -v yq &> /dev/null; then
        sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq;
        sudo chmod +x /usr/bin/yq
    fi
    
    # Utiliser yq pour extraire les hôtes et leurs IPs
    yq eval '.all.children.*.hosts[] | select(.ansible_host != null) | key + " " + .ansible_host' "$inventory_file"
}

locate_inventory_file() {
    find "$search_dir" -maxdepth 6 -type f -iname "*inventory*.yaml" -print -quit
}
# Fonction pour créer le point de montage et monter le /home distant
mount_remote_home() {
    local host=$1
    local ip=$2
    
    debug "Tentative de montage pour $host ($ip)"
    
    # Vérifier si c'est l'hôte local et l'ignorer
    if is_local_host "$ip" "$host"; then
        echo "Ignoré (hôte local): $host ($ip)"
        return 0
    fi
    
    # Crée le répertoire de montage s'il n'existe pas
    if [ ! -d "$HOME/remote_homes/$host" ]; then
        debug "Création du répertoire $HOME/remote_homes/$host"
        mkdir -p "$HOME/remote_homes/$host"
    fi
    
    # Vérifie si le montage existe déjà
    if mountpoint -q "$HOME/remote_homes/$host"; then
        debug "Point de montage déjà existant pour $host"
        echo "Déjà monté: $host"
        return 0
    fi
    
    # Monte le /home distant
    debug "Exécution de sshfs pour $host"
    timeout 5 sshfs "$ip":/home "$HOME/remote_homes/$host"
local mount_status=$?
    
    if [ $mount_status -eq 0 ]; then
        echo "Monté avec succès: $host ($ip)"
    else
        echo "Erreur de montage: $host ($ip)"
        debug "Code d'erreur sshfs: $mount_status"
        rmdir "$HOME/remote_homes/$host"
    fi
}
# Fonction pour démonter tous les points de montage
unmount_all() {
    debug "Démontage de tous les points de montage"
    if [ -d "$HOME/remote_homes" ]; then
        sudo umount -f -l $HOME/remote_homes/* 2>/dev/null
        echo "Tous les points de montage ont été démontés"
        rm -rf "$HOME/remote_homes"
    else
        echo "Aucun répertoire remote_homes trouvé"
    fi
}
# Traitement des arguments en ligne de commande
main() {
    local PERFORM_MOUNT=true
    # Traitement des options
    while [ "$1" != "" ]; do
        case $1 in
            -u | --unmount )    
                PERFORM_MOUNT=false
                unmount_all
                exit 0
                ;;
            -d | --debug )      
                DEBUG=true
                ;;
            -h | --help )       
                PERFORM_MOUNT=false
                show_help
                exit 0
                ;;
            * )                 
                PERFORM_MOUNT=false
                show_help
                exit 1
                ;;
        esac
        shift
    done
    # Si PERFORM_MOUNT est toujours true, exécuter le montage
    if [ "$PERFORM_MOUNT" = true ]; then
        # Vérifie les dépendances
        debug "Vérification des dépendances"
        if ! command -v sshfs &> /dev/null; then
            echo "sshfs n'est pas installé. Installation..."
            sudo apt-get update && sudo apt-get install -y sshfs
        fi
        # Crée le répertoire principal pour les montages
        debug "Création du répertoire principal remote_homes"
        mkdir -p "$HOME/remote_homes"
        # Recherche du fichier inventory
        local inventory_file
        inventory_file=$(locate_inventory_file)
        if [[ -z "$inventory_file" ]]; then
            echo "ERREUR: Fichier inventory non trouvé dans $SCRIPT_DIR"
            exit 1
        fi

        # Parse le fichier inventory et monte chaque /home
        debug "Démarrage du parsing et montage"
        while read -r host ip; do
            debug "Traitement de l'entrée: host=$host, ip=$ip"
            if [[ -n "$host" && -n "$ip" ]]; then
                mount_remote_home "$host" "$ip"
            fi
        done < <(parse_hosts "$inventory_file")
        echo "Terminé!"
    fi
}
# Exécution du script
main "$@"