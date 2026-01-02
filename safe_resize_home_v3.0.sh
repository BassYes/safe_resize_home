#!/usr/bin/env bash
set -euo pipefail

############################################
# safe_resize_home_v3.0.sh (Fusion Version)
# 生产级：缩 /home，扩 /
############################################

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; NC='\033[0m'
log_i(){ echo -e "${GREEN}[INFO]${NC} $*"; }
log_w(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
log_e(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

### ---------- 0. 依赖检查 ----------
REQUIRED_CMDS=(
  findmnt df awk sed grep
  lvs lvremove lvcreate lvextend
  mount umount
  tar gzip
  fuser
  numfmt
  systemctl # 服务控制需求
)

OPTIONAL_CMDS=(
  restorecon
  xfs_info
  xfs_growfs
  resize2fs
)

for c in "${REQUIRED_CMDS[@]}"; do
  command -v "$c" >/dev/null 2>&1 || log_e "缺少必要命令: $c"
done

### ---------- 1. 参数与全局变量 ----------
NEW_HOME_SIZE=""
BACKUP_DIR=""
DRY_RUN=0
AUTO_YES=0
STOPPED_SERVICES=()
# 定义需要优先处理的高风险服务列表
CRITICAL_SERVICES=(
  mysql mysqld mariadb
  postgresql
  docker docker.socket
  kubelet
  nfs-server nfs-idmapd
  smb smbd
  httpd nginx
)

usage(){
cat <<EOF
Usage:
  $0 -s 20G -b /mnt/backup [options]

Options:
  -s, --size SIZE        新 /home 大小 (e.g., 20G)
  -b, --backup-dir DIR   备份目录 (必须是外部磁盘或空间充足的非 /home 目录)
  -n, --dry-run          仅打印不执行
  -y, --yes              自动确认
  -h, --help             帮助
EOF
exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--size) NEW_HOME_SIZE="$2"; shift 2 ;;
    -b|--backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help) usage ;;
    *) log_e "未知参数: $1" ;;
  esac
done

[[ -z "$NEW_HOME_SIZE" || -z "$BACKUP_DIR" ]] && usage
[[ "$EUID" -ne 0 ]] && log_e "必须使用 root"

run(){
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

# 异常退出捕捉
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    log_w "=========================================="
    log_w " 脚本异常中止 (Exit Code: $exit_code)"
    log_w " 请检查系统状态：挂载点、LVM卷、服务状态"
    log_w "=========================================="
  fi
}
trap cleanup EXIT

############################################
# 2. 自动识别 & 预检
############################################
ROOT_SRC=$(findmnt -n -o SOURCE /)
HOME_SRC=$(findmnt -n -o SOURCE /home || true)
ROOT_FS=$(findmnt -n -o FSTYPE /)
HOME_FS=$(findmnt -n -o FSTYPE /home)

