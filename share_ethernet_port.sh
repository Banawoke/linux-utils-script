#!/bin/bash

# Script de partage de connexion Ethernet avec dnsmasq
set -euo pipefail

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/tmp/ethernet_sharing.log"
CONNECTIONS_LOG="/tmp/ethernet_connections.log"
DNSMASQ_CONFIG_FILE="/tmp/dnsmasq_shared_$$.conf"

# Configuration réseau par défaut
SHARED_INTERFACE=""
INET_INTERFACE=""
SHARED_IP="192.168.100.1"
SHARED_NETWORK="192.168.100.0/24"
SUBNET_MASK="24"
DHCP_RANGE_START="192.168.100.10"
DHCP_RANGE_END="192.168.100.50"
DNS_SERVERS=""  # Sera automatiquement détecté

# Variables de suivi
CLEANUP_DONE=false
TSHARK_PID=""  # PID du processus tshark

# Fonction de logging avec timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Fonction de logging des connexions
log_connection() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CONNECTIONS_LOG"
}

# Fonction pour vérifier et installer tshark si nécessaire
check_and_install_tshark() {
        if ! command -v tshark &> /dev/null; then
            log "ERREUR: Échec de l'installation de tshark"
            exit 1
        fi
        log "tshark installé"

}

# Fonction pour démarrer la capture tshark
start_tshark_capture() {
    local capture_file="/tmp/ethernet_capture_$$.pcap"
    log "Démarrage de la capture tshark sur $SHARED_INTERFACE..."
    log "Fichier de capture: $capture_file"
    
    # Lancer tshark en arrière-plan avec filtrage pour réduire le bruit
    # Filtre pour DHCP, DNS, et trafic ICMP/ARP de base
    tshark -i "$SHARED_INTERFACE" -w "$capture_file" -b filesize:1024 -b files:5 \
           -f "port 67 or port 68 or port 53 or arp or icmp" \
           -l -Q 2>/dev/null &
    TSHARK_PID=$!
    
    sleep 2
    if kill -0 $TSHARK_PID 2>/dev/null; then
        log "Capture tshark démarrée (PID: $TSHARK_PID)"
        log_connection "CAPTURE TSHARK DÉMARRÉE: Interface=$SHARED_INTERFACE, PID=$TSHARK_PID"
    else
        log "ERREUR: Échec du démarrage de tshark"
        TSHARK_PID=""
    fi
}

# Fonction pour arrêter la capture tshark
stop_tshark_capture() {
    if [[ -n "$TSHARK_PID" ]]; then
        log "Arrêt de la capture tshark (PID: $TSHARK_PID)..."
        kill $TSHARK_PID 2>/dev/null || true
        wait $TSHARK_PID 2>/dev/null || true
        log_connection "CAPTURE TSHARK ARRÊTÉE: PID=$TSHARK_PID"
        TSHARK_PID=""
    fi
}

# Fonction d'affichage de l'aide
show_help() {
    cat << EOF
$SCRIPT_NAME - Script de partage de connexion Ethernet avec dnsmasq et capture Wireshark

USAGE:
    $SCRIPT_NAME -e INTERFACE_ETHERNET [OPTIONS]

OPTIONS PRINCIPALES:
    -e, --ethernet INTERFACE    Interface Ethernet à partager (obligatoire)
    -i, --inet INTERFACE        Interface avec Internet (auto-détection si non spécifié)

OPTIONS RÉSEAU:
    --network NETWORK           Réseau à utiliser (ex: 192.168.1.0/24)
    --router-ip IP              IP du routeur/passerelle (ex: 192.168.1.1)
    --dhcp-range START-END      Plage DHCP (ex: 192.168.1.10-192.168.1.50)
    --subnet-mask CIDR          Masque de sous-réseau en CIDR (défaut: 24)

OPTIONS AUTRES:
    -d, --dns SERVERS           Serveurs DNS (auto-détection si non spécifié)
    --no-capture                Désactiver la capture Wireshark/tshark
    -h, --help                  Affiche cette aide

EXEMPLES:
    # Configuration de base avec capture
    $SCRIPT_NAME -e enp0s25

    # Sans capture Wireshark
    $SCRIPT_NAME -e eth0 --no-capture

    # Avec réseau personnalisé
    $SCRIPT_NAME -e eth0 --network 10.0.0.0/24 --router-ip 10.0.0.1 --dhcp-range 10.0.0.100-10.0.0.200

Configuration par défaut: 192.168.100.0/24 (routeur: 192.168.100.1)
Le script fonctionne en mode daemon - utilisez Ctrl+C pour arrêter proprement.
EOF
}

# Vérification des privilèges root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERREUR: Ce script doit être exécuté en tant que root"
        exit 1
    fi
}

