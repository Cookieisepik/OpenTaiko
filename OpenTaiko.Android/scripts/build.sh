#!/usr/bin/env bash
# OpenTaiko Android - unified Linux build/setup script
#
# Replaces:
#   build.ps1
#   download-bass.ps1
#   download-ffmpeg.ps1
#   make-appicons.py
#   make-songs-zip.ps1
#   fetch-ffmpeg-autogen.ps1 (now automatic)
#
# Usage:
#   ./build.sh [options]
#
# Options:
#   --release                 Build Release instead of Debug
#   --install                 Install the APK to a connected device/emulator
#   --run                     Install, then launch the app
#   --clean                   Remove OpenTaiko.Android/obj and bin before building
#   --bundle-songs            Bundle the song library into the APK
#   --push-songs              Push the song library to the device with adb
#   --songs-path PATH         Song folder for --bundle-songs/--push-songs
#   --android-sdk PATH        Android SDK root
#   --java-sdk PATH           JDK root (JDK 17 required)
#   --make-icons              Generate Android launcher icons
#   --make-songs-zip SRC ZIP  Create a filtered songs ZIP and exit
#   --download-bass           Download BASS natives
#   --download-ffmpeg         Download FFmpeg natives
#   --fetch-ffmpeg-autogen    Fetch and patch FFmpeg.AutoGen source
#   --help                    Show this help
#
# If no action-only option is supplied, the normal Android build is performed.
#
# Requirements:
#   bash, curl, unzip, zip (optional; song ZIP uses Python if available),
#   git (for FFmpeg.AutoGen fetch), dotnet with the Android workload,
#   JDK 17, Android SDK/platform-tools, Python 3 + Pillow for --make-icons.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$(cd "$APP_DIR/.." && pwd)"
ROOT="$APP_DIR"
CSPROJ="$ROOT/OpenTaiko.Android.csproj"

