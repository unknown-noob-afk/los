#!/bin/bash

rm -rf .repo/local_manifests/

# repo init rom
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth=1
echo "=================="
echo "Repo init success"
echo "=================="

# Local manifest
mkdir -p .repo/local_manifests
git clone https://github.com/unknown-noob-afk/local_manifest_spes.git .repo/local_manifests
echo "============================"
echo "Local manifest clone success"
echo "============================"

# Build Sync
/opt/crave/resync.sh
echo "============="
echo "Sync success"
echo "============="

# Export
export BUILD_USERNAME=NOOB
export BUILD_HOSTNAME=crave
export BUILD_BROKEN_MISSING_REQUIRED_MODULES=true
echo "======= Export Done ======"

# Set up build environment
source build/envsetup.sh
echo "============="

# Lunch
lunch lineage_spes-bp4a-userdebug

# Build
mka bacon

# Copy imgs to a separate folder for easy download
mkdir -p imgs_output
cp out/target/product/spes/boot.img imgs_output/
cp out/target/product/spes/init_boot.img imgs_output/
cp out/target/product/spes/dtbo.img imgs_output/
cp out/target/product/spes/recovery.img imgs_output/
cp out/target/product/spes/vendor_boot.img imgs_output/
