#!/bin/bash
# =============================================================================
# 构建域外 Mesa Extension（ARM64）：wayland / libxcb / libdrm / llvm-19 / Mesa
#
# 说明：
#   构建容器里 /opt/extensions/org.deepin.driver.mesa 就是 linglong/output/_build，
#   而 /project 会随 linglong/ 目录保留，所以源码和构建目录都能复用。
#   玲珑 base 的 ARM64 triplet 为 aarch64-linux-gnu
#   （与 org.deepin.base 25.2.2.3 的 build.bash 中 arm64 映射一致）。
#
# 设计：
#   1. 依赖全部前置安装，构建阶段不再碰 apt
#   2. 每个组件一个 build_xxx()，配置/编译/安装走统一驱动
#   3. 用「源码 commit + 配置参数」算签名做 stamp：
#      签名没变就跳过 meson setup，只跑增量 ninja
#   4. 产物统一做 SONAME 私有化，摆脱对 LD_LIBRARY_PATH / LD_PRELOAD 的依赖
# =============================================================================
set -euo pipefail

# ============================== 全局配置 ====================================

: "${EXTROOT:=/opt/extensions/org.deepin.driver.mesa}"
: "${TRIPLET:=aarch64-linux-gnu}"
: "${SRC_DIR:=source}"
: "${STATE_DIR:=${SRC_DIR}/.state}"
# Mesa 的额外补丁（相对当前工程目录，可被环境变量覆盖）
: "${MESA_PATCH:=0001-x11-copy-cross-GPU-pixmaps-on-Xwayland.patch}"
# 改名头要通过 -include 传给 configure/meson，必须用绝对路径
STATE_DIR=$(realpath -m "${STATE_DIR}")

# 需要从镜像里搬进扩展的运行库（base 缺失或版本过旧）
RUNTIME_MESA_LIBS=(
    libdisplay-info.so.1
)
RUNTIME_LLVM_LIBS=(
    libLLVM.so.19.1
    libclang-cpp.so.19.1
    libLLVMSPIRVLib.so.19.1
)

WAYLAND_PREFIX="${EXTROOT}/wayland"
LIBXCB_PREFIX="${EXTROOT}/libxcb"
LIBDRM_PREFIX="${EXTROOT}/libdrm"
MESA_PREFIX="${EXTROOT}/mesa"
LLVM_PREFIX="${EXTROOT}/llvm-19"

PC_PATH="${LIBDRM_PREFIX}/lib/${TRIPLET}/pkgconfig"
PC_PATH="${PC_PATH}:${LIBXCB_PREFIX}/lib/${TRIPLET}/pkgconfig"
PC_PATH="${PC_PATH}:${WAYLAND_PREFIX}/lib/${TRIPLET}/pkgconfig"

# 需要每次拉最新工具链时置 1；置 0 可以省掉网络往返
: "${UPGRADE_MESON:=1}"
: "${UPDATE_RUST:=0}"
: "${UPGRADE_CARGO_TOOLS:=0}"

# ============================ 依赖清单（硬编码）=============================
#
# 不再用 apt build-dep：它会把 base 自带的 llvm-17 系列重新装回来，
# 而 llvm-17 与 llvm-19 抢同一批 .pc（LLVMSPIRVLib.pc / libclc.pc），
# 每轮都要「装 17 → 卸 17 → 装 19」，既慢又容易踩到冲突。
#
# 清单来源：
#   deepin-community/{mesa,libdrm,libxcb,wayland} 的 debian/control（master）
# 在此基础上做了三处调整：
#   1. llvm-17 / libclang-17 / libclang-cpp17 / libclc-17 → 全部换成 19 系列
#   2. 去掉 rustc（用 rustup 的 stable）、debhelper / quilt（不做 deb 打包）
#   3. 补上 Mesa 27 需要但 24.3 清单里没有的：libdisplay-info-dev、libudev-dev、
#      libllvmspirvlib-19-dev、llvm-spirv-19、patchelf
#
# libdrm-dev 不装（base 自带，且我们自己编的 libdrm 通过 pkg-config 优先）；
# libwayland-dev 保留，因为它的 -dev 元包会带上一些 Mesa 需要的 wayland 工具。

# base 镜像里没有 git / wget / make / gcc / pkg-config / ninja / meson，
# 所以这些必须在 clone 源码之前装好，否则干净构建第一步就挂。
DEPS_BOOTSTRAP=(
    git curl wget ca-certificates xz-utils
    build-essential
    pkgconf
    gcc-13 g++-13
    ninja-build patchelf
)

DEP_WAYLAND=(
    pkgconf
    libexpat1-dev libffi-dev libxml2-dev
)

DEP_LIBDRM=(
    pkgconf
    libpciaccess-dev libudev-dev libx11-dev
    python3-docutils python3-setuptools
)

DEP_LIBXCB=(
    pkgconf
    libxau-dev libxdmcp-dev libpthread-stubs0-dev
    xcb-proto xutils-dev xsltproc check
    python3 python3-xcbgen
    libtool automake
)

DEP_MESA=(
    # 构建系统与代码生成
    pkgconf flex bison
    python3 python3-mako python3-ply python3-yaml python3-pycparser python3-setuptools
    # 底座与 X11 / XCB
    linux-libc-dev x11proto-dev
    libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev libxxf86vm-dev libxrandr-dev
    libxcb-dri2-0-dev libxcb-dri3-dev libxcb-glx0-dev libxcb-present-dev
    libxcb-randr0-dev libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev
    libxshmfence-dev
    # wayland / glvnd / 图形后端
    libwayland-dev libwayland-egl-backend-dev wayland-protocols
    libglvnd-core-dev
    # libgbm-dev 只提供 gbm.pc / gbm.h，让 Mesa 直接链 base 的 libgbm 来编
    libgbm-dev
    libexpat1-dev libzstd-dev zlib1g-dev
    libelf-dev libudev-dev libdisplay-info-dev
    # 音视频与传感器
    libva-dev libvdpau-dev libsensors-dev
    # Vulkan / D3D12
    libvulkan-dev directx-headers-dev
    # 着色器与调试
    glslang-tools valgrind
    # LLVM 19 全家桶（clc / rusticl / 软渲染共用）
    clang-19 llvm-19 llvm-19-dev
    libclang-19-dev libclang-cpp19-dev
    libclc-19 libclc-19-dev
    libllvmspirvlib-19-dev llvm-spirv-19
)

# base 自带、会和 llvm-19 抢 .pc 的旧包
CONFLICT_PKGS=(
    llvm-17 llvm-17-dev llvm-17-runtime llvm-17-tools llvm-17-linker-tools
    libllvmspirvlib-17 libllvmspirvlib-17-dev
    libclc-17 libclc-17-dev
    llvm-spirv-17
)