CONFIG="Debug"
INSTALL=0
RUN_APP=0
CLEAN=0
BUNDLE_SONGS=0
PUSH_SONGS=0
MAKE_ICONS=0
DOWNLOAD_BASS=0
DOWNLOAD_FFMPEG=0
FETCH_FFMPEG_AUTOGEN=0
SONGS_PATH=""
ANDROID_SDK=""
JAVA_SDK=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
    case "$1" in
        --release) CONFIG="Release" ;;
        --install) INSTALL=1 ;;
        --run) RUN_APP=1; INSTALL=1 ;;
        --clean) CLEAN=1 ;;
        --bundle-songs) BUNDLE_SONGS=1 ;;
        --push-songs) PUSH_SONGS=1 ;;
        --make-icons) MAKE_ICONS=1 ;;
        --download-bass) DOWNLOAD_BASS=1 ;;
        --download-ffmpeg) DOWNLOAD_FFMPEG=1 ;;
        --fetch-ffmpeg-autogen) FETCH_FFMPEG_AUTOGEN=1 ;;
        --songs-path)
            (($# >= 2)) || die "--songs-path requires a path"
            SONGS_PATH="$2"; shift
            ;;
        --android-sdk)
            (($# >= 2)) || die "--android-sdk requires a path"
            ANDROID_SDK="$2"; shift
            ;;
        --java-sdk)
            (($# >= 2)) || die "--java-sdk requires a path"
            JAVA_SDK="$2"; shift
            ;;
        --make-songs-zip)
            (($# >= 3)) || die "--make-songs-zip requires SOURCE and DESTINATION"
            MAKE_SONGS_ZIP_SRC="$2"
            MAKE_SONGS_ZIP_DST="$3"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

# ------------------------------ helpers -------------------------------------

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_songs_path() {
    local p
    if [[ -n "$SONGS_PATH" ]]; then
        p="$SONGS_PATH"
    else
        p="$REPO/../OpenTaiko-Soundtrack"
    fi
    [[ -d "$p" ]] || die "Songs folder not found: $p (pass --songs-path PATH)"
    SONGS_ABS="$(cd "$p" && pwd)"
}

find_android_sdk() {
    if [[ -n "$ANDROID_SDK" && -d "$ANDROID_SDK/platforms" ]]; then
        ANDROID_SDK="$(cd "$ANDROID_SDK" && pwd)"
        return
    fi

    local candidates=()
    [[ -n "${ANDROID_HOME:-}" ]] && candidates+=("$ANDROID_HOME")
    [[ -n "${ANDROID_SDK_ROOT:-}" ]] && candidates+=("$ANDROID_SDK_ROOT")
    candidates+=(
        "/usr/local/lib/android/sdk"
        "/opt/android-sdk"
        "/android-sdk"
        "$HOME/Android/Sdk"
        "$HOME/.android/sdk"
    )

    for p in "${candidates[@]}"; do
        if [[ -d "$p/platforms" ]] || [[ -x "$p/cmdline-tools/latest/bin/sdkmanager" ]]; then
            ANDROID_SDK="$(cd "$p" && pwd)"
            return
        fi
    done

    die "Android SDK not found. Install it or pass --android-sdk PATH."
}

find_java_sdk() {
    if [[ -n "$JAVA_SDK" && -x "$JAVA_SDK/bin/java" ]]; then
        JAVA_SDK="$(cd "$JAVA_SDK" && pwd)"
        return
    fi

    local candidates=()
    [[ -n "${JAVA_HOME:-}" ]] && candidates+=("$JAVA_HOME")
    candidates+=(
        "/usr/lib/jvm/temurin-17-jdk-amd64"
        "/usr/lib/jvm/java-17-openjdk-amd64"
        "$HOME/.local/share/JetBrains/Toolbox/apps/AndroidStudio"/*/*/*/jbr
        "$HOME/android-studio/jbr"
        "/opt/android-studio/jbr"
        "/usr/lib/jvm/java-17-openjdk"
        "/usr/lib/jvm/java-17"
        "/usr/lib/jvm/default-java"
    )

    local p
    for p in "${candidates[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -x "$p/bin/java" ]] || continue
        if "$p/bin/java" -version 2>&1 | grep -qE 'version "17(\.|\")'; then
            JAVA_SDK="$(cd "$p" && pwd)"
            return
        fi
    done

    if command -v java >/dev/null 2>&1; then
        local java_bin java_home
        java_bin="$(readlink -f "$(command -v java)")"
        java_home="$(dirname "$(dirname "$java_bin")")"
        if "$java_home/bin/java" -version 2>&1 | grep -qE 'version "17(\.|\")'; then
            JAVA_SDK="$java_home"
            return
        fi
    fi

    die "No JDK 17 found. Install JDK 17 or pass --java-sdk PATH."
}

# ------------------------------ FFmpeg.AutoGen --------------------------------

fetch_ffmpeg_autogen() {
    need_cmd git

    local dest="$REPO/third_party/FFmpeg.AutoGen/upstream"

    if [[ -f "$dest/FFmpeg.cs" ]]; then
        log "FFmpeg.AutoGen upstream/ already present"
        return
    fi

    local commit="40873965266b526eeb7982ad45b1e51957eb5411"
    local repo_url="https://github.com/Ruslan-B/FFmpeg.AutoGen"
    local work

    work="$(mktemp -d)"
    local cleanup_work
    cleanup_work() {
        rm -rf "$work"
    }

    log "Fetching FFmpeg.AutoGen from $repo_url @ $commit..."

    git -C "$work" init -q
    git -C "$work" remote add origin "$repo_url"
    git -C "$work" fetch -q --depth 1 origin "$commit" || { cleanup_work; die "Failed to fetch FFmpeg.AutoGen"; }
    git -C "$work" checkout -q FETCH_HEAD -- FFmpeg.AutoGen || { cleanup_work; die "Failed to checkout FFmpeg.AutoGen"; }

    rm -rf "$dest"
    mkdir -p "$dest"
    cp -R "$work/FFmpeg.AutoGen/." "$dest/" || { cleanup_work; die "Failed to copy FFmpeg.AutoGen"; }
    rm -f "$dest/FFmpeg.AutoGen.csproj"

    log "Applying iOS Darwin fallback patch..."
    patch -p1 -d "$dest" < "$REPO/third_party/FFmpeg.AutoGen/ios-darwin-fallback.patch" || { cleanup_work; die "Failed to apply iOS patch"; }

    log "Applying Android Bionic fallback patch..."
    patch -p1 -d "$dest" < "$REPO/third_party/FFmpeg.AutoGen/android-bionic-fallback.patch" || { cleanup_work; die "Failed to apply Android patch"; }

    cleanup_work
    log "FFmpeg.AutoGen fetched and patched -> $dest"
}

# ------------------------------ BASS ----------------------------------------

download_bass() {
    need_cmd curl
    need_cmd unzip

    local tmp="$ROOT/.cache/opentaiko-bass-android"
    mkdir -p "$tmp"

    local packages=(
        "bass24-android|https://www.un4seen.com/files/bass24-android.zip"
        "bassmix24-android|https://www.un4seen.com/files/bassmix24-android.zip"
        "bass_fx24-android|https://www.un4seen.com/files/z/0/bass_fx24-android.zip"
    )
    local abis=("arm64-v8a" "x86_64")

    local entry pkg url zipfile dst abi libdir
    for entry in "${packages[@]}"; do
        pkg="${entry%%|*}"
        url="${entry#*|}"
        zipfile="$tmp/$pkg.zip"
        dst="$tmp/$pkg"

        if [[ ! -f "$zipfile" ]]; then
            log "Downloading $pkg..."
            curl -fL --retry 3 --retry-delay 2 "$url" -o "$zipfile" || die "Failed to download $pkg"
        fi

        rm -rf "$dst"
        mkdir -p "$dst"
        unzip -q "$zipfile" -d "$dst" || die "Failed to extract $zipfile"

        for abi in "${abis[@]}"; do
            libdir="$ROOT/jniLibs/$abi"
            mkdir -p "$libdir"
            if [[ -d "$dst/libs/$abi" ]]; then
                find "$dst/libs/$abi" -type f -name '*.so' -exec cp -f {} "$libdir/" \;
                find "$dst/libs/$abi" -type f -name '*.so' -printf '  %p -> %s\n' 2>/dev/null || true
            else
                warn "No libs/$abi directory in $pkg"
            fi
        done
    done

    log "Done. jniLibs/ now holds the BASS natives."
}

# ------------------------------ FFmpeg natives -------------------------------

download_ffmpeg() {
    need_cmd curl
    need_cmd unzip

    local tmp="$ROOT/.cache/opentaiko-ffmpeg-android"
    mkdir -p "$tmp"

    local version="5.1.2-1.5.8"
    local base="https://repo1.maven.org/maven2/org/bytedeco/ffmpeg/$version"
    local wanted=("libavutil.so" "libswresample.so" "libavcodec.so" "libavformat.so" "libswscale.so")

    local classifiers=("android-arm64|arm64-v8a" "android-x86_64|x86_64")
    local entry classifier abi jar libdir name found

    for entry in "${classifiers[@]}"; do
        classifier="${entry%%|*}"
        abi="${entry#*|}"
        jar="$tmp/ffmpeg-$version-$classifier.jar"

        if [[ ! -f "$jar" ]]; then
            log "Downloading ffmpeg $version $classifier..."
            curl -fL --retry 3 --retry-delay 2 \
                "$base/ffmpeg-$version-$classifier.jar" -o "$jar" || die "Failed to download ffmpeg"
        fi

        libdir="$ROOT/jniLibs/$abi"
        mkdir -p "$libdir"

        local unpack="$tmp/extract-$classifier"
        rm -rf "$unpack"
        mkdir -p "$unpack"
        unzip -q "$jar" -d "$unpack" || die "Failed to extract $jar"

        for name in "${wanted[@]}"; do
            found="$(find "$unpack" -type f -name "$name" -print -quit)"
            [[ -n "$found" ]] || die "$name not found in $jar"
            cp -f "$found" "$libdir/$name"
            log "  $abi/$name"
        done
    done

    log "Done. jniLibs/ now holds the FFmpeg natives."
}

# ------------------------------ icons ----------------------------------------

make_icons() {
    need_cmd python3

    python3 - "$ROOT" "$REPO" <<'PY'
import os
import sys

try:
    from PIL import Image
except ImportError:
    raise SystemExit(
        "Pillow is required. Install it with: python3 -m pip install --user Pillow"
    )

ROOT = os.path.abspath(sys.argv[1])
REPO = os.path.abspath(sys.argv[2])
ICO = os.path.join(REPO, "OpenTaiko", "OpenTaiko.ico")
RES = os.path.join(ROOT, "Resources")

DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

if not os.path.isfile(ICO):
    raise SystemExit(f"Icon source not found: {ICO}")

im = Image.open(ICO)
if getattr(im, "ico", None):
    im = im.ico.getimage(max(im.ico.sizes()))
logo = im.convert("RGBA")

def fit_center(canvas, logo, frac):
    side = canvas.size[0]
    target = int(side * frac)
    ratio = min(target / logo.width, target / logo.height)
    scaled = logo.resize(
        (max(1, int(logo.width * ratio)),
        max(1, int(logo.height * ratio))),
        Image.Resampling.LANCZOS
    )
    pos = ((side - scaled.width) // 2, (side - scaled.height) // 2)
    canvas.alpha_composite(scaled, pos)
    return canvas

for density, (legacy_px, fg_px) in DENSITIES.items():
    outdir = os.path.join(RES, f"mipmap-{density}")
    os.makedirs(outdir, exist_ok=True)

    legacy = fit_center(
        Image.new("RGBA", (legacy_px, legacy_px), (255, 255, 255, 255)),
        logo, 0.80
    )
    legacy.convert("RGB").save(os.path.join(outdir, "ic_launcher.png"))

    fg = fit_center(
        Image.new("RGBA", (fg_px, fg_px), (0, 0, 0, 0)),
        logo, 0.58
    )
    fg.save(os.path.join(outdir, "ic_launcher_foreground.png"))

print("icons written under", RES)
PY
}

# ------------------------------ songs ZIP ------------------------------------

make_songs_zip() {
    local source="$1"
    local destination="$2"

    [[ -d "$source" ]] || die "Song source folder not found: $source"

    source="$(cd "$source" && pwd)"
    mkdir -p "$(dirname "$destination")"
    rm -f "$destination"

    need_cmd python3
    python3 - "$source" "$destination" <<'PY'
import os
import sys
import zipfile

source = os.path.abspath(sys.argv[1])
destination = os.path.abspath(sys.argv[2])
junk = {"thumbs.db", "desktop.ini"}
count = 0

with zipfile.ZipFile(
    destination,
    "w",
    compression=zipfile.ZIP_DEFLATED,
    compresslevel=1,
) as z:
    for root, dirs, files in os.walk(source):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.lower() in junk:
                continue
            if name.startswith("."):
                continue

            full = os.path.join(root, name)
            rel = os.path.relpath(full, source).replace(os.sep, "/")
            if any(part.startswith(".") for part in rel.split("/")):
                continue
            z.write(full, rel)
            count += 1

print(f"make-songs-zip: {count} files -> {destination}")
if count == 0:
    try:
        os.unlink(destination)
    except FileNotFoundError:
        pass
    raise SystemExit("no files matched under " + source)
PY
}

# ------------------------------ main build -----------------------------------

check_android_workload() {
    need_cmd dotnet
    if ! dotnet workload list 2>/dev/null | grep -qE '^[[:space:]]*android([[:space:]]|$)'; then
        die "The .NET Android workload is not installed. Run: dotnet workload install android"
    fi
}

check_prerequisites() {
    local bass="$ROOT/jniLibs/arm64-v8a/libbass.so"
    local ffmpeg="$ROOT/jniLibs/arm64-v8a/libavcodec.so"
    local autogen="$REPO/third_party/FFmpeg.AutoGen/upstream/FFmpeg.cs"

    if [[ ! -f "$bass" ]]; then
        log "BASS natives missing -> downloading"
        download_bass
    fi

    if [[ ! -f "$ffmpeg" ]]; then
        log "FFmpeg natives missing -> downloading"
        download_ffmpeg
    fi

    if [[ ! -f "$autogen" ]]; then
        log "FFmpeg.AutoGen upstream source missing -> fetching"
        fetch_ffmpeg_autogen
    fi
}

clean_build() {
    if ((CLEAN)); then
        rm -rf "$ROOT/obj" "$ROOT/bin"
        log "Cleaned $ROOT/obj and $ROOT/bin"
    fi
}

build_app() {
    local -a args=(
        build "$CSPROJ"
        -f net8.0-android
        -c "$CONFIG"
        -p:UseVendoredFFmpeg=true
        "-p:AndroidSdkDirectory=$ANDROID_SDK"
        "-p:JavaSdkDirectory=$JAVA_SDK"
    )

    if [[ "$CONFIG" == "Release" ]]; then
        args+=("-p:Optimize=false")
    fi

    if ((BUNDLE_SONGS)); then
        resolve_songs_path

        local bytes
        bytes="$(python3 - "$SONGS_ABS" <<'PY'
import os, sys
root = os.path.abspath(sys.argv[1])
total = 0
for base, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if not d.startswith(".")]
    for f in files:
        if f.lower() in {"thumbs.db", "desktop.ini"}:
            pass
        p = os.path.join(base, f)
        rel = os.path.relpath(p, root)
        if any(part.startswith(".") for part in rel.split(os.sep)):
            continue
        try:
            total += os.path.getsize(p)
        except OSError:
            pass
print(total)
PY
)"
        if ((bytes > 1800 * 1000 * 1000)); then
            die "Songs folder is too large to bundle (~>2 GB). Use --push-songs or point --songs-path at a smaller folder."
        fi

        log "Bundling songs: $SONGS_ABS ($(awk -v b="$bytes" 'BEGIN {printf "%.0f MB", b/1000000}'))"
        args+=("-p:BundleSongs=true" "-p:BundleSongsPath=$SONGS_ABS")
    fi

    ((INSTALL)) && args+=("-t:Install")

    log "Android SDK : $ANDROID_SDK"
    log "JDK         : $JAVA_SDK"
    log "Config      : $CONFIG"

    (
        export ANDROID_HOME="$ANDROID_SDK"
        export ANDROID_SDK_ROOT="$ANDROID_SDK"
        export JAVA_HOME="$JAVA_SDK"
        export PATH="$JAVA_SDK/bin:$ANDROID_SDK/platform-tools:$PATH"
        dotnet "${args[@]}"
    )

    local apk
    apk="$(find "$ROOT/bin/$CONFIG/net8.0-android" -type f -name '*-Signed.apk' -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | head -n1 | cut -d' ' -f2- || true)"

    if [[ -n "$apk" ]]; then
        local size
        size="$(du -h "$apk" | cut -f1)"
        log "APK: $apk ($size)"
    fi
}

push_songs() {
    resolve_songs_path
    local adb="$ANDROID_SDK/platform-tools/adb"
    [[ -x "$adb" ]] || die "adb not found under Android SDK platform-tools."

    local dst="/storage/emulated/0/Android/data/com.opentaiko.OpenTaiko/files/Songs/"
    log "Pushing songs from $SONGS_ABS (existing files are overwritten by adb)..."

    local item
    while IFS= read -r -d '' item; do
        "$adb" push "$item" "$dst" ||
            die "adb push failed on '$(basename "$item")' - is a device connected? On Android 11+ some devices block shell writes to Android/data."
    done < <(find "$SONGS_ABS" -mindepth 1 -maxdepth 1 ! -name '.*' -print0)
}

run_app() {
    local adb="$ANDROID_SDK/platform-tools/adb"
    [[ -x "$adb" ]] || die "adb not found under Android SDK platform-tools."

    log "Launching com.opentaiko.OpenTaiko..."
    "$adb" shell monkey -p com.opentaiko.OpenTaiko -c android.intent.category.LAUNCHER 1 >/dev/null
    log "Logs: adb logcat -s OpenTaiko AndroidRuntime mono-stdout"
}

# ------------------------------ action dispatch -------------------------------

if [[ -n "${MAKE_SONGS_ZIP_SRC:-}" ]]; then
    make_songs_zip "$MAKE_SONGS_ZIP_SRC" "$MAKE_SONGS_ZIP_DST"
    exit 0
fi

if ((MAKE_ICONS)); then
    make_icons
fi

if ((DOWNLOAD_BASS)); then
    download_bass
fi

if ((DOWNLOAD_FFMPEG)); then
    download_ffmpeg
fi

if ((FETCH_FFMPEG_AUTOGEN)); then
    fetch_ffmpeg_autogen
fi

# Action-only invocations do not need a full Android SDK/build.
if ((MAKE_ICONS || DOWNLOAD_BASS || DOWNLOAD_FFMPEG || FETCH_FFMPEG_AUTOGEN)) &&
   ((INSTALL == 0 && RUN_APP == 0 && CLEAN == 0 && BUNDLE_SONGS == 0 && PUSH_SONGS == 0)) &&
   [[ "$CONFIG" == "Debug" ]]; then
    exit 0
fi

# Normal build path.
check_android_workload
find_android_sdk
find_java_sdk
check_prerequisites
clean_build
build_app

if ((PUSH_SONGS)); then
    push_songs
fi

if ((RUN_APP)); then
    run_app
fi
