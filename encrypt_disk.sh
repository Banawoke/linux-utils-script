#!/bin/bash
# Script d'automatisation pour le déverrouillage LUKS via keyfile dans /boot
# Basé sur: https://www.howtoforge.com/automatically-unlock-luks-encrypted-drives-with-a-keyfile

set -e

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "Ce script doit être lancé en root (sudo)."
  exit 1
fi

echo "--- Vérification des prérequis ---"

# Vérifier présence de cryptsetup
if ! command -v cryptsetup &> /dev/null; then
    echo "Erreur: cryptsetup n'est pas installé."
    exit 1
fi

# Vérifier présence de update-initramfs
if ! command -v update-initramfs &> /dev/null; then
    echo "Erreur: update-initramfs n'est pas trouvé."
    exit 1
fi

echo "Prérequis validés."
echo ""

# 1. Demander le disque à chiffrer
echo "Disques chiffrés détectés :"
lsblk -o NAME,FSTYPE,UUID,MOUNTPOINT | grep crypto_LUKS || echo "Aucun détecté via lsblk..."
echo ""
read -p "Entrez le chemin de la partition LUKS à déverrouiller (ex: /dev/sda3) : " TARGET_DEVICE

if [ ! -b "$TARGET_DEVICE" ]; then
    echo "Erreur: Le périphérique $TARGET_DEVICE n'existe pas."
    exit 1
fi

if ! cryptsetup isLuks "$TARGET_DEVICE"; then
    echo "Erreur: $TARGET_DEVICE n'est pas un volume LUKS valide."
    exit 1
fi

TARGET_UUID=$(blkid -s UUID -o value "$TARGET_DEVICE")
if [ -z "$TARGET_UUID" ]; then
    echo "Erreur: Impossible de récupérer l'UUID de $TARGET_DEVICE."
    exit 1
fi
echo "Cible confirmée: $TARGET_DEVICE (UUID: $TARGET_UUID)"


# 2. Identifier /boot et préparer le keyfile
# On cherche le device monté sur /boot
BOOT_DEVICE=$(findmnt -n -o SOURCE /boot || echo "")

echo ""
if [ -z "$BOOT_DEVICE" ]; then
    echo "/boot ne semble pas être une partition montée séparément."
    echo "Le script a besoin de savoir sur quel périphérique stocker la clé (pour l'identifier par UUID)."
    read -p "Entrez la partition de boot (ex: /dev/sda1) : " BOOT_DEVICE
fi

if [ ! -b "$BOOT_DEVICE" ]; then
    echo "Erreur: Le périphérique de boot $BOOT_DEVICE n'existe pas."
    exit 1
fi

BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE")
echo "Partition de stockage de la clé: $BOOT_DEVICE (UUID: $BOOT_UUID)"

# Génération du nom de fichier
DEVICE_BASENAME=$(basename "$TARGET_DEVICE")
KEYFILE_NAME="keyfile_${DEVICE_BASENAME}"
KEYFILE_PATH="/boot/$KEYFILE_NAME"

if [ -f "$KEYFILE_PATH" ]; then
    echo "Attention: Le fichier $KEYFILE_PATH existe déjà."
    read -p "Voulez-vous l'écraser ? (o/N) : " OVERWRITE
    if [[ "$OVERWRITE" != "o" && "$OVERWRITE" != "O" ]]; then
        echo "Annulation."
        exit 1
    fi
fi

echo ""
echo "--- Création de la clé ---"
echo "Génération de 4KB de données aléatoires dans $KEYFILE_PATH..."
dd if=/dev/urandom of="$KEYFILE_PATH" bs=1024 count=4 status=none
chmod 0400 "$KEYFILE_PATH"

echo "Ajout de la clé au slot LUKS de $TARGET_DEVICE..."
echo "Vous allez devoir saisir un mot de passe existant de ce volume."
cryptsetup luksAddKey "$TARGET_DEVICE" "$KEYFILE_PATH"

# 3. Modification de /etc/crypttab
CRYPTTAB="/etc/crypttab"
echo ""
echo -e "${YELLOW}--- Modification de $CRYPTTAB ---${NC}"

# Sauvegarde
cp "$CRYPTTAB" "${CRYPTTAB}.bak.$(date +%s)"
echo "Sauvegarde effectuée vers ${CRYPTTAB}.bak.$(date +%s)"

# Préparation des chaînes de remplacement
# Format passdev: /dev/disk/by-uuid/<BOOT_UUID>:/<FILENAME_RELATIVE_TO_ROOT_OF_BOOT>
# Si /boot est un point de montage, le fichier /boot/keyfile est à la racine de la partition boot : /keyfile
PASSDEV_PATH="/dev/disk/by-uuid/${BOOT_UUID}:/${KEYFILE_NAME}"
KEYSCRIPT="keyscript=/lib/cryptsetup/scripts/passdev"

# Script awk pour modifier la ligne intelligemment
awk -v uuid="$TARGET_UUID" -v newkey="$PASSDEV_PATH" -v ks="$KEYSCRIPT" '
BEGIN { OFS="\t" }
{
    # On cherche la ligne correspondant à notre device (par UUID ou device path)
    if ($1 ~ uuid || $2 ~ "UUID="uuid ) {
        print "Modification de la ligne: " $0 > "/dev/stderr"
        
        # Champ 3 : Keyfile
        $3 = newkey
        
        # Champ 4 : Options
        # Si keyscript n existe pas déjà
        if ($4 !~ /keyscript=/) {
            # Si on trouve "discard", on le remplace par keyscript (comme demandé par l utilisateur)
            # Sinon on ajoute keyscript à la fin
            if ($4 ~ /discard/) {
                sub(/discard/, ks, $4)
            } else {
                $4 = $4 "," ks
            }
        }
    }
    print $0
}' "$CRYPTTAB" > "${CRYPTTAB}.tmp"

mv "${CRYPTTAB}.tmp" "$CRYPTTAB"

echo "Nouveau contenu pour le volume :"
grep "$TARGET_UUID" "$CRYPTTAB"

# 4. Update Initramfs
echo "Mise à jour de l'initramfs..."
update-initramfs -u

echo "Opération terminée avec succès."
echo "La clé est stockée dans $KEYFILE_PATH"
echo "Un backup de crypttab a été créé."