[[ -z "$HOME_SRC" ]] && log_e "/home 不是独立挂载"
[[ "$HOME_SRC" != /dev/* ]] && log_e "/home 不是块设备"

VG=$(lvs --noheadings -o vg_name "$HOME_SRC" | awk '{print $1}')
[[ -z "$VG" ]] && log_e "无法识别 VG"

ROOT_LV_PATH=$(lvs --noheadings -o lv_path "$ROOT_SRC" | awk '{print $1}')
HOME_LV_PATH=$(lvs --noheadings -o lv_path "$HOME_SRC" | awk '{print $1}')

# 风险检查
[[ "$ROOT_FS" =~ btrfs|zfs ]] && log_e "不支持 $ROOT_FS"
[[ "$HOME_FS" =~ btrfs|zfs ]] && log_e "不支持 $HOME_FS"

# --- 新分区能否装下现有数据 ---
USED_KB=$(df -k /home | awk 'NR==2{print $3}')
NEW_SIZE_KB=$(numfmt --from=iec "$NEW_HOME_SIZE" | awk '{print int($1/1024)}')
(( USED_KB > NEW_SIZE_KB * 85 / 100 )) && log_e "/home 现有数据量超过新大小的 85%，无法缩容"

# --- 备份盘能否装下备份文件 ---
if [[ ! -d "$BACKUP_DIR" ]]; then
    log_w "备份目录不存在，尝试创建: $BACKUP_DIR"
    run mkdir -p "$BACKUP_DIR"
fi
BACKUP_MNT=$(findmnt -n -o TARGET -T "$BACKUP_DIR")
[[ "$BACKUP_MNT" == "/" ]] && log_w "警告：备份目录位于根分区，建议使用外部存储"
[[ "$BACKUP_MNT" == "/home" ]] && log_e "备份目录不能位于 /home 内部！"

BACKUP_AVAIL_KB=$(df -k --output=avail "$BACKUP_DIR" | awk 'NR==2{print $1}')
# 预留 500MB buffer
SAFE_BUFFER_KB=512000
if (( USED_KB > (BACKUP_AVAIL_KB - SAFE_BUFFER_KB) )); then
    log_e "备份目标空间不足！需要: ${USED_KB}KB, 可用: ${BACKUP_AVAIL_KB}KB"
fi

# XFS inode64 记录
XFS_INODE64=""
if [[ "$HOME_FS" == "xfs" ]]; then
  if xfs_info /home | grep -q inode64; then XFS_INODE64=1; else XFS_INODE64=0; fi
fi

############################################
# 3. 确认
############################################
log_i "VG=$VG"
log_i "ROOT=$ROOT_LV_PATH ($ROOT_FS)"
log_i "HOME=$HOME_LV_PATH ($HOME_FS)"
log_i "PLAN: /home -> $NEW_HOME_SIZE, 剩余空间 -> /"
log_i "BACKUP TO: $BACKUP_DIR"

if [[ $AUTO_YES -ne 1 ]]; then
  read -p "确认执行？此操作有风险 (yes/no): " ans
  [[ "$ans" != "yes" ]] && exit 0
fi

############################################
# 4. 备份 + 校验
############################################
STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_TAR="$BACKUP_DIR/home_$STAMP.tar.gz"

log_i ">> 1. 备份 /home (保留权限/ACL/Xattr)..."
run tar --xattrs --acls --selinux -czf "$BACKUP_TAR" -C /home .

log_i ">> 1.1 校验备份完整性 (gzip -t)..."
run gzip -t "$BACKUP_TAR"

log_i ">> 1.2 校验文件列表 (tar -t)..."
run tar -tzf "$BACKUP_TAR" >/dev/null

############################################
# 5. 停止服务 & 卸载
############################################
if mountpoint -q /home; then
  log_i ">> 2. 检测并停止占用 /home 的关键服务..."
  
  # 遍历预定义的关键服务
  for svc in "${CRITICAL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
      log_w "  正在停止服务: $svc"
      run systemctl stop "$svc"
      STOPPED_SERVICES+=("$svc")
    fi
  done

  log_i ">> 3. 卸载 /home"
  # 尝试正常卸载
  if ! run umount /home 2>/dev/null; then
      log_w "  正常卸载失败，清理剩余占用进程..."
      run fuser -km /home || true
      sleep 2
      run umount /home || run umount -l /home
  fi
fi

############################################
# 6. 重建 home LV
############################################
log_i ">> 4. 重建 LVM 卷"
run lvremove -y "$HOME_LV_PATH"
run lvcreate -L "$NEW_HOME_SIZE" -n "$(basename "$HOME_LV_PATH")" "$VG"
HOME_LV_PATH=$(lvs --noheadings -o lv_path -S lv_name="$(basename "$HOME_LV_PATH")" | awk '{print $1}')

############################################
# 7. 格式化 & 恢复
############################################
log_i ">> 5. 格式化 ($HOME_FS)"
if [[ "$HOME_FS" == "xfs" ]]; then
  run mkfs.xfs -f "$HOME_LV_PATH"
else
  run mkfs.ext4 -F "$HOME_LV_PATH"
fi

log_i ">> 6. 挂载 & 数据解压"
run mount "$HOME_LV_PATH" /home
run tar -xzf "$BACKUP_TAR" -C /home --xattrs --acls --selinux

############################################
# 8. 修复上下文 & fstab
############################################
if command -v restorecon >/dev/null 2>&1; then
  log_i ">> 7. 修复 SELinux 上下文"
  run restorecon -RFv /home
fi

# 保持脚本A的 UUID 替换逻辑，这比脚本B的追加更安全
log_i ">> 8. 更新 /etc/fstab (保留 UUID 模式)"
FSTAB_NEW="/etc/fstab.new"
cp /etc/fstab "$FSTAB_NEW"

# 获取新 UUID
NEW_UUID=$(blkid -s UUID -o value "$HOME_LV_PATH")

# 智能替换：保留原有的挂载参数，只替换 UUID
if grep -q "/home" "$FSTAB_NEW"; then
    # 如果原 fstab 使用 UUID
    sed -i -E "s|^UUID=[^[:space:]]+([[:space:]]+/home)|UUID=${NEW_UUID}\1|" "$FSTAB_NEW"
    # 如果原 fstab 使用设备路径 (容错)
    sed -i -E "s|^/dev/mapper/[^[:space:]]+([[:space:]]+/home)|UUID=${NEW_UUID}\1|" "$FSTAB_NEW"
fi

run mount -a -T "$FSTAB_NEW"
run mv "$FSTAB_NEW" /etc/fstab
[[ -x "$(command -v restorecon)" ]] && run restorecon -v /etc/fstab

############################################
# 9. 扩容 Root & 恢复服务
############################################
log_i ">> 9. 扩容根分区"
run lvextend -l +100%FREE "$ROOT_LV_PATH"
if [[ "$ROOT_FS" == "xfs" ]]; then
  run xfs_growfs /
else
  run resize2fs "$ROOT_LV_PATH"
fi

# 恢复服务
if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
  log_i ">> 10. 恢复之前停止的服务"
  for svc in "${STOPPED_SERVICES[@]}"; do
    log_i "  启动: $svc"
    run systemctl start "$svc"
  done
fi

log_i "================ SUCCESS ================"
log_i "完成！备份文件位于: $BACKUP_TAR"
log_i "强烈建议 reboot 验证系统状态"