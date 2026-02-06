#!/bin/bash

# Restauration depuis archive tar.gz
echo "Restauration depuis archive tar.gz"
echo "Recherche d'archives tar.gz dans /mnt..."

TARBALL=$(find /mnt -maxdepth 2 -name "*.tar.gz" -type f 2>/dev/null | head -n 1)

if [ -n "$TARBALL" ]; then
    echo "Archive trouvée : $TARBALL"
    echo "Contenu de l'archive (premiers éléments) :"
    tar -tzf "$TARBALL" | head -n 20
    echo ""
    read -r -p "Voulez-vous extraire cette archive à la racine / ? (o/N) : " CONFIRM
    
    if [[ "$CONFIRM" =~ ^[oOyY]$ ]]; then
        echo "Extraction de l'archive vers / ..."
        sudo tar -xzf "$TARBALL" -C / --preserve-permissions
        if [ $? -eq 0 ]; then
            echo "Extraction terminée avec succès."
        else
            echo "Erreur lors de l'extraction de l'archive."
        fi
    else
        echo "Extraction annulée."
    fi
else
    echo "Aucune archive tar.gz trouvée dans /mnt"
fi

echo ""

# Demande interactive pour le fichier APT
# Cette liste peut être obtenue avec : apt-mark showmanual > "/opt/apt-list.txt"
echo "--- Restauration APT ---"
read -r -p "Veuillez indiquer le chemin du fichier liste APT (Entrée pour ignorer) : " APT_LIST

if [ -n "$APT_LIST" ] && [ -f "$APT_LIST" ]; then
    echo "Liste des paquets APT trouvée : $APT_LIST"
    echo "Mise à jour des dépôts..."
    sudo apt update
    echo "Vérification des paquets disponibles..."
    
    # Lecture brute des paquets
    RAW_PACKAGES=$(cat "$APT_LIST" | tr '\n' ' ')
    VALID_PACKAGES=""
    UNKNOWN_PACKAGES=""

    # Filtrage des paquets
    for pkg in $RAW_PACKAGES; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            VALID_PACKAGES="$VALID_PACKAGES $pkg"
        else
            UNKNOWN_PACKAGES="$UNKNOWN_PACKAGES $pkg"
        fi
    done

    if [ ! -z "$UNKNOWN_PACKAGES" ]; then
        echo "Les paquets suivants sont introuvables et seront ignorés : $UNKNOWN_PACKAGES"
    fi

    if [ ! -z "$VALID_PACKAGES" ]; then
        echo "Tentative d'installation groupée des paquets valides..."
        if ! sudo apt install -y $VALID_PACKAGES; then
            echo "L'installation groupée a échoué (problème de dépendance ?)."
            echo "Passage à l'installation paquet par paquet (pour en installer un maximum)..."
            
            for pkg in $VALID_PACKAGES; do
                echo "Tentative d'installation de $pkg..."
                sudo apt install -y "$pkg" || echo "Échec de l'installation de $pkg"
            done
        else
            echo "Installation groupée réussie."
        fi
    else
        echo "Aucun paquet valide à installer."
    fi

    # Nettoyage
    sudo apt autoremove -y
else
    if [ -z "$APT_LIST" ]; then
        echo "Restauration APT ignorée (aucun fichier fourni)."
    else
        echo "Fichier '$APT_LIST' introuvable/invalide."
    fi
fi


# Demande interactive pour le fichier Flatpak
# Cette liste peut être obtenue avec : flatpak list --columns=application --app > "/opt/flatpak-list.txt"
echo "--- Restauration Flatpak ---"
read -r -p "Veuillez indiquer le chemin du fichier liste Flatpak (Entrée pour ignorer) : " FLATPAK_LIST

if [ -n "$FLATPAK_LIST" ] && [ -f "$FLATPAK_LIST" ]; then
    echo "Liste des applications Flatpak trouvée : $FLATPAK_LIST"
    
    # Vérification et installation de Flatpak si nécessaire
    if ! command -v flatpak &> /dev/null; then
        echo "Flatpak n'est pas installé. Tentative d'installation..."
        sudo apt install -y flatpak
        
        if ! command -v flatpak &> /dev/null; then
            echo "Impossible d'installer Flatpak. Les applications Flatpak ne seront pas restaurées."
        fi
    fi

    if command -v flatpak &> /dev/null; then
        echo "Configuration du remote Flathub..."
        sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

        echo "Installation des Flatpaks..."
        
        # Le fichier de backup contient --columns=application --app, donc juste les ID (ex: org.mozilla.firefox)
        while IFS= read -r app; do
            if [ ! -z "$app" ]; then
                echo "Installation de $app..."
                # Suggest explicit remote 'flathub' to avoid ambiguity or missing refs
                sudo flatpak install -y --noninteractive flathub "$app" || echo "Échec de l'installation de $app"
            fi
        done < "$FLATPAK_LIST"
    else
        echo "Flatpak n'est pas installé sur ce système."
    fi
else
    if [ -z "$FLATPAK_LIST" ]; then
        echo "Restauration Flatpak ignorée (aucun fichier fourni)."
    else
        echo "Fichier '$FLATPAK_LIST' introuvable/invalide."
    fi
fi