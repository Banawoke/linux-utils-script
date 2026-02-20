#!/bin/bash

# Script pour supprimer tous les dossiers et sous-dossiers d'un chemin
# en déplaçant tous les fichiers vers la racine du chemin spécifié

# Fonction d'aide
show_help() {
    echo "Usage: $0 [-t] <chemin_cible>"
    echo ""
    echo "Ce script supprime tous les dossiers et sous-dossiers du chemin spécifié"
    echo "et déplace tous les fichiers vers la racine de ce chemin."
    echo ""
    echo "Arguments:"
    echo "  chemin_cible    Le chemin où effectuer l'opération"
    echo ""
    echo "Options:"
    echo "  -h, --help      Afficher cette aide"
    echo "  -t              Déplacer dans un dossier 'other/' tous les fichiers"
    echo "                  dont l'extension n'est PAS dans la liste des formats"
    echo "                  conservés (.docx, .pptx, .xlsx, .md, .conf, .cfg,"
    echo "                  .html, .pp, .yaml, .yml, .txt, .pdf)"
    echo ""
    echo "Exemple:"
    echo "  $0 /home/user/dossier_test"
    echo "  $0 -t /home/user/dossier_test"
}

# Parsing des options
TRI_OTHER=false

while getopts ":ht" opt; do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        t)
            TRI_OTHER=true
            ;;
        \?)
            echo "Option invalide: -$OPTARG" >&2
            show_help
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

# Vérification des arguments
if [ $# -eq 0 ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

TARGET_PATH="$1"

# Vérification que le chemin existe
if [ ! -d "$TARGET_PATH" ]; then
    echo "Erreur: Le chemin '$TARGET_PATH' n'existe pas ou n'est pas un dossier."
    exit 1
fi

# Conversion en chemin absolu
TARGET_PATH=$(realpath "$TARGET_PATH")

echo "Traitement du dossier: $TARGET_PATH"
echo "Recherche et déplacement des fichiers..."

# Compteurs pour les statistiques
files_moved=0
dirs_removed=0

# Fonction pour déplacer les fichiers et gérer les conflits de noms
move_file_safely() {
    local source_file="$1"
    local target_dir="$2"
    local filename=$(basename "$source_file")
    local target_file="$target_dir/$filename"
    local counter=1
    
    # Si le fichier existe déjà, ajouter un suffixe numérique
    while [ -e "$target_file" ]; do
        local name_without_ext="${filename%.*}"
        local extension="${filename##*.}"
        
        if [ "$name_without_ext" = "$extension" ]; then
            # Pas d'extension
            target_file="$target_dir/${filename}_${counter}"
        else
            # Avec extension
            target_file="$target_dir/${name_without_ext}_${counter}.${extension}"
        fi
        counter=$((counter + 1))
    done
    
    mv "$source_file" "$target_file"
    echo "  Déplacé: $(basename "$source_file") -> $(basename "$target_file")"
    return 0
}

# Traitement récursif: d'abord déplacer tous les fichiers
echo "Phase 1: Déplacement des fichiers vers la racine..."
while IFS= read -r -d '' file; do
    if [ -f "$file" ] && [ "$(dirname "$file")" != "$TARGET_PATH" ]; then
        move_file_safely "$file" "$TARGET_PATH"
        files_moved=$((files_moved + 1))
    fi
done < <(find "$TARGET_PATH" -type f -print0)

echo ""
echo "Phase 2: Suppression des dossiers vides..."

# Supprimer tous les dossiers vides (en commençant par les plus profonds)
while IFS= read -r -d '' dir; do
    if [ "$dir" != "$TARGET_PATH" ] && [ -d "$dir" ]; then
        # Vérifier que le dossier est vide
        if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
            rmdir "$dir" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "  Supprimé: $dir"
                dirs_removed=$((dirs_removed + 1))
            fi
        else
            echo "  Attention: Le dossier '$dir' n'est pas vide, ignoré"
        fi
    fi
done < <(find "$TARGET_PATH" -depth -type d -print0)

# Deuxième passage pour s'assurer que tous les dossiers vides sont supprimés
echo ""
echo "Phase 3: Vérification finale et nettoyage..."
cleanup_needed=true
cleanup_rounds=0

while [ "$cleanup_needed" = true ] && [ $cleanup_rounds -lt 10 ]; do
    cleanup_needed=false
    cleanup_rounds=$((cleanup_rounds + 1))
    
    while IFS= read -r -d '' dir; do
        if [ "$dir" != "$TARGET_PATH" ] && [ -d "$dir" ]; then
            if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
                rmdir "$dir" 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo "  Nettoyage: $dir"
                    dirs_removed=$((dirs_removed + 1))
                    cleanup_needed=true
                fi
            fi
        fi
    done < <(find "$TARGET_PATH" -depth -type d -print0)
done

echo ""
echo "=== RÉSUMÉ ==="
echo "Chemin traité: $TARGET_PATH"
echo "Fichiers déplacés: $files_moved"
echo "Dossiers supprimés: $dirs_removed"
echo ""

# Vérification finale
remaining_dirs=$(find "$TARGET_PATH" -mindepth 1 -type d | wc -l)
if [ $remaining_dirs -eq 0 ]; then
    echo "Opération terminée avec succès!"
    echo "Tous les dossiers ont été supprimés et tous les fichiers sont maintenant à la racine."
else
    echo "Attention: $remaining_dirs dossier(s) n'ont pas pu être supprimés."
    echo "Dossiers restants:"
    find "$TARGET_PATH" -mindepth 1 -type d
fi

# Phase 4 (optionnelle): Déplacer dans 'other/' tout ce qui n'est pas un format connu
if [ "$TRI_OTHER" = true ]; then
    echo ""
    echo "Phase 4: Déplacement des fichiers non reconnus dans le dossier 'other/'..."

    # Extensions à GARDER à la racine
    KEEP_EXTENSIONS=("docx" "pptx" "xlsx" "md" "conf" "cfg" "html" "pp" "yaml" "yml" "txt" "pdf")
    OTHER_DIR="$TARGET_PATH/other"
    files_sorted=0

    # Créer le dossier 'other/' s'il n'existe pas
    mkdir -p "$OTHER_DIR"

    for file in "$TARGET_PATH"/*; do
        # Ignorer les dossiers
        [ -f "$file" ] || continue

        # Récupérer l'extension en minuscule
        filename=$(basename "$file")
        extension="${filename##*.}"
        extension_lower=$(echo "$extension" | tr '[:upper:]' '[:lower:]')

        # Vérifier si l'extension fait partie de la liste à conserver
        keep=false
        for ext in "${KEEP_EXTENSIONS[@]}"; do
            if [ "$extension_lower" = "$ext" ]; then
                keep=true
                break
            fi
        done

        # Si l'extension n'est pas dans la liste, déplacer dans 'other/'
        if [ "$keep" = false ]; then
            move_file_safely "$file" "$OTHER_DIR"
            files_sorted=$((files_sorted + 1))
        fi
    done

    echo ""
    echo "Fichiers déplacés dans 'other/': $files_sorted"
fi

echo ""
echo "Contenu final du dossier racine:"
ls -la "$TARGET_PATH"