# Validation du format IP
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validation du réseau CIDR
validate_network() {
    local network=$1
    if [[ $network =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip=${network%/*}
        local cidr=${network#*/}
        if validate_ip "$ip" && [[ $cidr -ge 8 && $cidr -le 30 ]]; then
            return 0
        fi
    fi
    return 1
}

# Calcul de l'IP du routeur à partir du réseau
calculate_router_ip() {
    local network=$1
    local base_ip=${network%/*}
    IFS='.' read -ra IP_PARTS <<< "$base_ip"
    IP_PARTS[3]=$((IP_PARTS[3] + 1))
    echo "${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.${IP_PARTS[3]}"
}

# Calcul de la plage DHCP par défaut
calculate_dhcp_range() {
    local network=$1
    local base_ip=${network%/*}
    local cidr=${network#*/}
    IFS='.' read -ra IP_PARTS <<< "$base_ip"
    
    # Calculer la plage utilisable selon le CIDR
    local host_bits=$((32 - cidr))
    local max_hosts=$(( (2 ** host_bits) - 2 ))
    
    # Commencer à .10 et prendre 40 adresses ou la moitié des adresses disponibles
    local start_offset=10
    local range_size=40
    
    if [[ $max_hosts -lt 50 ]]; then
        range_size=$((max_hosts / 2))
        if [[ $range_size -lt 5 ]]; then
            range_size=5
        fi
    fi
    
    IP_PARTS[3]=$((IP_PARTS[3] + start_offset))
    local start_ip="${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.${IP_PARTS[3]}"
    
    IP_PARTS[3]=$((IP_PARTS[3] + range_size - 1))
    local end_ip="${IP_PARTS[0]}.${IP_PARTS[1]}.${IP_PARTS[2]}.${IP_PARTS[3]}"
    
    echo "$start_ip-$end_ip"
}

# Auto-détection de l'interface avec Internet
detect_internet_interface() {
    local interface
    interface=$(ip route show default | grep -oP 'dev \K\w+' | head -1)
    if [[ -n "$interface" ]]; then
        echo "$interface"
    else
        echo "ERREUR: Impossible de détecter l'interface Internet"
        exit 1
    fi
}

# Détection automatique des serveurs DNS
detect_dns_servers() {
    local dns_servers=""
    
    if command -v resolvectl &> /dev/null; then
        local ipv4_dns
        ipv4_dns=$(resolvectl status 2>/dev/null | grep -E "Current DNS Server:|DNS Servers:" | \
                   grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
                   grep -v "127.0.0.53" | \
                   sort -u | tr '\n' ',' | sed 's/,$//')
        
        if [[ -n "$ipv4_dns" ]]; then
            dns_servers="$ipv4_dns"
        fi
    fi
    
    if [[ -z "$dns_servers" ]]; then
        dns_servers="8.8.8.8,8.8.4.4"
    fi
    
    echo "$dns_servers"
}

# Validation de l'interface Ethernet
validate_ethernet_interface() {
    local interface=$1
    if ! ip link show "$interface" &> /dev/null; then
        echo "ERREUR: Interface Ethernet '$interface' introuvable"
        echo "Interfaces disponibles:"
        ip link show | grep -E "^[0-9]+:" | cut -d: -f2 | tr -d ' '
        exit 1
    fi
}

# Affichage des connexions actives
show_connections() {
    local lease_file="/tmp/dnsmasq-sharing.leases"
    
    
    if [[ -f "$lease_file" ]]; then
        while read -r expiry mac ip name; do
            local exp_date
            if [[ "$expiry" != "0" ]]; then
                exp_date=$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Invalide")
            else
                exp_date="Permanent"
            fi
            printf "%-18s | %-17s | %-15s | %s\n" "$exp_date" "$mac" "$ip" "${name:-<inconnu>}"
        done < "$lease_file"
    else
        echo "Aucun fichier de baux DHCP trouvé."
    fi
    
    echo

    arp -a | grep -E "$(echo $SHARED_NETWORK | cut -d'/' -f1 | sed 's/\.[0-9]*$//')" 2>/dev/null || echo "Aucune entrée ARP trouvée"
}

# Configuration de dnsmasq (avec logs détaillés)
configure_dnsmasq() {
    log "Configuration de dnsmasq..."
    
    if [[ -z "$DNS_SERVERS" ]]; then
        DNS_SERVERS=$(detect_dns_servers)
        log "Serveurs DNS détectés automatiquement: $DNS_SERVERS"
    else
        log "Serveurs DNS spécifiés manuellement: $DNS_SERVERS"
    fi
    
    cat > "$DNSMASQ_CONFIG_FILE" << EOF   
interface=$SHARED_INTERFACE
bind-interfaces
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,12h
dhcp-option=3,$SHARED_IP
dhcp-option=6,$DNS_SERVERS
domain=local
local=/local/
log-queries
log-dhcp
log-facility=/var/log/dnsmasq-sharing.log
dhcp-leasefile=/tmp/dnsmasq-sharing.leases
dhcp-script=/usr/local/bin/dhcp-event-logger.sh
no-hosts
EOF

}

# Configuration de l'interface Ethernet
configure_ethernet_interface() {
    log "Configuration de l'interface Ethernet $SHARED_INTERFACE..."
    log "Réseau: $SHARED_NETWORK, IP du routeur: $SHARED_IP"
    
    nmcli device set "$SHARED_INTERFACE" managed no 2>/dev/null || true
    ip addr flush dev "$SHARED_INTERFACE" 2>/dev/null || true
    ip addr add "$SHARED_IP/$SUBNET_MASK" dev "$SHARED_INTERFACE"
    ip link set "$SHARED_INTERFACE" up
    
    log "Interface $SHARED_INTERFACE configurée avec succès"
}

# Configuration du routage et NAT
configure_routing() {
    log "Configuration du routage et NAT..."
    
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    iptables -t nat -D POSTROUTING -o "$INET_INTERFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$INET_INTERFACE" -o "$SHARED_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$SHARED_INTERFACE" -o "$INET_INTERFACE" -j ACCEPT 2>/dev/null || true
    
    iptables -t nat -A POSTROUTING -o "$INET_INTERFACE" -j MASQUERADE
    iptables -A FORWARD -i "$INET_INTERFACE" -o "$SHARED_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$SHARED_INTERFACE" -o "$INET_INTERFACE" -j ACCEPT
    
    log "Routage configuré entre $SHARED_INTERFACE ($SHARED_NETWORK) et $INET_INTERFACE"
}

# Démarrage de dnsmasq
start_dnsmasq() {
    log "Démarrage de dnsmasq..."
    
    pkill dnsmasq 2>/dev/null || true
    sleep 1
    
    dnsmasq --conf-file="$DNSMASQ_CONFIG_FILE"
    sleep 2
    
    if pgrep -f "dnsmasq.*$(basename "$DNSMASQ_CONFIG_FILE")" > /dev/null; then
        log "dnsmasq démarré avec succès sur interface $SHARED_INTERFACE"
        log "DHCP: $DHCP_RANGE_START - $DHCP_RANGE_END"
        log_connection "SERVICE DÉMARRÉ: Réseau=$SHARED_NETWORK, DHCP=$DHCP_RANGE_START-$DHCP_RANGE_END"
    else
        log "ERREUR: Échec du démarrage de dnsmasq"
        exit 1
    fi
}

# Nettoyage
cleanup_configuration() {
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return
    fi
    
    log "Nettoyage en cours..."
    log_connection "SERVICE ARRÊTÉ: Réseau=$SHARED_NETWORK"
    
    stop_tshark_capture
    
    pkill dnsmasq 2>/dev/null || true
    
    iptables -t nat -D POSTROUTING -o "$INET_INTERFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$INET_INTERFACE" -o "$SHARED_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$SHARED_INTERFACE" -o "$INET_INTERFACE" -j ACCEPT 2>/dev/null || true
    
    nmcli device set "$SHARED_INTERFACE" managed yes 2>/dev/null || true
    ip addr flush dev "$SHARED_INTERFACE" 2>/dev/null || true
    
    [[ -f "$DNSMASQ_CONFIG_FILE" ]] && rm -f "$DNSMASQ_CONFIG_FILE"
    
    CLEANUP_DONE=true
    log "Nettoyage terminé"
}

# Signal handler
signal_handler() {
    log "Arrêt demandé..."
    
    # Tuer les processus tail et monitoring
    pkill -P $$ tail 2>/dev/null || true
    pkill -P $$ sleep 2>/dev/null || true
    
    cleanup_configuration
    log "Partage de connexion arrêté"
    exit 0
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--ethernet) 
                SHARED_INTERFACE="$2"; shift 2 ;;
            -i|--inet) 
                INET_INTERFACE="$2"; shift 2 ;;
            --network)
                if validate_network "$2"; then
                    SHARED_NETWORK="$2"
                    SUBNET_MASK="${2#*/}"
                    # Recalculer l'IP du routeur et la plage DHCP
                    SHARED_IP=$(calculate_router_ip "$2")
                    local dhcp_range=$(calculate_dhcp_range "$2")
                    DHCP_RANGE_START="${dhcp_range%-*}"
                    DHCP_RANGE_END="${dhcp_range#*-}"
                else
                    echo "ERREUR: Format de réseau invalide: $2"
                    exit 1
                fi
                shift 2 ;;
            --router-ip)
                if validate_ip "$2"; then
                    SHARED_IP="$2"
                else
                    echo "ERREUR: IP de routeur invalide: $2"
                    exit 1
                fi
                shift 2 ;;
            --dhcp-range)
                IFS='-' read -r DHCP_RANGE_START DHCP_RANGE_END <<< "$2"
                if ! validate_ip "$DHCP_RANGE_START" || ! validate_ip "$DHCP_RANGE_END"; then
                    echo "ERREUR: Plage DHCP invalide: $2"
                    exit 1
                fi
                shift 2 ;;
            --subnet-mask)
                if [[ "$2" =~ ^[0-9]{1,2}$ ]] && [[ $2 -ge 8 && $2 -le 30 ]]; then
                    SUBNET_MASK="$2"
                else
                    echo "ERREUR: Masque de sous-réseau invalide: $2 (doit être entre 8 et 30)"
                    exit 1
                fi
                shift 2 ;;
            -d|--dns) 
                DNS_SERVERS="$2"; shift 2 ;;
            -h|--help) 
                show_help; exit 0 ;;
            *) 
                echo "ERREUR: Option inconnue: $1"; show_help; exit 1 ;;
        esac
    done
}

