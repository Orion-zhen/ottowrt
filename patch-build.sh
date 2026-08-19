#!/usr/bin/env bash

# 遇到命令失败、使用未定义变量或管道中的命令失败时立即退出，避免在异常状态下继续修改源码。
set -euo pipefail

# 获取脚本所在目录的绝对路径，确保从任意工作目录执行脚本时都能正确定位文件。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 确定 OpenWrt 源码目录：优先使用第一个命令行参数，其次使用 WORKDIR，最后默认使用 openwrt。
OPENWRT_DIR="${1:-${SCRIPT_DIR}/${WORKDIR:-openwrt}}"

# 如果传入的是相对路径，则将其转换为相对于脚本目录的绝对路径。
if [[ "${OPENWRT_DIR}" != /* ]]; then
  OPENWRT_DIR="${SCRIPT_DIR}/${OPENWRT_DIR}"
fi

# 在执行补丁前确认 OpenWrt 源码目录存在，防止修改错误的位置。
if [[ ! -d "${OPENWRT_DIR}" ]]; then
  echo "OpenWrt source directory not found: ${OPENWRT_DIR}" >&2
  exit 1
fi

# 修改 x86 未识别设备的默认网络布局：eth0 为 WAN，其余 eth* 接口为 LAN。
patch_x86_default_network() {
  # 只修改 x86 的兜底分支，不影响已经拥有专用网络布局的设备或其他架构。
  local network_script="${OPENWRT_DIR}/target/linux/x86/base-files/etc/board.d/02_network"
  local marker='# OttoWrt default: eth0 as WAN and remaining eth interfaces as LAN'
  local expected_block marker_count marker_line block_line_count actual_block
  local esac_line temporary_file
  expected_block=$'# OttoWrt default: eth0 as WAN and remaining eth interfaces as LAN\n*)\n\tlan_ifaces=\n\tfor iface_path in /sys/class/net/eth*; do\n\t\t[ -e "$iface_path" ] || continue\n\t\tiface="${iface_path##*/}"\n\t\t[ "$iface" = "eth0" ] || lan_ifaces="${lan_ifaces:+$lan_ifaces }$iface"\n\tdone\n\t[ -n "$lan_ifaces" ] && ucidef_set_interface_lan "$lan_ifaces"\n\tucidef_set_interface_wan "eth0"\n\t;;'

  if [[ ! -f "${network_script}" ]]; then
    echo "x86 network script not found: ${network_script}" >&2
    exit 1
  fi

  marker_count="$(grep -cFx "${marker}" "${network_script}" || true)"
  case "${marker_count}" in
    0)
      # esac 是 case 的唯一结束位置；若上游结构变化则拒绝继续，避免插入到错误位置。
      if [[ "$(grep -cFx 'esac' "${network_script}" || true)" -ne 1 ]]; then
        echo "Unexpected case structure: ${network_script}" >&2
        exit 1
      fi

      esac_line="$(grep -nFx 'esac' "${network_script}" | cut -d: -f1)"
      temporary_file="$(mktemp "${network_script}.XXXXXX")"
      {
        sed -n "1,$((esac_line - 1))p" "${network_script}"
        printf '%s\n' "${expected_block}"
        sed -n "${esac_line},\$p" "${network_script}"
      } >"${temporary_file}"
      cat "${temporary_file}" >"${network_script}"
      rm -f "${temporary_file}"
      ;;
    1)
      # 标记存在时必须与完整补丁块完全一致，不能把残缺补丁误判为已完成。
      marker_line="$(grep -nFx "${marker}" "${network_script}" | cut -d: -f1)"
      block_line_count="$(printf '%s\n' "${expected_block}" | wc -l)"
      actual_block="$(sed -n "${marker_line},$((marker_line + block_line_count - 1))p" "${network_script}")"
      if [[ "${actual_block}" != "${expected_block}" ]]; then
        echo "Existing x86 network patch is incomplete: ${network_script}" >&2
        exit 1
      fi
      ;;
    *)
      echo "Duplicate x86 network patch markers found: ${network_script}" >&2
      exit 1
      ;;
  esac

  echo "Patched x86 default network (WAN=eth0, LAN=remaining eth interfaces):"
  grep -n -A10 -F "${marker}" "${network_script}"
}

# 修改首次启动时生成的默认 LAN 地址，避免与常见的上级网络地址冲突。
patch_default_lan_ip() {
  local config_generate="${OPENWRT_DIR}/package/base-files/files/bin/config_generate"
  local old new old_count new_count old_line
  old=$'\t\t\t\tlan) ipad=${ipaddr:-"192.168.1.1"} ;;'
  new=$'\t\t\t\tlan) ipad=${ipaddr:-"192.168.114.1"} ;;'

  if [[ ! -f "${config_generate}" ]]; then
    echo "config_generate not found: ${config_generate}" >&2
    exit 1
  fi

  old_count="$(grep -cFx "${old}" "${config_generate}" || true)"
  new_count="$(grep -cFx "${new}" "${config_generate}" || true)"

  # 只允许“尚未修改”或“已经正确修改”两种状态，重复执行不会产生额外变化。
  if [[ "${old_count}" -eq 1 && "${new_count}" -eq 0 ]]; then
    old_line="$(grep -nFx "${old}" "${config_generate}" | cut -d: -f1)"
    sed -i "${old_line}c\\${new}" "${config_generate}"
  elif [[ "${old_count}" -ne 0 || "${new_count}" -ne 1 ]]; then
    echo "Unexpected default LAN IP definitions: ${config_generate}" >&2
    exit 1
  fi

  echo "Patched default LAN IP (192.168.114.1):"
  grep -n -F 'lan) ipad=${ipaddr:-"192.168.114.1"} ;;' "${config_generate}"
}

