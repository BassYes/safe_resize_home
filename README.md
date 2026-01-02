这份README.md 文档涵盖了脚本的使用说明，添加了\*\*故障排查（Troubleshooting）。

# ---

**LVM Safe Resize Tool (Linux /home \-\> /)**

这是一个用于 Linux 系统（如 CentOS 7/8, RHEL, Rocky Linux）的生产级 Shell 脚本。它的主要功能是**安全地**缩小 /home 逻辑卷的容量，并将释放出的空间扩容到 / (根目录)。

本脚本采用了“**数据完整性优先**”的设计哲学，融合了数据校验、服务感知、自动备份与恢复等特性。

## **✨ 主要特性**

* **🛡️ 数据安全第一**：  
  * 在执行任何破坏性操作（如删除 LV）前，强制执行 tar 备份。  
  * **双重校验**：备份后立即执行 gzip \-t (压缩包完整性) 和 tar \-t (文件列表读取) 校验，确保备份文件真实可用。  
* **🧠 智能预检**：  
  * 检查 /home 现有数据量是否能装入新分区。  
  * 检查 **备份盘** 是否有足够空间存放备份文件（防止备份撑爆磁盘）。  
* **⚙️ 运维友好**：  
  * **服务感知**：在卸载前自动识别并停止高风险服务（如 MySQL, Docker, Nginx, SMB 等）。  
  * **自动恢复**：脚本结束时尝试自动恢复之前停止的服务。  
  * **异常捕获**：如果脚本中途报错（Trap Error），会打印醒目的警告，防止系统处于未知中间状态。  
* **🔧 兼容性**：  
  * 支持 XFS 和 ext4 文件系统。  
  * 尝试保留 /etc/fstab 中的 UUID 和挂载参数。

## **📋 前置要求**

* **Root 权限**：必须以 root 用户运行。  
* **备份空间**：必须有一个非 /home 的目录用于存放备份（建议使用外部挂载盘 /mnt/backup，**严禁使用 /tmp**）。  
* **依赖工具**：系统需安装 tar, lvm2, xfsprogs (针对 XFS), psmisc (fuser)。

## **🚀 使用方法**

### **1\. 下载与授权**

Bash

chmod \+x safe\_resize\_home\_v3.0.sh

### **2\. 执行脚本**

基本用法：  
将 /home 缩小到 20G，并将备份存放在 /data/backup。

```
./safe\_resize\_home\_v3.0.sh \-s 20G \-b /data/backup
```

**参数说明：**

* \-s, \--size: 新的 /home 大小 (例如: 10G, 500M)。剩余的所有空间都会被分配给 /。  
* \-b, \--backup-dir: 备份文件存放路径（**重要：不要放在 /home 下，也不要放在 /tmp 下**）。  
* \-n, \--dry-run: 演练模式，仅打印命令不实际执行。  
* \-y, \--yes: 自动回答 Yes（适用于自动化脚本，慎用）。

## **⚠️ 故障排查 (Troubleshooting)**

### **1\. 重启后图形界面自动登录变成了 Root？**

现象：  
执行脚本并重启后，GNOME/GDM 的自动登录用户从原来的普通用户变成了 root。  
原因：  
脚本本身不会修改 GDM 配置文件。这种情况通常是由于 /home 在重建过程中被暂时卸载，或者重建后文件权限/SELinux 上下文发生变化，导致 GDM (GNOME Display Manager) 认为原用户不可用，从而回退到了 root 或默认状态。  
**解决方案：**

1. 检查并修改 GDM 配置：  
   编辑 /etc/gdm/custom.conf：  
     
   ```vi /etc/gdm/custom.conf```

   找到 \[daemon\] 部分，将 AutomaticLogin=root 修改回你的用户名：  
   ```  
   [daemon]  
   AutomaticLoginEnable=True  
   AutomaticLogin=your_username  \<-- 修改这里
   ```

2. 关键：检查家目录权限：  
   如果权限不正确，GDM 即使配置了也无法登录。请确认：  
   Bash  
   ls \-ld /home/your\_username

   * 所有者必须是该用户 (your\_username:your\_username)。如果是 root，请执行：  
     chown \-R your\_username:your\_username /home/your\_username  
   * **权限**通常应为 700 (drwx------)。  
3. 修复 SELinux 上下文：  
   如果系统开启了 SELinux，上下文错误也会导致无法登录。  
   Bash  
   restorecon \-Rv /home

### **2\. 格式化时报错 unknown option \-i inode64=0**

现象：  
脚本在 mkfs.xfs 步骤报错退出。  
原因：  
旧版本的 xfsprogs (如 CentOS 7 默认版本) 不支持在格式化时显式指定 \-i inode64 参数。  
解决方案：  
编辑脚本，找到格式化部分，去掉 \-i inode64=$XFS\_INODE64 参数，直接使用 mkfs.xfs \-f ... 即可。

## ---

**免责声明**

本脚本涉及**高风险**的磁盘分区和格式化操作。尽管脚本包含了多重安全检查和备份机制，但在生产环境执行前：

1. 务必确保已经拥有**独立于本机的额外数据备份**。  
2. 务必先在测试机或虚拟机中进行验证。

作者不对因使用本脚本导致的数据丢失或系统损坏承担责任。