# Surveillance des connexions avec tail
monitor_connections() {
    local lease_file="/tmp/dnsmasq-sharing.leases"
    
    # Affichage initial des connexions
    show_connections
    
    echo
    echo "=== SURVEILLANCE EN TEMPS RÉEL ==="
    echo "Logs système: $LOG_FILE"
    echo "Logs connexions: $CONNECTIONS_LOG"
    echo "Appuyez sur Ctrl+C pour arrêter"
    echo
    
    # Lancement du monitoring en arrière-plan
    (
        while true; do
            sleep 30
            # Vérifier que dnsmasq fonctionne
            if ! pgrep -f "dnsmasq.*$(basename "$DNSMASQ_CONFIG_FILE")" > /dev/null; then
                log "Redémarrage de dnsmasq..."
                start_dnsmasq
            fi
        done
    ) &
    local monitor_pid=$!
    
    # Suivre les logs en temps réel
    echo "=== LOGS EN TEMPS RÉEL ==="
    tail -f "$CONNECTIONS_LOG" "$LOG_FILE" "/var/log/dnsmasq-sharing.log" &
    
    local tail_pid=$!
    
    # Démarrer la surveillance Wireshark si activée
    if [[ "${NO_CAPTURE:-false}" != "true" ]]; then
        monitor_wireshark_captures &
        local wireshark_pid=$!
    fi
    
    # Attendre l'interruption
    trap "kill $monitor_pid $tail_pid ${wireshark_pid:-} 2>/dev/null; signal_handler" INT TERM
    wait
}

