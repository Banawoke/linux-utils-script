#!/bin/bash

# Configuration
SERVEUR_REBOND="alebout@serveurderebond.fr"
CLE_SSH="~/.ssh/id_ed25519"

# Vérifier si l'option -v est passée
VERBOSE=""
if [[ "$1" == "-v" ]]; then
    VERBOSE="-v"
fi

# Demander le serveur de destination
read -p "Entrez l'adresse du serveur de destination : " SERVEUR_DESTINATION

# Connexion SSH
ssh -A -i "$CLE_SSH" -J "$SERVEUR_REBOND" $VERBOSE "$SERVEUR_DESTINATION"