# 旧脚本往 sources.list 里加过的 deb-src 行，现在已经用不到，顺手清掉
LEGACY_APT_REPO_LINE='deb-src [trusted=yes] https://ci.deepin.com/repo/deepin/deepin-community/stable crimson/2510 main community commercial'

# 在 base 25.2.2 里与系统库重名、需要私有化的 SONAME 映射
declare -A SONAME_MAP=(
    [libwayland-client.so.0]=libwayland-client-ext.so.0
    [libwayland-server.so.0]=libwayland-server-ext.so.0
    [libxcb-dri3.so.0]=libxcb-dri3-ext.so.0
    [libxcb-present.so.0]=libxcb-present-ext.so.0
    [libdrm.so.2]=libdrm-ext.so.2
    [libdrm_amdgpu.so.1]=libdrm_amdgpu-ext.so.1
    [libdrm_intel.so.1]=libdrm_intel-ext.so.1
    [libdrm_radeon.so.1]=libdrm_radeon-ext.so.1
    [libdrm_nouveau.so.2]=libdrm_nouveau-ext.so.2
)

# libgbm 刻意不在名单里：gbm_device / gbm_bo 是 Mesa 私有的不透明结构体，
# 应用（Chromium 这类）用的是 base 的 libgbm 创建的对象，再交给我们的 EGL。
# 两个 Mesa 版本对同一块内存的结构体布局不一致，接管过来就是空指针调用。
# 让 base 的 libgbm 统一管理，跨版本边界只落在 dmabuf fd 上，这才是安全的。
# 因此扩展不投递 libgbm.so.1 和 gbm/dri_gbm.so，Mesa 直接链 base 那份。
#
# 这些库刻意由 base 提供，扩展不投递。放这里等于显式声明「允许落到 base」。
SHARED_WITH_BASE=(
    libgbm.so.1
)

# 被私有化的库，其导出符号也统一加前缀。
#
# 只换 SONAME 是不够的：base 和扩展仍然导出同名符号（wl_* / xcb_dri3_* /
# drm* / gbm_* / amdgpu_* …）。只要 base 那份进了进程的全局作用域并排在
# 查找顺序前面，动态链接器就会用它来满足我们 Mesa 的引用，于是同一份
# 数据结构被两个不同版本的实现解释：轻则功能异常，重则整个进程崩掉。
# 这条规律跟硬件厂商无关，凡是 base 也提供的库都会中招。
#
# 做法：把这些库的导出符号在编译期整体改名（定义和引用一起改），
# 两边的符号名彻底不相交，谁先加载都无所谓。
# 前缀固定为 ll_ext_（linglong extension），一眼能看出符号来自这个扩展。
# 具体实现见 symbol_header_* / build_*_component 里的 EXTRA_CFLAGS。
SYMBOL_PREFIX='ll_ext_'

EXTRA_CFLAGS=''

# ================================ 日志 ======================================

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() {
    printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2
    exit 1
}
section() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

declare -A STAGE_SECONDS=()
STAGE_ORDER=()
stage() {
    local name=$1
    shift
    section "${name}"
    local start=${SECONDS}
    "$@"
    STAGE_SECONDS[${name}]=$((SECONDS - start))
    STAGE_ORDER+=("${name}")
}

report_timings() {
    section '耗时统计'
    local name
    for name in "${STAGE_ORDER[@]}"; do
        printf '  %s: %ss\n' "${name}" "${STAGE_SECONDS[${name}]}"
    done
    printf '  %s: %ss\n' '总计' "${SECONDS}"
}

# ================================ 小工具 ====================================

have() { command -v "$1" >/dev/null 2>&1; }

apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# version_ge A B  ->  A >= B ?
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ============================ 依赖：apt 相关 ================================

# apt 是这套脚本唯一的硬前提（base 镜像里可能没有 apt，需要容器环境提供）
require_apt() {
    have apt-get || die "容器内没有 apt-get，无法安装构建依赖。
请确认 ll-builder 使用的是带 apt 的 base，或在 linglong.yaml 里用 buildext.apt.buildDepends 预装。"
    have dpkg-query || die '容器内没有 dpkg-query，无法判断包是否已安装'
    log "apt: $(apt-get --version 2>/dev/null | head -n1)"
}

APT_LISTS_STAMP=/var/cache/apt/.linglong-mesa-build.stamp

# 老版本脚本加过 deb-src 源，现在不再需要，清掉能省一半索引体积
cleanup_apt_sources() {
    local f=/etc/apt/sources.list
    [ -f "${f}" ] || return 0
    local before after
    before=$(sha256sum "${f}" | cut -d' ' -f1)

    # 去重、去空行，再删掉不再需要的 deb-src 行
    awk -v drop="${LEGACY_APT_REPO_LINE}" '
        NF && !seen[$0]++ && $0 != drop
    ' "${f}" >"${f}.new"
    mv "${f}.new" "${f}"

    after=$(sha256sum "${f}" | cut -d' ' -f1)
    if [ "${before}" != "${after}" ]; then
        log 'apt 源已清理'
        rm -f "${APT_LISTS_STAMP}"
    else
        log 'apt 源无变化'
    fi
}