# 修补 ripgrep 的构建配置，禁用 LTO 以避免链接阶段出现构建问题。
patch_ripgrep() {
  # 定位 ripgrep 软件包的 Makefile。
  local makefile="${OPENWRT_DIR}/feeds/packages/utils/ripgrep/Makefile"

  # 确认 Makefile 存在；如果 feeds 尚未安装或路径发生变化，则立即报错。
  if [[ ! -f "${makefile}" ]]; then
    echo "Makefile not found: ${makefile}" >&2
    exit 1
  fi

  # 确认 package.mk 的引入位置存在，以便把构建标志插入到正确位置。
  if ! grep -qFx 'include $(INCLUDE_DIR)/package.mk' "${makefile}"; then
    echo "package.mk include not found: ${makefile}" >&2
    exit 1
  fi

  # 先删除已有的相同配置，使脚本可以重复执行而不会产生重复内容。
  sed -i '/^PKG_BUILD_FLAGS:=no-lto$/d' "${makefile}"

  # 在引入 package.mk 之前加入 no-lto 构建标志。
  sed -i '/^include $(INCLUDE_DIR)\/package\.mk$/i PKG_BUILD_FLAGS:=no-lto' "${makefile}"

  # 输出修改结果及其上下文，便于在构建日志中确认补丁已正确应用。
  echo "Patched ripgrep:"
  grep -n -B1 -A1 -F 'PKG_BUILD_FLAGS:=no-lto' "${makefile}"
}

# 修补 Node.js 的构建配置，禁用 LTO 以规避 GCC LTO 与 fortify-headers 的冲突。
patch_node() {
  # 定位 Node.js 软件包的 Makefile。
  local makefile="${OPENWRT_DIR}/feeds/packages/lang/node/node/Makefile"

  # 确认 Makefile 存在；如果 feeds 尚未安装或路径发生变化，则立即报错。
  if [[ ! -f "${makefile}" ]]; then
    echo "Makefile not found: ${makefile}" >&2
    exit 1
  fi

  # 确认 package.mk 的引入位置唯一，避免在上游结构变化后插入到错误位置。
  if [[ "$(grep -cFx 'include $(INCLUDE_DIR)/package.mk' "${makefile}" || true)" -ne 1 ]]; then
    echo "Unexpected package.mk include count: ${makefile}" >&2
    exit 1
  fi

  # 先删除已有的相同配置，再插入到 package.mk 之前；重复执行不会产生重复内容。
  sed -i '/^PKG_BUILD_FLAGS:=no-lto$/d' "${makefile}"
  sed -i '/^include $(INCLUDE_DIR)\/package\.mk$/i PKG_BUILD_FLAGS:=no-lto' "${makefile}"

  # 输出修改结果及其上下文，便于在构建日志中确认补丁已正确应用。
  echo "Patched Node.js:"
  grep -n -B1 -A1 -F 'PKG_BUILD_FLAGS:=no-lto' "${makefile}"
}

# 修补 netdata 的配置参数，关闭 Netdata Cloud 功能。
patch_netdata() {
  # 定位 netdata 软件包的 Makefile。
  local makefile="${OPENWRT_DIR}/feeds/packages/admin/netdata/Makefile"

  # 确认 Makefile 存在；如果 feeds 尚未安装或路径发生变化，则立即报错。
  if [[ ! -f "${makefile}" ]]; then
    echo "Makefile not found: ${makefile}" >&2
    exit 1
  fi

  # 确认 netdata 的 BuildPackage 定义存在，以便把配置参数插入到软件包定义之前。
  if ! grep -qFx '$(eval $(call BuildPackage,netdata))' "${makefile}"; then
    echo "BuildPackage definition not found: ${makefile}" >&2
    exit 1
  fi

  # 先删除已有的相同参数，使脚本可以重复执行而不会产生重复内容。
  sed -i '/^CONFIGURE_ARGS += --disable-cloud$/d' "${makefile}"

  # 在 BuildPackage 定义之前加入 --disable-cloud 配置参数。
  sed -i '/^\$(eval \$(call BuildPackage,netdata))$/i CONFIGURE_ARGS += --disable-cloud' "${makefile}"

  # 输出修改结果及其上下文，便于在构建日志中确认补丁已正确应用。
  echo "Patched netdata:"
  grep -n -B1 -A1 -F 'CONFIGURE_ARGS += --disable-cloud' "${makefile}"
}

# 依次应用网络、默认 IP 和软件包构建补丁；任一步失败都会终止脚本。
patch_x86_default_network
patch_default_lan_ip
patch_ripgrep
patch_node
patch_netdata
