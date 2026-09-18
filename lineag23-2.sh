#!/bin/bash

# ==========================================
# ⚙️ Global Configuration
# ==========================================
DEVICE=${1:-"spes"}
ROM_CHOICE=${2:-1}
START_TIME=$(date +%s)
LOG_FILE="build_${DEVICE}_$(date +%Y%m%d_%H%M).log"
rm -f "/tmp/build_failed.lock"

export BUILD_USERNAME="ajay"
if [ -d "/opt/crave" ]; then
    export BUILD_HOSTNAME="crave"
else
    export BUILD_HOSTNAME=$(hostname)
fi
export BUILD_BROKEN_MISSING_REQUIRED_MODULES=true

# ==========================================
# 📝 Setup Full-Script Logging
# ==========================================
exec 3>&1 4>&2
exec 1> >(tee -a "$LOG_FILE") 2>&1

# 📱 Telegram Notification Setup (OPTIONAL — fill in or leave blank to disable)
TELEGRAM_TOKEN="8984418187:AAFDfoStPt-OpwKmm5U2vVSAwexfAeVKlqM"
TELEGRAM_CHAT_ID="5683536051"

# ☁️ Pixeldrain upload key (required for upload_and_notify + crash log upload)
PIXELDRAIN_API_KEY="04a5b1ba-3519-46ed-af20-d6904680fb94"
# ==========================================

set -eE
set -o pipefail

# ==========================================
# 📨 Core Helper Functions & Error Trap
# ==========================================
send_tg_msg() {
    [ -z "$TELEGRAM_TOKEN" ] && return 0
    local MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" \
        -d "text=${MESSAGE}" > /dev/null
}

handle_error() {
    trap - ERR
    set +eE
    set +o pipefail
    local FAILED_LINE="$1"

    exec 1>&3 2>&4
    sleep 1

    if [ -f "/tmp/build_failed.lock" ]; then
        exit 1
    fi
    touch "/tmp/build_failed.lock"

    echo "❌ CRITICAL: Build failed on line $FAILED_LINE!"

    local END_TIME=$(date +%s)
    local ELAPSED_MINUTES=$(((END_TIME - START_TIME) / 60))
    local DISPLAY_TIME="${ELAPSED_MINUTES}m"

    local FAIL_MSG="❌ <b>BUILD FAILED</b>%0A%0A"
    FAIL_MSG+="<blockquote>• <b>Device:</b> ${DEVICE_NAME}%0A"
    FAIL_MSG+="• <b>ROM:</b> ${ROM_NAME:-Unknown}%0A"
    FAIL_MSG+="• <b>Time:</b> ${DISPLAY_TIME}%0A"
    FAIL_MSG+="• <b>Error:</b> Line ${FAILED_LINE}%0A"
    FAIL_MSG+="• <b>Crash Log:</b> Check Crave/console output</blockquote>"

    send_tg_msg "$FAIL_MSG"

    exit 1
}

trap 'handle_error $LINENO' ERR

# ==========================================
# 🔀 The Switchboard (Define your ROMs here)
# ==========================================
echo "=========================================="
echo "🔍 Analyzing Build Request..."
echo "=========================================="
MANUAL_REMOVALS=()
MANUAL_GIT_CLONES=()
CUSTOM_REPOS=()

case "$DEVICE" in
    "spes")
        DEVICE_NAME="Xiaomi Spes"
        case "$ROM_CHOICE" in
            1)
                ROM_NAME="LineageOS 23.2"
                ANDROID_VERSION="16-QPR2"
                ROM_VERSION="23.2"
                GH_REPO="unknown-noob-afk/LineageOS_spes"

                REPO_INIT_URL="https://github.com/LineageOS/android.git"
                REPO_INIT_BRANCH="lineage-23.2"
                USE_LOCAL_MANIFEST="true"
                LOCAL_MANIFEST_REPO="https://github.com/unknown-noob-afk/los.git"
                LOCAL_MANIFEST_BRANCH="main"
                BUILD_TARGET="lineage_spes-userdebug"
                BUILD_COMMAND="mka bacon"
                ;;

            *)
                echo "❌ Invalid ROM choice for spes! (Only LineageOS 23.2 defined)"
                handle_error $LINENO
                ;;
        esac
        ;;

    *)
        echo "❌ Invalid Device! Use 'spes'."
        handle_error $LINENO
        ;;
esac

echo "✅ Selected Device: $DEVICE"
echo "✅ Selected ROM: $ROM_NAME"
echo "✅ Android Version: ${ANDROID_VERSION:-Unknown}"

# ==========================================
# 🛠️ Modular Execution Functions
# ==========================================