# 索引 1 小时内就不重复 update，省掉每次构建的网络往返
apt_refresh() {
    # 索引目录被清空过（例如全新容器）就必须重新 update
    local lists_ok=0
    if [ -d /var/lib/apt/lists ] && [ -n "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]; then
        lists_ok=1
    fi
    if [ "${lists_ok}" = 1 ] && [ -f "${APT_LISTS_STAMP}" ] \
        && [ -z "$(find "${APT_LISTS_STAMP}" -mmin +60 2>/dev/null)" ]; then
        log 'apt 索引较新，跳过 update'
        return 0
    fi
    log 'apt update'
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    mkdir -p "$(dirname "${APT_LISTS_STAMP}")"
    touch "${APT_LISTS_STAMP}"
}

# apt_purge <pkg>...  只卸载已安装的；不做 autoremove，避免误删 ninja / meson
apt_purge() {
    local p
    local installed=()
    for p in "$@"; do
        apt_installed "${p}" && installed+=("${p}")
    done
    if [ ${#installed[@]} -eq 0 ]; then
        log 'apt: 无需卸载'
        return 0
    fi
    log "apt: 卸载 ${installed[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" \
        || warn "卸载 ${installed[*]} 部分失败，继续"
}

# apt_install <pkg>...  只装缺失的，已装则完全不调用 apt-get
apt_install() {
    local p
    local missing=()
    declare -A seen=()
    for p in "$@"; do
        apt_installed "${p}" && continue
        [ -n "${seen[${p}]:-}" ] && continue
        seen[${p}]=1
        missing+=("${p}")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        log 'apt: 依赖已满足'
        return 0
    fi
    log "apt: 安装 ${#missing[@]} 个包: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# llvm-19 / libclc-19 / libllvmspirvlib-19 是否已经装上。
# 这组包和 base 自带的 17 系列互斥（抢同名 .pc），只用来决定要不要先 purge。
llvm19_installed() {
    local p
    for p in clang-19 llvm-19 libclang-19-dev libclang-cpp19-dev \
        libclc-19 libclc-19-dev libllvmspirvlib-19-dev; do
        apt_installed "${p}" || return 1
    done
    return 0
}

# ====================== 依赖：工具链（python / rust）=======================

setup_python_toolchain() {
    apt_install python3 python3-pip python3-pycparser python3-setuptools

    if [ "${UPGRADE_MESON}" = 1 ] || ! have meson; then
        log 'pip: 安装/升级 meson'
        pip3 install --break-system-packages --upgrade meson
    fi

    # mesa 生成的 ninja 规则里写死了 /bin/meson，所以必须让它指向 pip 那一份。
    # 先修历史遗留的自指软链：指向自己会报 "Too many levels of symbolic links"。
    if [ -L /usr/bin/meson ] && [ ! -e /usr/bin/meson ]; then
        rm -f /usr/bin/meson
    fi

    local target=/usr/local/bin/meson
    if [ ! -x "${target}" ]; then
        target=$(readlink -f "$(command -v meson 2>/dev/null || true)" 2>/dev/null || true)
    fi
    [ -x "${target}" ] || die 'meson 装完却找不到可执行文件'
    [ "$(readlink -f /usr/bin/meson 2>/dev/null)" = "${target}" ] || ln -sfn "${target}" /usr/bin/meson

    log "meson: $(meson --version) (${target})"
}

setup_rust_toolchain() {
    # rustup 的 shim 必须排在最前，才能压过 apt 里的旧 rustc
    case ":${PATH}:" in
        *:/root/.cargo/bin:*) ;;
        *) export PATH="/root/.cargo/bin:${PATH}" ;;
    esac

    if have rustup; then
        if [ "${UPDATE_RUST}" = 1 ]; then
            log 'rustup: 更新 stable'
            rustup update stable
        fi
        rustup show active-toolchain >/dev/null 2>&1 \
            || rustup toolchain install stable --profile minimal
    else
        log 'rustup: 首次安装 stable'
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
        export PATH="/root/.cargo/bin:${PATH}"
    fi
    log "rustc: $(rustc --version)"

    cargo_tool cbindgen cbindgen 0.28
    cargo_tool bindgen bindgen-cli ''
}

# cargo_tool <binary> <crate> <min-version>
cargo_tool() {
    local bin=$1 crate=$2 min=$3
    local need_install=0 cur

    if ! have "${bin}"; then
        need_install=1
    elif [ "${UPGRADE_CARGO_TOOLS}" = 1 ]; then
        need_install=1
    elif [ -n "${min}" ]; then
        cur=$("${bin}" --version 2>/dev/null | awk '{print $2}')
        if ! version_ge "${cur:-0}" "${min}"; then
            log "${bin}: ${cur:-unknown} < ${min}，需要升级"
            need_install=1
        fi
    fi

    if [ "${need_install}" = 1 ]; then
        log "cargo: 安装 ${crate}"
        cargo install --locked "${crate}"
    fi
    log "${bin}: $("${bin}" --version 2>/dev/null | head -n1)"
}

# =============================== 源码获取 ==================================

fetch_repo() {
    local name=$1 url=$2 branch=$3
    local dir="${SRC_DIR}/${name}"

    if [ ! -d "${dir}/.git" ]; then
        log "${name}: clone ${url} (${branch})"
        git clone -b "${branch}" --depth 1 "${url}" "${dir}"
        return 0
    fi

    local current_url current_branch remote_changed=0 branch_changed=0
    current_url=$(git -C "${dir}" remote get-url origin 2>/dev/null || true)
    current_branch=$(git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    if [ "${current_url}" != "${url}" ]; then
        log "${name}: origin ${current_url:-<none>} -> ${url}"
        git -C "${dir}" remote set-url origin "${url}"
        remote_changed=1
    fi
    if [ "${current_branch}" != "${branch}" ]; then
        branch_changed=1
    fi

    local before after
    before=$(git -C "${dir}" rev-parse HEAD)
    if ! git -C "${dir}" fetch --depth 1 origin "${branch}" >/dev/null 2>&1; then
        # 源/分支已经变化却 fetch 失败时，不能悄悄回退到旧代码
        if [ "${remote_changed}" = 1 ] || [ "${branch_changed}" = 1 ]; then
            die "${name}: 源或分支已变化，但 fetch ${branch} 失败；不能继续使用旧代码"
        fi
        warn "${name}: fetch 失败，使用本地代码 ${before:0:8}"
        return 0
    fi
    after=$(git -C "${dir}" rev-parse FETCH_HEAD)
    if [ "${before}" = "${after}" ]; then
        log "${name}: 已是最新 ${before:0:8}"
    else
        log "${name}: ${before:0:8} -> ${after:0:8}"
    fi

    # 切换源/分支时清掉旧 fork 的 subprojects，避免旧版本被新源码误用。
    if [ "${remote_changed}" = 1 ] || [ "${branch_changed}" = 1 ]; then
        rm -rf "${dir}/subprojects"
    fi

    # 强制回到目标分支/commit，清掉上一轮补丁 / autoreconf 的残留。
    # build 和已下载的 subprojects 默认保留；源码分支本身始终与远端一致。
    git -C "${dir}" checkout -f -B "${branch}" FETCH_HEAD >/dev/null 2>&1
    git -C "${dir}" clean -xdfq -e build -e subprojects
}

head_commit() { git -C "$1" rev-parse HEAD; }

apply_debian_patches() {
    local dir=$1
    if git -C "${dir}" apply --check debian/patches/*.patch >/dev/null 2>&1; then
        log '应用 deepin 打包补丁'
        git -C "${dir}" apply debian/patches/*.patch
    else
        log '打包补丁已应用或不存在，跳过'
    fi
}

# apply_source_patch <dir> <patch>
# 应用工程自带的额外补丁；失败必须中止，不能悄悄编一个没打补丁的源码树。
apply_source_patch() {
    local dir=$1 patch=$2 abs
    [ -f "${patch}" ] || die "找不到补丁: ${patch}"
    abs=$(realpath "${patch}")

    if git -C "${dir}" apply --check "${abs}" >/dev/null 2>&1; then
        log "应用补丁 $(basename "${abs}")"
        git -C "${dir}" apply "${abs}"
    elif git -C "${dir}" apply --reverse --check "${abs}" >/dev/null 2>&1; then
        log "补丁已应用: $(basename "${abs}")"
    else
        die "补丁无法应用: ${abs}"
    fi
}

# ============================== 构建驱动 ===================================

# ========================= 符号隔离（通用） ================================
#
# 一个被私有化 SONAME 的库，符号名仍然和 base 那份相同，就还是会被顶替。
# 这里用「编译期改名头」解决：把该库所有导出符号 #define 成带前缀的名字，
# 然后用 -include 塞进它自己和 Mesa 的每一个翻译单元。定义和引用一起改名，
# 二进制层面不再有任何同名符号。
#
# 不碰任何上游源码，只加编译参数。

symbol_cache_file() { printf '%s/%s.symbols' "${STATE_DIR}" "$1"; }

# symbol_cache_load <name> <commit>  -> 命中则输出符号清单
symbol_cache_load() {
    local f
    f=$(symbol_cache_file "$1")
    [ -f "${f}" ] || return 1
    [ "$(sed -n 1p "${f}")" = "$2" ] || return 1
    sed -n '2,$p' "${f}"
}

# symbol_cache_save <name> <commit>（符号清单走标准输入）
symbol_cache_save() {
    local f tmp
    f=$(symbol_cache_file "$1")
    mkdir -p "${STATE_DIR}"
    tmp="${f}.tmp"
    { printf '%s\n' "$2"; cat; } >"${tmp}" && mv -f "${tmp}" "${f}"
}

symbol_header_path() { printf '%s/symrename-%s.h' "${STATE_DIR}" "$1"; }

# 采集目录下「属于 SONAME_MAP」的共享库的导出符号。
# 刻意只取被私有化的那几个：像 libxcb.so.1、libwayland-egl.so.1 是我们主动
# 和 base 共享的，它们的符号名一旦改掉，运行时就没有提供者了。
collect_exported_symbols() {
    local d=$1 f soname n hit
    local -a wanted=("${!SONAME_MAP[@]}")

    find "${d}" -type f -name '*.so.*' -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            soname=$(readelf -d "${f}" 2>/dev/null \
                | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
            [ -n "${soname}" ] || soname=$(basename "${f}")
            hit=0
            for n in "${wanted[@]}"; do
                if [ "${n}" = "${soname}" ]; then
                    hit=1
                    break
                fi
            done
            [ "${hit}" -eq 1 ] || continue
            nm -D --defined-only --format=posix "${f}" 2>/dev/null \
                | awk '$2 ~ /^[TDBRVWi]$/ {print $1}'
        done | sed 's/@.*//' | sort -u
}

# symbol_header_write <name>（符号清单走标准输入）-> 写出改名头
symbol_header_write() {
    local name=$1 guard header
    guard="LINGLONG_SYMRENAME_$(printf '%s' "${name}" | tr 'a-z-' 'A-Z_')"
    header=$(symbol_header_path "${name}")
    mkdir -p "${STATE_DIR}"
    {
        printf '/* 由 build-and-install.sh 生成：给 %s 的导出符号统一加前缀 */\n' "${name}"
        printf '#ifndef %s\n#define %s\n' "${guard}" "${guard}"
        awk -v p="${SYMBOL_PREFIX}" 'NF { printf "#define %s %s%s\n", $0, p, $0 }'
        printf '#endif\n'
    } >"${header}"
}

component_signature() {
    local commit=$1
    shift
    printf '%s\0%s\n' "${commit}" "$*" | sha256sum | cut -d' ' -f1 | cut -c1-16
}

stamp_file() { printf '%s/%s.stamp' "${STATE_DIR}" "$1"; }

stamp_matches() {
    local f
    f=$(stamp_file "$1")
    [ -f "${f}" ] && [ "$(cat "${f}")" = "$2" ]
}

stamp_write() {
    mkdir -p "${STATE_DIR}"
    printf '%s\n' "$2" >"$(stamp_file "$1")"
}

# 给一个组件开启符号隔离。
#
#   isolate_prepare <name> <commit>      产出/复用导出符号清单
#   isolate_flags   <name>               把清单转成 -include 参数写入 EXTRA_CFLAGS
#
# 首次构建时清单还不存在，调用方需要先做一轮普通编译，再把采集结果喂给
# isolate_cache_store；之后每次构建都直接用缓存，不用重复编译。
isolate_symbols_load() {
    symbol_cache_load "$1" "$2"
}

isolate_symbols_store() {
    symbol_cache_save "$1" "$2"
}

# isolate_flags <name...>：为每个组件的符号头生成 -include，累加到 EXTRA_CFLAGS
isolate_flags() {
    local name header
    for name in "$@"; do
        header="${STATE_DIR}/symrename-${name}.h"
        if [ -f "${header}" ]; then
            EXTRA_CFLAGS="${EXTRA_CFLAGS} -include ${header}"
        fi
    done
}

# build_meson_component <name> <srcdir> <commit> <meson args...>
build_meson_component() {
    local name=$1 dir=$2 commit=$3
    shift 3
    dir=$(realpath "${dir}")
    local sig builddir="${dir}/build" extra="${EXTRA_CFLAGS}"
    sig=$(component_signature "${commit}" "${SYMBOL_PREFIX}" "${extra}" "$@")

    if stamp_matches "${name}" "${sig}" && [ -f "${builddir}/meson-private/coredata.dat" ]; then
        log "${name}: 配置未变化，跳过 meson setup"
    else
        # meson 只在 setup 时读 CFLAGS/CXXFLAGS，而 --reconfigure 不会重新读环境变量，
        # 所以参数一变就整个重新 setup。参数变化本来也会让 ninja 全量重编，
        # 多出来的只是一次 setup 的时间。
        log "${name}: meson setup"
        rm -rf "${builddir}"
        # 必须显式给源码目录，否则 meson 会把 builddir 当成源码目录
        CFLAGS="${extra}" CXXFLAGS="${extra}" \
            meson setup "${builddir}" "${dir}" "$@"
        stamp_write "${name}" "${sig}"
    fi

    log "${name}: 编译"
    meson compile -C "${builddir}"
    log "${name}: 安装"
    meson install -C "${builddir}"
}

# build_autotools_component <name> <srcdir> <commit> <prefix> <libdir> <configure args...>
build_autotools_component() {
    local name=$1 dir=$2 commit=$3 prefix=$4 libdir=$5
    shift 5
    dir=$(realpath "${dir}")
    local sig builddir="${dir}/build" extra="${EXTRA_CFLAGS}"
    sig=$(component_signature "${commit}" "${prefix}" "${libdir}" "${SYMBOL_PREFIX}" "${extra}" "$@")

    if ! stamp_matches "${name}" "${sig}"; then
        log "${name}: autoreconf -fiv"
        (cd "${dir}" && autoreconf -fiv)
        rm -rf "${builddir}"
        stamp_write "${name}" "${sig}"
    fi

    mkdir -p "${builddir}"
    if [ ! -f "${builddir}/Makefile" ]; then
        log "${name}: configure"
        (cd "${builddir}" && CFLAGS="${extra}" CXXFLAGS="${extra}" \
            "${dir}/configure" --prefix="${prefix}" --libdir="${libdir}" "$@")
    else
        log "${name}: 复用已有 Makefile"
    fi

    log "${name}: 编译"
    make -j"$(nproc)" -C "${builddir}"
    log "${name}: 安装"
    make -C "${builddir}" install
}

# ================================ 组件 =====================================

build_wayland() {
    local dir="${SRC_DIR}/wayland" commit syms
    apply_debian_patches "${dir}"
    commit=$(head_commit "${dir}")

    local -a args=(
        --prefix="${WAYLAND_PREFIX}"
        --libdir="lib/${TRIPLET}"
        --buildtype=release
        -Ddocumentation=false
        -Dtests=false
        -Ddtd_validation=false
    )

    EXTRA_CFLAGS=''
    if syms=$(symbol_cache_load wayland "${commit}"); then
        log "wayland: 复用已记录的导出符号（$(printf '%s\n' "${syms}" | wc -l) 个）"
    else
        log 'wayland: 首轮编译以采集导出符号'
        build_meson_component wayland "${dir}" "${commit}" "${args[@]}"
        syms=$(collect_exported_symbols "${WAYLAND_PREFIX}")
        printf '%s\n' "${syms}" | symbol_cache_save wayland "${commit}"
    fi
    symbol_header_write wayland <<<"${syms}"

    EXTRA_CFLAGS="-include $(symbol_header_path wayland)"
    build_meson_component wayland "${dir}" "${commit}" "${args[@]}"
}

build_libxcb() {
    local dir="${SRC_DIR}/libxcb" commit syms
    commit=$(head_commit "${dir}")

    local -a args=(
        --enable-dbe=no
        --disable-silent-rules
        PYTHON=python3
    )

    EXTRA_CFLAGS=''
    if syms=$(symbol_cache_load libxcb "${commit}"); then
        log "libxcb: 复用已记录的导出符号（$(printf '%s\n' "${syms}" | wc -l) 个）"
    else
        log 'libxcb: 首轮编译以采集导出符号'
        build_autotools_component libxcb "${dir}" "${commit}" \
            "${LIBXCB_PREFIX}" "\${prefix}/lib/${TRIPLET}" "${args[@]}"
        syms=$(collect_exported_symbols "${LIBXCB_PREFIX}")
        printf '%s\n' "${syms}" | symbol_cache_save libxcb "${commit}"
    fi
    symbol_header_write libxcb <<<"${syms}"

    EXTRA_CFLAGS="-include $(symbol_header_path libxcb)"
    build_autotools_component libxcb "${dir}" "${commit}" \
        "${LIBXCB_PREFIX}" "\${prefix}/lib/${TRIPLET}" "${args[@]}"
}

build_libdrm() {
    local dir="${SRC_DIR}/libdrm" commit syms
    commit=$(head_commit "${dir}")

    # libdir 与 libxcb / wayland / mesa 统一，pkg-config、ld.so.conf、RUNPATH 共用一套路径
    local -a args=(
        --prefix="${LIBDRM_PREFIX}"
        --libdir="lib/${TRIPLET}"
        --buildtype=release
        --auto-features=disabled
        -Db_lto=true
        -Ddefault_library=both
        -Dman-pages=enabled
        -Dudev=true
        -Dintel=enabled
        -Dradeon=enabled
        -Damdgpu=enabled
        -Dnouveau=enabled
        -Dvmwgfx=enabled
        # Mesa 的 freedreno/etnaviv/tegra/lima/panfrost 等 ARM 驱动只依赖
        # libdrm 核心 drm* API，不依赖单独的 libdrm_freedreno.so.1。
        # 这里关闭 libdrm_freedreno，避免和 ARM64 base 可能自带的同名
        # libdrm_freedreno.so.1 在 ld cache 里形成两份未私有化的副本。
        -Dfreedreno=disabled
        -Dtests=false
        -Dinstall-test-programs=false
    )

    EXTRA_CFLAGS=''
    if syms=$(symbol_cache_load libdrm "${commit}"); then
        log "libdrm: 复用已记录的导出符号（$(printf '%s\n' "${syms}" | wc -l) 个）"
    else
        log 'libdrm: 首轮编译以采集导出符号'
        build_meson_component libdrm "${dir}" "${commit}" "${args[@]}"
        syms=$(collect_exported_symbols "${LIBDRM_PREFIX}")
        printf '%s\n' "${syms}" | symbol_cache_save libdrm "${commit}"
    fi
    symbol_header_write libdrm <<<"${syms}"

    EXTRA_CFLAGS="-include $(symbol_header_path libdrm)"
    build_meson_component libdrm "${dir}" "${commit}" "${args[@]}"
}

build_mesa() {
    local dir="${SRC_DIR}/mesa"

    # Zink 在 Xwayland 跨 GPU 场景下的性能补丁；必须在上游源码切换后重新应用。
    apply_source_patch "${dir}" "${MESA_PATCH}"

    export CC=gcc-13
    export CXX=g++-13
    export LD=ld

    # Mesa 只通过 pkg-config 找 libdrm / wayland / xcb。
    # 环境变量和 --pkg-config-path 同时给，兼顾不认该参数的子项目。
    export PKG_CONFIG_PATH="${PC_PATH}"

    # $ORIGIN 必须转义，否则会被 Shell 展开成空字符串。
    # $ORIGIN/.. 给 dri/、gbm/ 子目录回上一层找 libgallium / libgbm。
    export LDFLAGS="-Wl,-rpath,\$ORIGIN -Wl,-rpath,\$ORIGIN/.. -Wl,-rpath,${LIBDRM_PREFIX}/lib/${TRIPLET} -Wl,-rpath,${LIBXCB_PREFIX}/lib/${TRIPLET} -Wl,-rpath,${WAYLAND_PREFIX}/lib/${TRIPLET} -Wl,-rpath,${LLVM_PREFIX}"

    # 上游三个组件的导出符号都加了前缀，Mesa 里的引用必须同步改名。
    # libgbm 不参与符号隔离（见 SONAME_MAP 上方的说明）。
    EXTRA_CFLAGS="-include $(symbol_header_path wayland)"
    EXTRA_CFLAGS+=" -include $(symbol_header_path libxcb)"
    EXTRA_CFLAGS+=" -include $(symbol_header_path libdrm)"
    # -Dlibgbm-external=true 时不编 src/gbm，但它没把 src/gbm/main 加进包含路径，
    # 而 src/gbm/backends/dri 仍然要编（要 include gbm_backend_abi.h）。这里补上。
    EXTRA_CFLAGS+=" -I$(realpath "${dir}")/src/gbm/main"

    verify_pkgconfig

    build_meson_component mesa "${dir}" "$(head_commit "${dir}")" \
        --prefix="${MESA_PREFIX}" \
        --libdir="lib/${TRIPLET}" \
        --buildtype=release \
        --pkg-config-path="${PC_PATH}" \
        -Db_ndebug=true \
        -Dglx-direct=true \
        -Dgallium-extra-hud=true \
        -Dgallium-va=enabled \
        -Dgallium-rusticl=true \
        -Dvalgrind=enabled \
        -Dglvnd=enabled \
        -Dlmsensors=enabled \
        -Dgles1=enabled \
        -Dgles2=enabled \
        -Dvideo-codecs=all \
        -Degl=enabled \
        -Dgbm=enabled \
        -Dlibgbm-external=true \
        -Dteflon=true \
        -Dgallium-drivers=iris,d3d12,radeonsi,rocket,zink,nouveau,freedreno,asahi,v3d,vc4,panfrost,crocus,lima,llvmpipe,svga,ethosu,etnaviv,virgl,tegra \
        -Dplatforms=x11,wayland \
        -Dvulkan-drivers=amd,nouveau,freedreno,intel,broadcom,panfrost,microsoft-experimental,swrast,virtio,imagination,kosmickrisp,gfxstream,asahi \
        -Dllvm=enabled \
        -Dshared-llvm=auto \
        -Dlibunwind=disabled \
        -Ddri-drivers-path="${MESA_PREFIX}/lib/${TRIPLET}/dri" \
        -Dgbm-backends-path="${MESA_PREFIX}/lib/${TRIPLET}/gbm" \
        -Dglvnd-vendor-name=mesa-ext

    # 保留 gbm/dri_gbm.so：base 的 libgbm 是 loader，后端由 GBM_BACKENDS_PATH
    # 决定。指向这里之后，应用（Chromium）用的 base loader 会加载我们的 27 后端，
    # 于是 gbm_device 全程由 Mesa 27 创建，base 的 Mesa 24.3 根本不会进进程。
    # 两边的 GBM_BACKEND_ABI_VERSION 都是 1、gbm_device_v0 布局一致，
    # min(loader, backend) 协商后是官方支持的组合。
}

# ============================== 依赖校验 ===================================

verify_toolchain() {
    local missing=()
    local tool
    for tool in gcc-13 g++-13 ld clang-19 llvm-config-19 ninja pkg-config patchelf readelf; do
        have "${tool}" || missing+=("${tool}")
    done
    [ ${#missing[@]} -eq 0 ] || die "缺少工具: ${missing[*]}"

    have cbindgen || die '缺少 cbindgen'
    version_ge "$(cbindgen --version | awk '{print $2}')" 0.28 \
        || die "cbindgen 版本过低，Mesa 需要 >= 0.28"
    have bindgen || die '缺少 bindgen'

    version_ge "$(meson --version)" 1.4 || die "meson 版本过低: $(meson --version)"
    version_ge "$(ninja --version)" 1.8.2 || die "ninja 版本过低: $(ninja --version)"

    log "gcc: $(gcc-13 -dumpversion) / rustc: $(rustc --version | awk '{print $2}')"
    log "llvm: $(llvm-config-19 --version) / meson: $(meson --version) / ninja: $(ninja --version)"
}

# 确保所有 pkg-config 都落在扩展目录内，避免悄悄编到 base 的旧库
verify_pkgconfig() {
    local pkg libdir ver
    for pkg in libdrm libdrm_amdgpu libdrm_intel wayland-client xcb xcb-dri3 xcb-present; do
        libdir=$(PKG_CONFIG_PATH="${PC_PATH}" pkg-config --variable=libdir "${pkg}" 2>/dev/null) \
            || die "pkg-config 找不到 ${pkg}（搜索路径 ${PC_PATH}）"
        case "${libdir}" in
            "${EXTROOT}"/*) ;;
            *) die "pkg-config ${pkg} 解析到 ${libdir}，不在 ${EXTROOT} 内" ;;
        esac
        ver=$(PKG_CONFIG_PATH="${PC_PATH}" pkg-config --modversion "${pkg}")
        log "pkg-config ${pkg} ${ver} -> ${libdir}"
    done

    # Mesa 硬性要求 LLVMSPIRVLib >=19.1,<19.2
    ver=$(pkg-config --modversion LLVMSPIRVLib 2>/dev/null || true)
    case "${ver}" in
        19.*) log "pkg-config LLVMSPIRVLib ${ver}" ;;
        *) die "LLVMSPIRVLib 版本为 '${ver:-未找到}'，Mesa 需要 19.1.x" ;;
    esac
}

# ============================== 产物处理 ===================================

# copy_soname <soname> <destdir>
copy_soname() {
    local soname=$1 dest=$2
    local real
    real=$(ldconfig -p | awk -v n="${soname}" '$1 == n { print $NF; exit }')
    [ -n "${real}" ] || die "镜像里找不到 ${soname}，无法装入扩展"
    mkdir -p "${dest}"
    cp -Lf "${real}" "${dest}/${soname}"
    log "运行库: ${soname} (${real})"
}

# base 只有 llvm-17 和 Mesa 24.3，下面这些 soname base 里要么没有、要么版本过旧，
# 必须在扩展里自带一份，否则 RADV / Rusticl 会在 dlopen 阶段直接失败：
#   libdisplay-info  -> 所有 Vulkan 驱动（含 RADV），base 里完全没有
#   libclang-cpp 19  -> Rusticl OpenCL
#   libLLVMSPIRVLib  -> Rusticl OpenCL
install_runtime_libs() {
    local n
    for n in "${RUNTIME_MESA_LIBS[@]}"; do
        copy_soname "${n}" "${MESA_PREFIX}/lib/${TRIPLET}"
    done
    for n in "${RUNTIME_LLVM_LIBS[@]}"; do
        copy_soname "${n}" "${LLVM_PREFIX}"
    done
}

# 给与 base 重名的依赖库换私有 SONAME（xxx.so -> xxx-ext.so）。
#
# base 里也有 libwayland-client.so.0 / libxcb-dri3.so.0 / libdrm.so.2，
# 应用往往在加载扩展之前就把它们加载进进程了，之后动态链接器只会按 SONAME
# 复用已加载的那份，DT_RUNPATH 也压不过。换成本层独有的 SONAME 后，
# 这些依赖必然从扩展目录加载，既不需要 LD_LIBRARY_PATH 也不需要 LD_PRELOAD。
#
# 只换「base 有同名 SONAME 且我们需要更新 ABI」的交集，不搞全量改名。
# 逐个符号比对后的分组（base = Mesa 24.3 / libdrm 2.4.123 / wayland 1.23）：
#   · 必须换（base 缺符号，Mesa 直接引用）：
#       libwayland-client  wl_fixes_interface / wl_display_dispatch_queue_timeout
#       libwayland-server  wl_fixes_interface
#       libxcb-dri3        xcb_dri3_{import,free}_syncobj*
#       libxcb-present     xcb_present_pixmap_synced*
#   · 顺带换（base 符号齐全，但结构体是和头文件配套的，混用会读到未初始化字段）：
#       libdrm / libdrm_amdgpu / libdrm_intel / libdrm_radeon / libdrm_nouveau
#       （2.4.133 头文件里的 amdgpu_gpu_info 尾部字段 2.4.123 不会填）
#   · 不换（base 的导出符号是超集，共享一份反而更安全）：
#       libwayland-egl      wl_egl_window 由应用创建、我们消费，同一份实例最好
#       libwayland-cursor   我们的 Mesa 根本不引用
#       libxcb / libX11 等  跨库共享进程级全局状态，复制会破坏错误处理器等
#
# libvulkan_*.so / dri_gbm.so / *_dri.so 由绝对路径或环境变量目录定位，
# 名字不参与搜索，改名没有意义。
#
# wayland 的可交互结构（wl_display / wl_proxy / wl_event_queue / wl_map）
# 在 1.23 与 1.26 之间布局一致，所以扩展内 1.26、应用侧 1.23 可以共存。
privateize_runtime_libs() {
    local root=$1
    local f soname new dst n
    local -a args

    # 1) 生成私有 SONAME 副本，删掉原名文件避免被 ld.so.cache 命中
    while IFS= read -r -d '' f; do
        soname=$(readelf -d "${f}" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
        [ -n "${soname}" ] || continue
        new=${SONAME_MAP[${soname}]:-}
        [ -n "${new}" ] || continue
        dst="$(dirname "${f}")/${new}"
        cp -f "${f}" "${dst}"
        patchelf --set-soname "${new}" "${dst}"
        rm -f "${f}" "$(dirname "${f}")/${soname}"
        log "SONAME ${soname} -> ${new}"
    done < <(find "${root}" -type f \( -name '*.so' -o -name '*.so.[0-9]*' \) -print0)

    # 2) 全层 NEEDED 重定向到私有名
    while IFS= read -r -d '' f; do
        args=()
        while IFS= read -r n; do
            [ -n "${SONAME_MAP[${n}]:-}" ] && args+=(--replace-needed "${n}" "${SONAME_MAP[${n}]}")
        done < <(readelf -d "${f}" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
        if [ ${#args[@]} -gt 0 ]; then
            patchelf "${args[@]}" "${f}"
            log "NEEDED $(basename "${f}")"
        fi
    done < <(find "${root}" -type f \( -name '*.so' -o -name '*.so.[0-9]*' \) -print0)

    # 3) 清掉失效的编译期链接（libfoo.so -> libfoo.so.N）
    find "${root}" -xtype l -delete
}

# 扩展里凡是「Mesa 家族」的依赖都必须由扩展自己提供。
# 一旦落到 base，就是命中 base 的 Mesa 24.3 / llvm-17：轻则 OpenCL 失效，
# 重则 Vulkan 驱动 dlopen 失败（zink 报 VK_ERROR_INCOMPATIBLE_DRIVER）。
#
# 用一次 python 解析全部 ELF，不在 shell 里对几十个上百 MB 的库反复 fork
# objdump/awk —— 那样在容器里会吃满内存被静默杀掉。
verify_no_base_mesa_deps() {
    local out
    if ! out=$(python3 - "${EXTROOT}" "${SHARED_WITH_BASE[@]}" <<'PY'
import os
import re
import struct
import sys

root = sys.argv[1]
shared = set(sys.argv[2:])
family = re.compile(
    r'^lib(drm|wayland-|xcb|gbm|LLVM|clang|display-info|vulkan|EGL|GLX|GL\.|gallium|llvmspirv|clc)'
)

def elf_dyn(path):
    """返回 (soname, [needed...])；非 ELF64 或静态库返回 None。"""
    try:
        with open(path, 'rb') as fp:
            data = fp.read()
    except OSError:
        return None
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[4] != 2:
        return None

    phoff = struct.unpack_from('<Q', data, 0x20)[0]
    phentsize = struct.unpack_from('<H', data, 0x36)[0]
    phnum = struct.unpack_from('<H', data, 0x38)[0]

    loads, dyn = [], None
    for i in range(phnum):
        off = phoff + i * phentsize
        p_type, = struct.unpack_from('<I', data, off)
        if p_type == 1:      # PT_LOAD
            loads.append((
                struct.unpack_from('<Q', data, off + 16)[0],   # p_vaddr
                struct.unpack_from('<Q', data, off + 8)[0],    # p_offset
                struct.unpack_from('<Q', data, off + 32)[0],   # p_filesz
            ))
        elif p_type == 2:    # PT_DYNAMIC
            dyn = (
                struct.unpack_from('<Q', data, off + 8)[0],
                struct.unpack_from('<Q', data, off + 32)[0],
            )
    if dyn is None:
        return None

    def to_off(addr):
        for vaddr, poff, filesz in loads:
            if vaddr <= addr < vaddr + filesz:
                return addr - vaddr + poff
        return None

    entries, strtab = [], None
    off, size = dyn
    for i in range(size // 16):
        tag, val = struct.unpack_from('<QQ', data, off + i * 16)
        if tag == 0:
            break
        if tag == 5:          # DT_STRTAB
            strtab = to_off(val)
        entries.append((tag, val))
    if strtab is None:
        return None

    def cstr(idx):
        end = data.index(b'\0', strtab + idx)
        return data[strtab + idx:end].decode('utf-8', 'replace')

    soname, needed = None, []
    for tag, val in entries:
        if tag == 14:         # DT_SONAME
            soname = cstr(val)
        elif tag == 1:        # DT_NEEDED
            needed.append(cstr(val))
    return soname, needed

provided, elfs = set(), []
for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        full = os.path.join(dirpath, name)
        if not os.path.isfile(full):
            continue
        info = elf_dyn(full)
        if info is None:
            continue
        soname, needed = info
        provided.add(name)
        if soname:
            provided.add(soname)
        elfs.append((name, needed))

bad = []
for name, needed in elfs:
    for dep in needed:
        if family.match(dep) and dep not in provided and dep not in shared:
            bad.append('{} -> {}'.format(name, dep))

if bad:
    print('\n'.join(sorted(set(bad))))
    sys.exit(1)
PY
    ); then
        printf '%s\n' "${out}" >&2
        die '上面这些 Mesa 家族依赖没有自带（base 里是 Mesa 24.3 / llvm-17）'
    fi

    log 'Mesa 家族依赖全部自带'
}

# 通用校验：私有化后的每个库，都不能再和 base 的同名库共享任何导出符号。
# 只要还有交集，进程里 base 那份就可能顶替我们 Mesa 的引用。
verify_symbol_isolation() {
    local base_dir="/usr/lib/${TRIPLET}" so dst base_path ours a b overlap bad=0
    for so in "${!SONAME_MAP[@]}"; do
        base_path="${base_dir}/${so}"
        [ -e "${base_path}" ] || continue
        dst=${SONAME_MAP[${so}]}
        ours=$(find "${EXTROOT}" -type f -name "${dst}" -print -quit 2>/dev/null)
        if [ -z "${ours}" ]; then
            warn "找不到私有化后的 ${dst}，跳过符号校验"
            continue
        fi

        a=$(nm -D --defined-only --format=posix "${base_path}" 2>/dev/null \
            | awk '$2 ~ /^[TDBRVWi]$/ {print $1}' | sed 's/@.*//' | sort -u)
        b=$(nm -D --defined-only --format=posix "${ours}" 2>/dev/null \
            | awk '$2 ~ /^[TDBRVWi]$/ {print $1}' | sed 's/@.*//' | sort -u)
        overlap=$(comm -12 <(printf '%s\n' "${a}") <(printf '%s\n' "${b}") || true)
        if [ -n "${overlap}" ]; then
            printf '%s 与 base 共享以下符号:\n%s\n' "${dst}" "${overlap}" >&2
            bad=1
        fi
    done

    [ "${bad}" -eq 0 ] || die '私有库仍与 base 共享符号名，运行时会互相顶替'
    log '私有库符号已与 base 完全隔离'
}

verify_outputs() {
    verify_symbol_isolation
    local libs=(
        "${MESA_PREFIX}/lib/${TRIPLET}/libEGL_mesa-ext.so.0"
        "${MESA_PREFIX}/lib/${TRIPLET}/libGLX_mesa-ext.so.0"
        "${MESA_PREFIX}/lib/${TRIPLET}/libvulkan_radeon.so"
        "${MESA_PREFIX}/lib/${TRIPLET}/libdisplay-info.so.1"
        "${LLVM_PREFIX}/libLLVM.so.19.1"
        "${LLVM_PREFIX}/libclang-cpp.so.19.1"
        "${LLVM_PREFIX}/libLLVMSPIRVLib.so.19.1"
    )
    local p f
    for p in "${MESA_PREFIX}/lib/${TRIPLET}"/libgallium-*.so; do
        if [ -e "${p}" ]; then libs+=("${p}"); fi
    done

    for f in "${libs[@]}"; do
        [ -e "${f}" ] || die "缺少产物 ${f}"
    done

    local missing outside
    missing=$(ldd "${libs[@]}" 2>&1 | grep 'not found' || true)
    [ -z "${missing}" ] || die "存在未解析的依赖：
${missing}"

    outside=$(ldd "${libs[@]}" 2>/dev/null \
        | grep -F -f <(printf '%s\n' "${SONAME_MAP[@]}") \
        | grep -v "${EXTROOT}" || true)
    [ -z "${outside}" ] || die "私有库解析到扩展目录之外：
${outside}"

    verify_no_base_mesa_deps
    log '产物链接自检通过'
}

# ================================ 主流程 ===================================

prepare_sources() {
    mkdir -p "${SRC_DIR}"
    fetch_repo wayland https://github.com/deepin-community/wayland.git master
    fetch_repo libxcb https://github.com/deepin-community/libxcb.git master
    fetch_repo libdrm https://github.com/deepin-community/libdrm.git master
    fetch_repo mesa https://gitlab.freedesktop.org/mesa/mesa.git staging/26.3

    # 旧脚本误克隆出来的嵌套仓库，占空间且无用途
    if [ -d "${SRC_DIR}/mesa/mesa/.git" ]; then
        warn '清理历史遗留的 source/mesa/mesa'
        rm -rf "${SRC_DIR}/mesa/mesa"
    fi
}

# clone 源码之前必须先有的工具
install_base_tools() {
    apt_install "${DEPS_BOOTSTRAP[@]}"
}

install_dependencies() {
    # 三个被依赖库的构建依赖，一次性装好
    apt_install "${DEP_WAYLAND[@]}"
    apt_install "${DEP_LIBDRM[@]}"
    apt_install "${DEP_LIBXCB[@]}"

    # base 自带 llvm-17 系列，和 19 抢同名 .pc（LLVMSPIRVLib.pc / libclc.pc）。
    # 只在 19 还没装齐时才先卸 17，装好之后每轮都直接跳过 purge。
    if llvm19_installed; then
        log 'LLVM19 / clang19 已就绪，跳过 purge'
    else
        apt_purge "${CONFLICT_PKGS[@]}"
    fi

    # 无论上面走哪条分支，都要确保 DEP_MESA 整体到位
    # （apt_install 只会装缺失的，全齐时是纯 dpkg 查询，很快）
    apt_install "${DEP_MESA[@]}"
}

main() {
    stage '环境自检' require_apt
    stage '清理 apt 源' cleanup_apt_sources
    stage '刷新 apt 索引' apt_refresh
    stage '安装基础工具' install_base_tools
    stage '获取源码' prepare_sources
    stage '安装构建依赖' install_dependencies
    stage '准备 Python 工具链' setup_python_toolchain
    stage '准备 Rust 工具链' setup_rust_toolchain
    stage '校验工具链' verify_toolchain

    stage '构建 wayland' build_wayland
    stage '构建 libxcb' build_libxcb
    stage '构建 libdrm' build_libdrm
    stage '构建 mesa' build_mesa

    stage '安装外部运行库' install_runtime_libs
    stage '私有化 SONAME' privateize_runtime_libs "${EXTROOT}"
    stage '校验产物' verify_outputs

    report_timings
    log 'mesa build done'
}

main "$@"
