#!/bin/bash
# ==============================================================================
# Script de conversion LUKS2 in-place de la racine (/) pour Debian/Ubuntu
# ==============================================================================
# Ce script prépare la conversion in-place de la partition racine (/) en LUKS2.
# Il fonctionne de manière automatisée lors du démarrage dans l'initramfs.
#
# Prérequis :
# - /boot doit être sur une partition séparée non chiffrée (ex: /dev/sda2)
# - Paquets installés : cryptsetup, cryptsetup-initramfs, lvm2
#
# Usage :
#   sudo ./setup_luks_root.sh [MOT_DE_PASSE_LUKS]
#   sudo reboot
# ==============================================================================

set -euo pipefail

PASSPHRASE="${1:-}"

if [ -z "$PASSPHRASE" ]; then
    echo -n "Veuillez entrer le mot de passe LUKS désiré : "
    read -s PASSPHRASE
    echo
fi

if [ -z "$PASSPHRASE" ]; then
    echo "Erreur: Le mot de passe ne peut pas être vide."
    exit 1
fi

echo "=== 1. Sauvegarde des fichiers de configuration ==="
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
[ -f /etc/crypttab ] && cp /etc/crypttab /etc/crypttab.bak.$(date +%Y%m%d_%H%M%S)

echo "=== 2. Écriture de la clé temporaire ==="
echo -n "$PASSPHRASE" > /etc/luks_convert.key
chmod 600 /etc/luks_convert.key

echo "=== 3. Ajout de dm-crypt aux modules initramfs ==="
grep -qxF "dm-crypt" /etc/initramfs-tools/modules || echo "dm-crypt" >> /etc/initramfs-tools/modules

echo "=== 4. Configuration de /etc/crypttab et /etc/fstab ==="
echo "root_crypt /dev/mapper/albt--hyper--v--vg-root none luks,discard" > /etc/crypttab
sed -i "s|/dev/mapper/albt--hyper--v--vg-root|/dev/mapper/root_crypt|g" /etc/fstab

echo "=== 5. Création du hook initramfs pour resize2fs et la clé LUKS ==="
cat << 'HOOKEOF' > /etc/initramfs-tools/hooks/add_resize2fs
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/sbin/resize2fs /sbin
if [ -f /etc/luks_convert.key ]; then
    copy_file file /etc/luks_convert.key /etc/luks_convert.key
fi
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/add_resize2fs

echo "=== 6. Création du script de conversion dans init-premount ==="
cat << 'SCRIPTEOF' > /etc/initramfs-tools/scripts/init-premount/luks_convert
#!/bin/sh
PREREQ="lvm"
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac

if [ -f /etc/luks_convert.key ]; then
    echo "=========================================================="
    echo "  LANCEMENT DE LA CONVERSION LUKS2 IN-PLACE DE LA RACINE  "
    echo "=========================================================="
    
    modprobe dm-crypt || true
    modprobe xts || true
    modprobe aesni-intel || true

    # Vérification du système de fichiers
    /sbin/e2fsck -fy /dev/mapper/albt--hyper--v--vg-root
    
    # Réduction temporaire ext4 (100G)
    /sbin/resize2fs /dev/mapper/albt--hyper--v--vg-root 100G
    
    # Chiffrement in-place avec cryptsetup reencrypt
    /sbin/cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32M /dev/mapper/albt--hyper--v--vg-root -q --key-file /etc/luks_convert.key
    
    # Ouverture du volume chiffré
    /sbin/cryptsetup open /dev/mapper/albt--hyper--v--vg-root root_crypt --key-file /etc/luks_convert.key
    
    # Re-expansion du filesystem ext4 au maximum du volume LUKS
    /sbin/resize2fs /dev/mapper/root_crypt
    
    # Nettoyage de la clé et du script sur le système de fichiers chiffré
    mkdir -p /mnt_temp
    mount /dev/mapper/root_crypt /mnt_temp
    rm -f /mnt_temp/etc/luks_convert.key
    rm -f /mnt_temp/etc/initramfs-tools/scripts/init-premount/luks_convert
    rm -f /mnt_temp/etc/initramfs-tools/hooks/add_resize2fs
    
    # Création d'un service systemd de mise à jour initramfs post-boot
    cat << "SERVICEEOF" > /mnt_temp/etc/systemd/system/luks-post-boot.service
[Unit]
Description=Post-boot LUKS initramfs update
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "update-initramfs -u; systemctl disable luks-post-boot.service; rm -f /etc/systemd/system/luks-post-boot.service"

[Install]
WantedBy=multi-user.target
SERVICEEOF
    mkdir -p /mnt_temp/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/luks-post-boot.service /mnt_temp/etc/systemd/system/multi-user.target.wants/luks-post-boot.service
    
    umount /mnt_temp
    
    echo "=========================================================="
    echo "  CONVERSION LUKS2 TERMINEE AVEC SUCCES !                "
    echo "=========================================================="
fi
SCRIPTEOF
chmod +x /etc/initramfs-tools/scripts/init-premount/luks_convert

echo "=== 7. Ré-génération de initramfs et mise à jour de GRUB ==="
update-initramfs -u -k all
update-grub

echo "================================================================="
echo " PRÊT ! Le système est configuré pour chiffrer la racine en LUKS"
echo " lors du prochain redémarrage."
echo "================================================================="
