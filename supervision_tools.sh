#!/bin/bash

# Fichier de log avec la date du jour
LOG_FILE="log-sup-$(date +%Y-%m-%d).txt"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Pas de couleur

# Fonction pour afficher à l'écran ET journaliser dans le fichier sans les codes de couleur
log_echo() {
    # Affichage à l'écran avec interprétation des couleurs et sauts de ligne
    echo -e "$1"
    # Écriture dans le fichier en retirant les codes de couleur ANSI (\x1b[...m)
    echo -e "$1" | sed -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

log_echo "${BLUE}=== Début de la session de supervision : $(date) ===${NC}"
log_echo "Les logs sont enregistrés dans le fichier : $LOG_FILE\n"

# Fonction pour tester ICMP (ping)
test_icmp() {
    ping -c 1 -W 1 "$1" >/dev/null 2>&1
    return $?
}

# Fonction pour tester un port avec NC (ici on teste SSH par défaut)
test_nc_ssh() {
    nc -z -w 1 "$1" "$2" >/dev/null 2>&1
    return $?
}

# Fonction pour tester Web (HTTP/HTTPS) avec cURL
test_curl() {
    curl -Is -m 1 "http://$1" >/dev/null 2>&1 || curl -Is -m 1 "https://$1" >/dev/null 2>&1
    return $?
}

# Fonction pour analyser les arguments et extraire les commentaires (entre parenthèses)
HOSTS=()
declare -A HOST_COMMENTS

parse_hosts() {
    # On itère sur tous les arguments fournis
    for arg in "$@"; do
        # Si l'argument commence par '(' et finit par ')'
        if [[ "$arg" =~ ^\((.*)\)$ ]]; then
            # On récupère le commentaire sans les parenthèses
            local comment="${BASH_REMATCH[1]}"
            local last_idx=$(( ${#HOSTS[@]} - 1 ))
            
            # S'il y a un hôte précédent, on lui associe le commentaire
            if [ $last_idx -ge 0 ]; then
                local last_host="${HOSTS[$last_idx]}"
                HOST_COMMENTS["$last_host"]="$comment"
            fi
        else
            # Ce n'est pas un commentaire, c'est donc un hôte
            HOSTS+=("$arg")
        fi
    done
}

# 1. Obtenir la liste d'hôtes (soit par arguments, soit interactivement)
if [ $# -eq 0 ]; then
    log_echo "${BLUE}Aucun hôte fourni en argument.${NC}"
    log_echo "Exemple de saisie : ${YELLOW}serveur1 (prod) serveur2 (dev)${NC}"
    read -p "Veuillez entrer les hôtes à tester : " -a input_args
    # Loguer la saisie
    echo "Hôtes saisis manuellement : ${input_args[*]}" >> "$LOG_FILE"
    parse_hosts "${input_args[@]}"
else
    echo "Hôtes fournis en arguments : $*" >> "$LOG_FILE"
    parse_hosts "$@"
fi

# Vérifier si la liste est vide après demande
if [ ${#HOSTS[@]} -eq 0 ]; then
    log_echo "${RED}Erreur : Aucun hôte renseigné. Fin du script.${NC}"
    exit 1
fi

log_echo "\n${BLUE}=== Étape 1 : Test de connectivité initiale ===${NC}"
log_echo "Test de tous les hôtes pour voir ceux qui répondent..."

# Tableaux associatifs pour garder les hôtes et les services actifs
declare -A ACTIVE_HOSTS
declare -A ACTIVE_ICMP
declare -A ACTIVE_SSH
declare -A ACTIVE_WEB

for host in "${HOSTS[@]}"; do
    
    # Affichage personnalisé si un commentaire existe
    disp_host="$host"
    if [ -n "${HOST_COMMENTS["$host"]}" ]; then
        disp_host="$host ${CYAN}(${HOST_COMMENTS["$host"]})${NC}"
    fi

    log_echo "\nTest initial pour : ${YELLOW}$disp_host${NC}"
    
    is_active=false
    
    # Test ICMP
    if test_icmp "$host"; then
        log_echo "  [${GREEN}OK${NC}] ICMP (Ping)"
        ACTIVE_ICMP["$host"]=true
        is_active=true
    else
        log_echo "  [${RED}KO${NC}] ICMP (Ping)"
    fi
    
    # Test SSH (via nc)
    if test_nc_ssh "$host" 22; then
        log_echo "  [${GREEN}OK${NC}] SSH (Port 22 via nc)"
        ACTIVE_SSH["$host"]=true
        is_active=true
    else
        log_echo "  [${RED}KO${NC}] SSH (Port 22 via nc)"
    fi
    
    # Test cURL
    if test_curl "$host"; then
        log_echo "  [${GREEN}OK${NC}] Web (HTTP/HTTPS via curl)"
        ACTIVE_WEB["$host"]=true
        is_active=true
    else
        log_echo "  [${RED}KO${NC}] Web (HTTP/HTTPS via curl)"
    fi
    
    # Conserver l'hôte s'il répond à au moins un test
    if [ "$is_active" = true ]; then
        ACTIVE_HOSTS["$host"]=true
    else
        log_echo "  => ${RED}L'hôte $disp_host ne répond à aucun test. Il est retiré de la supervision.${NC}"
    fi
done

# Vérifier s'il reste des hôtes actifs
if [ ${#ACTIVE_HOSTS[@]} -eq 0 ]; then
    log_echo "\n${RED}Aucun hôte n'a répondu. Fin du script.${NC}"
    exit 0
fi

log_echo "\n${BLUE}=== Étape 2 : Supervision en mode interactif ===${NC}"
log_echo "Hôtes conservés pour la boucle : ${YELLOW}${!ACTIVE_HOSTS[*]}${NC}"

# Boucle interactive
while true; do
    echo -ne "\nAppuyez sur ${GREEN}[Entrée]${NC} pour relancer ou tapez un ${CYAN}commentaire${NC} à journaliser puis Entrée (Ctrl+C pour quitter) : "
    read -r user_comment
    
    # Si l'utilisateur a tapé quelque chose, on l'ajoute au fichier de log
    if [ -n "$user_comment" ]; then
        # On ne passe pas par log_echo car on ne veut pas l'afficher à l'écran juste après que l'utilisateur l'ait tapé, 
        # on veut juste le stocker en silence
        echo "[OBSERVATION - $(date '+%H:%M:%S')] : $user_comment" >> "$LOG_FILE"
    fi
    
    # Nettoyer l'écran uniquement pour l'affichage, pas d'impact sur le log
    clear
    log_echo "${BLUE}=== Résultats de la supervision ($(date '+%H:%M:%S')) ===${NC}"
    
    for host in "${!ACTIVE_HOSTS[@]}"; do
        
        # Affichage personnalisé si un commentaire existe
        disp_host="$host"
        if [ -n "${HOST_COMMENTS["$host"]}" ]; then
            disp_host="$host ${CYAN}(${HOST_COMMENTS["$host"]})${NC}"
        fi

        log_echo "\n${YELLOW}Hôte : $disp_host${NC}"
        
        if [ "${ACTIVE_ICMP["$host"]}" = true ]; then
            if test_icmp "$host"; then
                log_echo "  [${GREEN}OK${NC}] ICMP (Ping)"
            else
                log_echo "  [${RED}KO${NC}] ICMP (Ping)"
            fi
        fi
        
        if [ "${ACTIVE_SSH["$host"]}" = true ]; then
            if test_nc_ssh "$host" 22; then
                log_echo "  [${GREEN}OK${NC}] SSH (nc port 22)"
            else
                log_echo "  [${RED}KO${NC}] SSH (nc port 22)"
            fi
        fi
        
        if [ "${ACTIVE_WEB["$host"]}" = true ]; then
            if test_curl "$host"; then
                log_echo "  [${GREEN}OK${NC}] Web (curl HTTP/HTTPS)"
            else
                log_echo "  [${RED}KO${NC}] Web (curl HTTP/HTTPS)"
            fi
        fi
    done
done