# Main
main() {
    parse_arguments "$@"
    check_root
    
    if [[ -z "$SHARED_INTERFACE" ]]; then
        echo "ERREUR: Interface Ethernet non spécifiée (-e|--ethernet)"
        show_help
        exit 1
    fi
    
    if [[ -z "$INET_INTERFACE" ]]; then
        INET_INTERFACE=$(detect_internet_interface)
        log "Interface Internet détectée automatiquement: $INET_INTERFACE"
    fi
    
    validate_ethernet_interface "$SHARED_INTERFACE"
    
    # Vérifier et installer tshark si la capture est activée
    if [[ "${NO_CAPTURE:-false}" != "true" ]]; then
        check_and_install_tshark
    fi
    
    trap signal_handler INT TERM
    
    log "=== CONFIGURATION DU PARTAGE ==="
    log "Interface partagée: $SHARED_INTERFACE"
    log "Interface Internet: $INET_INTERFACE"
    log "Réseau: $SHARED_NETWORK"
    log "IP du routeur: $SHARED_IP"
    log "Plage DHCP: $DHCP_RANGE_START - $DHCP_RANGE_END"
    log "Masque: /$SUBNET_MASK"
    if [[ "${NO_CAPTURE:-false}" != "true" ]]; then
        log "Capture Wireshark/tshark: ACTIVÉE"
    else
        log "Capture Wireshark/tshark: DÉSACTIVÉE"
    fi
    
    configure_dnsmasq
    configure_ethernet_interface
    configure_routing
    start_dnsmasq
    
    # Démarrer la capture si activée
    if [[ "${NO_CAPTURE:-false}" != "true" ]]; then
        start_tshark_capture
    fi
    
    log "Partage de connexion actif. Ctrl+C pour arrêter."
    log "Logs de connexions: $CONNECTIONS_LOG"
    
    monitor_connections
}

main "$@"