send_start_notification() {
    echo "📱 Sending 'Build Started' notification..."
    START_MSG="⏳ <b>BUILD STARTED</b>%0A%0A"
    START_MSG+="<blockquote>• <b>Device:</b> ${DEVICE_NAME}%0A"
    START_MSG+="• <b>ROM:</b> ${ROM_NAME}%0A"
    START_MSG+="• <b>Android:</b> ${ANDROID_VERSION}%0A"
    START_MSG+="• <b>Host:</b> ${BUILD_HOSTNAME}</blockquote>"
    send_tg_msg "$START_MSG"
}

sync_repositories() {
    echo "=========================================="
    echo "🚀 Starting Build Environment Setup"
    echo "=========================================="

    # 1. Cleanup & Base Sync
    repo init -u "$REPO_INIT_URL" -b "$REPO_INIT_BRANCH" --git-lfs --depth=1

    # Remove stale GCC prebuilts to prevent "Cannot remove project" repo sync errors
    rm -rf prebuilts/gcc 2>/dev/null || true

    if [ -f /opt/crave/resync.sh ]; then
        echo "🚀 Running Crave resync..."
        bash /opt/crave/resync.sh
    else
        echo "🚀 Running standard repo sync..."
        for i in {1..3}; do
            repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j$(nproc --all) && break || {
                if [ $i -eq 3 ]; then
                    echo "❌ Repo sync failed after 3 attempts."
                    handle_error $LINENO
                fi
                echo "⚠️ repo sync failed, retrying in 30 seconds... ($i/3)"
                sleep 30
            }
        done
    fi

    # 2. Manually clone device/vendor/kernel/hardware trees directly to their target paths
    #    (bypasses local_manifests, which wasn't reliably syncing custom projects)
    if [ "$USE_LOCAL_MANIFEST" == "true" ]; then
        echo "📥 Cloning device/vendor/kernel/hardware trees directly..."

        rm -rf device/xiaomi/spes
        git clone --depth=1 -b sixteen-qpr2 https://github.com/unknown-noob-afk/android_device_xiaomi_spes.git device/xiaomi/spes

        rm -rf vendor/xiaomi/spes
        git clone --depth=1 -b sixteen-qpr2 https://github.com/unknown-noob-afk/vendor_spes.git vendor/xiaomi/spes

        rm -rf kernel/xiaomi/spes
        git clone --depth=1 -b sixteen-qpr2 https://github.com/unknown-noob-afk/android_kernel_xiaomi_spes.git kernel/xiaomi/spes

        rm -rf hardware/xiaomi
        git clone --depth=1 -b lineage-23.2 https://github.com/unknown-noob-afk/android_hardware_xiaomi.git hardware/xiaomi

        # Sanity check — fail loudly if any tree didn't actually land
        for TREE in device/xiaomi/spes vendor/xiaomi/spes kernel/xiaomi/spes hardware/xiaomi; do
            if [ ! -d "$TREE" ] || [ -z "$(ls -A "$TREE" 2>/dev/null)" ]; then
                echo "❌ $TREE failed to clone or is empty."
                handle_error $LINENO
            fi
        done
        echo "✅ All custom trees present."
    else
        echo "⏭️ Skipping custom tree clones (Not supported by $ROM_NAME)."
    fi

    # Manual Removals (if any defined)
    if [ ${#MANUAL_REMOVALS[@]} -gt 0 ]; then
        echo "=========================================="
        echo "🧹 Executing Manual Conflict Removals..."
        for rm_target in "${MANUAL_REMOVALS[@]}"; do
            echo "🗑️ Removing $rm_target..."
            rm -rf "$rm_target"
        done
    fi

    # Manual Git Clones (if any defined)
    if [ ${#MANUAL_GIT_CLONES[@]} -gt 0 ]; then
        echo "=========================================="
        echo "⬇️ Executing Manual Git Clones in parallel..."
        for clone_args in "${MANUAL_GIT_CLONES[@]}"; do
            TARGET_DIR=$(echo "$clone_args" | awk '{print $NF}')
            echo "🗑️ Removing $TARGET_DIR to prepare for clean clone..."
            rm -rf "$TARGET_DIR"
            git clone --depth=1 $clone_args &
        done
        wait
    fi

    # Custom repos (if any defined)
    if [ ${#CUSTOM_REPOS[@]} -gt 0 ]; then
        echo "=========================================="
        echo "Syncing custom repositories in parallel for $ROM_NAME..."
        for repo_info in "${CUSTOM_REPOS[@]}"; do
            DIR="${repo_info%%|*}"
            REPO_NAME="${repo_info##*|}"
            rm -rf "$DIR"
            git clone "$BASE_URL/$REPO_NAME.git" --depth=1 "$DIR" &
        done
        wait
        echo "✅ Custom sources synced."
    else
        echo "⏭️ No custom repos defined for $ROM_NAME. Skipping parallel sync."
    fi
}

compile_rom() {
    export TZ="Asia/Kolkata"

    # 📦 Install legacy Ncurses via apt as safety net (spes only)
    if [ "$DEVICE" == "spes" ]; then
        if ! dpkg -s libncurses5 &> /dev/null; then
            echo "📦 Installing legacy libncurses5 dependencies via sudo..."
            sudo apt-get update -y
            sudo apt-get install -y libncurses5 libtinfo5 || true
        fi

        # 🔧 Fallback to System Symlink Hack if apt failed (Ubuntu 24.04 dropped it)
        if ! dpkg -s libncurses5 &> /dev/null; then
            echo "🔧 apt failed (likely Ubuntu 24.04). Applying ncurses6 system symlink hack..."
            NCURSES_LIB=$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib /lib -maxdepth 2 -name "libncurses.so.6*" -print -quit 2>/dev/null)
            TINFO_LIB=$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib /lib -maxdepth 2 -name "libtinfo.so.6*" -print -quit 2>/dev/null)

            if [ -n "$NCURSES_LIB" ]; then
                NCURSES_DIR=$(dirname "$NCURSES_LIB")
                sudo ln -sf "$NCURSES_LIB" "$NCURSES_DIR/libncurses.so.5"
            fi
            if [ -n "$TINFO_LIB" ]; then
                TINFO_DIR=$(dirname "$TINFO_LIB")
                sudo ln -sf "$TINFO_LIB" "$TINFO_DIR/libtinfo.so.5"
            fi
            sudo ldconfig || true
        fi
    fi

    set +eE
    source build/envsetup.sh
    if [ -n "$BUILD_TARGET" ]; then
        lunch "$BUILD_TARGET"
        set -eE
    else
        set -eE
        echo "⏭️ Skipping lunch as requested (using full build command)..."
    fi

    echo "=========================================="
    echo "🔨 Starting compilation for $ROM_NAME..."
    echo "=========================================="

    $BUILD_COMMAND

    END_TIME=$(date +%s)
    BUILD_MINUTES=$(((END_TIME - START_TIME) / 60))
    DISPLAY_TIME="${BUILD_MINUTES}m"
    echo "⏱️ Build finished in $DISPLAY_TIME."
}

collect_artifacts() {
    echo "=========================================="
    echo "📦 Collecting output images..."
    TARGET_DIR="out/target/product/${DEVICE}"
    mkdir -p imgs_output
    FILES_TO_UPLOAD=()

    for IMG in boot.img dtb.img dtbo.img recovery.img vendor_boot.img; do
        if [ -f "${TARGET_DIR}/$IMG" ]; then
            cp "${TARGET_DIR}/$IMG" imgs_output/
            FILES_TO_UPLOAD+=("imgs_output/$IMG")
            echo "✅ Copied $IMG"
        else
            echo "⚠️ $IMG not found, skipping."
        fi
    done

    ROM_ZIP=$(ls -t ${TARGET_DIR}/*${DEVICE}*.zip 2>/dev/null | head -n 1 || true)
    if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
        cp "$ROM_ZIP" imgs_output/
        FILES_TO_UPLOAD+=("imgs_output/$(basename "$ROM_ZIP")")
        echo "✅ Copied ROM zip: $(basename "$ROM_ZIP")"

        # Compute checksums and size for Telegram notification
        ROM_SIZE_HUMAN=$(du -h "$ROM_ZIP" 2>/dev/null | awk '{print $1}' || echo "Unknown")
        ROM_SHA256=$(sha256sum "$ROM_ZIP" 2>/dev/null | awk '{print $1}' || echo "Unknown")
        ROM_MD5=$(md5sum "$ROM_ZIP" 2>/dev/null | awk '{print $1}' || echo "Unknown")

        # ==========================================
        # 📝 OTA JSON Metadata Generation / Handling
        # ==========================================
        echo "=========================================="
        echo "📝 Processing OTA JSON Metadata..."

        FILE_NAME=$(basename "$ROM_ZIP")
        REL_TAG=$(date +%y%m%d)

        # 🕒 Extract precise build datetime from ROM metadata
        EXTRACT_DIR=$(mktemp -d)
        unzip -p "$ROM_ZIP" META-INF/com/android/metadata > "$EXTRACT_DIR/metadata.txt" 2>/dev/null || true

        if grep -q "post-timestamp=" "$EXTRACT_DIR/metadata.txt" 2>/dev/null; then
            BUILD_DATETIME=$(grep "post-timestamp=" "$EXTRACT_DIR/metadata.txt" | cut -d= -f2 | tr -d '\r')
            echo "✅ Extracted precise build datetime from zip: $BUILD_DATETIME"
        else
            BUILD_DATETIME=$(date +%s)
            echo "⚠️ Warning: Could not extract precise datetime from zip, using current time: $BUILD_DATETIME"
        fi
        rm -rf "$EXTRACT_DIR"

        # 🟢 LineageOS Standard Structure (23.2)
        echo "Generating standard ${DEVICE}.json for LineageOS..."
        if ! command -v jq &> /dev/null; then
            sudo apt-get install -y jq > /dev/null 2>&1 || true
        fi

        FILE_SIZE=$(stat -c %s "$ROM_ZIP")
        GH_DOWNLOAD_URL="https://github.com/${GH_REPO}/releases/download/${REL_TAG}/${FILE_NAME}"
        JSON_FILE="imgs_output/${DEVICE}.json"

        jq -n \
          --arg dt "$BUILD_DATETIME" \
          --arg fn "$FILE_NAME" \
          --arg id "$ROM_SHA256" \
          --arg rt "UNOFFICIAL" \
          --arg sz "$FILE_SIZE" \
          --arg url "$GH_DOWNLOAD_URL" \
          --arg ver "$ROM_VERSION" \
          '[
            {
              datetime: ($dt | tonumber),
              type: $rt,
              version: $ver,
              files: [
                {
                  filename: $fn,
                  sha256: $id,
                  size: ($sz | tonumber),
                  url: $url
                }
              ]
            }
          ]' > "$JSON_FILE"

        echo "✅ Created $JSON_FILE"
        FILES_TO_UPLOAD+=("$JSON_FILE")

        # ==========================================
        # Generate Changelog from Gerrit
        # ==========================================
        echo "=========================================="
        echo "📝 Generating Changelog from LineageOS Gerrit..."
        branch="$REPO_INIT_BRANCH"
        if [ -z "$branch" ]; then
            branch="lineage-23.2"
        fi

        echo "# LineageOS Changelog (${branch})" > imgs_output/source_changelog.txt
        echo "Generated on $(date)" >> imgs_output/source_changelog.txt
        echo "" >> imgs_output/source_changelog.txt

        if curl -s -G "https://review.lineageos.org/changes/" --data-urlencode "q=status:merged branch:${branch} -project:^.*_device_.* -project:^.*mainline.* (-project:^.*_kernel_.* OR project:^.*android_kernel_qcom_sm8350.*)" -d "n=200" | sed '1d' | jq -r 'group_by(.project) | sort_by(.[0].submitted // .[0].updated // "") | reverse | .[] | "### " + .[0].project + "\n" + (map("- [" + ((.submitted // .updated // "Unknown") | .[0:10]) + "] " + .subject) | join("\n")) + "\n"' >> imgs_output/source_changelog.txt; then
            if [ -s imgs_output/source_changelog.txt ]; then
                echo "✅ Changelog saved to imgs_output/source_changelog.txt"
                FILES_TO_UPLOAD+=("imgs_output/source_changelog.txt")
            else
                echo "⚠️ Gerrit API returned empty or failed to parse."
            fi
        else
            echo "⚠️ Failed to fetch changelog from Gerrit."
        fi
    else
        echo "❌ ROM zip not found in ${TARGET_DIR}."
        handle_error $LINENO
    fi
}

upload_and_notify() {
    echo "------------------------------------------"
    echo "☁️ Uploading ${#FILES_TO_UPLOAD[@]} file(s) in parallel to Pixeldrain..."
    echo "------------------------------------------"

    MASTER_LINK=""
    UPLOADED_IDS=()
    TMP_DIR=$(mktemp -d)

    for i in "${!FILES_TO_UPLOAD[@]}"; do
        (
            FILE_PATH="${FILES_TO_UPLOAD[$i]}"
            UPLOAD_RES=$(curl -s --retry 3 --connect-timeout 20 --max-time 1800 \
                -u ":$PIXELDRAIN_API_KEY" \
                -F "file=@${FILE_PATH}" \
                "https://pixeldrain.com/api/file" || true)
            echo "$UPLOAD_RES" > "$TMP_DIR/res_$i.json"
        ) &
    done
    wait

    for i in "${!FILES_TO_UPLOAD[@]}"; do
        FILE_PATH="${FILES_TO_UPLOAD[$i]}"
        FILE_NAME=$(basename "$FILE_PATH")
        UPLOAD_RES=$(cat "$TMP_DIR/res_$i.json" 2>/dev/null || true)
        SUCCESS=$(echo "$UPLOAD_RES" | jq -r '.success' 2>/dev/null || true)

        if [ "$SUCCESS" == "true" ]; then
            FILE_ID=$(echo "$UPLOAD_RES" | jq -r '.id' 2>/dev/null || true)
            UPLOADED_IDS+=("$FILE_ID")
            echo "✅ Uploaded $FILE_NAME! ID: $FILE_ID"
        else
            echo "❌ Failed to upload $FILE_NAME to Pixeldrain"
            echo "Response: $UPLOAD_RES"
        fi
    done
    rm -rf "$TMP_DIR"

    if [ ${#UPLOADED_IDS[@]} -gt 0 ]; then
        echo "📁 Creating Pixeldrain List (Folder)..."

        FILES_JSON="["
        for i in "${!UPLOADED_IDS[@]}"; do
            FILES_JSON+="{\"id\":\"${UPLOADED_IDS[$i]}\", \"description\":\"\"}"
            if [ $i -lt $((${#UPLOADED_IDS[@]} - 1)) ]; then
                FILES_JSON+=","
            fi
        done
        FILES_JSON+="]"

        LIST_RES=$(curl -s -X POST -u ":$PIXELDRAIN_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"title\": \"$ROM_NAME Update\", \"files\": $FILES_JSON}" \
            "https://pixeldrain.com/api/list" || true)

        LIST_SUCCESS=$(echo "$LIST_RES" | jq -r '.success' 2>/dev/null || true)

        if [ "$LIST_SUCCESS" == "true" ]; then
            LIST_ID=$(echo "$LIST_RES" | jq -r '.id' 2>/dev/null || true)
            MASTER_LINK="https://pixeldrain.com/l/$LIST_ID"
            echo "✅ Folder created successfully!"
        else
            echo "⚠️ Failed to create folder list. Falling back to single file link."
            MASTER_LINK="https://pixeldrain.com/u/${UPLOADED_IDS[0]}"
        fi
    else
        echo "⚠️ No files uploaded successfully. No download link available."
    fi

    echo "🎉 Uploads complete for $ROM_NAME!"
    echo "🔗 Master Link: $MASTER_LINK"
}

send_success_notification() {
    SUCCESS_MSG="🚀 <b>BUILD SUCCESSFUL</b>%0A%0A"
    SUCCESS_MSG+="<blockquote>• <b>Device:</b> ${DEVICE_NAME}%0A"
    SUCCESS_MSG+="• <b>ROM:</b> ${ROM_NAME}%0A"
    SUCCESS_MSG+="• <b>Android:</b> ${ANDROID_VERSION}%0A"
    SUCCESS_MSG+="• <b>Time:</b> ${DISPLAY_TIME}%0A"
    if [ -n "$ROM_SIZE_HUMAN" ] && [ "$ROM_SIZE_HUMAN" != "Unknown" ]; then
        SUCCESS_MSG+="• <b>Size:</b> ${ROM_SIZE_HUMAN}%0A"
    fi
    if [ -n "$ROM_MD5" ] && [ "$ROM_MD5" != "Unknown" ]; then
        SUCCESS_MSG+="• <b>MD5:</b> <code>${ROM_MD5}</code>%0A"
    fi
    if [ -n "$MASTER_LINK" ]; then
        SUCCESS_MSG+="• <b>Download:</b> <a href=\"${MASTER_LINK}\">Download on Pixeldrain</a>%0A"
    fi
    SUCCESS_MSG="${SUCCESS_MSG}</blockquote>"
    send_tg_msg "$SUCCESS_MSG"
}

# ==========================================
# 🚀 MAIN EXECUTION PIPELINE
# ==========================================
send_start_notification
sync_repositories
compile_rom
collect_artifacts

# ==========================================
# 🗜️ Finalize Logs (must happen BEFORE upload, so log ships in the same batch)
# ==========================================
exec 1>&3 2>&4
sleep 1

if [ -f "$LOG_FILE" ] && command -v gzip &> /dev/null; then
    gzip -9 "$LOG_FILE"
    LOG_FILE="${LOG_FILE}.gz"
    FILES_TO_UPLOAD+=("$LOG_FILE")
fi

upload_and_notify
send_success_notification

# Clean up log file to save space
if [ -f "$LOG_FILE" ]; then
    echo "🧹 Deleting log file $LOG_FILE to save space..."
    rm -f "$LOG_FILE"
fi

echo "✅ All done. Images in imgs_output/, log uploaded."
