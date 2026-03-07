# Caddy 反代 Emby 一键脚本

![Language](https://img.shields.io/badge/Language-Bash-green.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-V5.0-orange.svg)

这是一个专为 **Emby** 设计的 Caddy 反向代理一键配置脚本。
支持自动申请 HTTPS 证书、自动配置开机自启、支持反代远程 HTTPS 服务器，并内置了端口冲突自动处理功能。

## 🚀 快速开始 (一键安装)

使用 **Root** 用户在终端运行以下命令即可：

```bash
bash <(curl -sL https://raw.githubusercontent.com/sure155/caddy_emby/main/install_caddy_emby.sh)
```

## 🚀 V5 版本新增核心功能
   * **多站点支持 (追加模式)**：你可以选择“追加”一个新的域名反代，而不覆盖之前的配置。单台机器，无限 Emby！

   * **指定删除**：可以列出当前所有反代域名，并指定删除其中某一个，不影响其他站点。

   * **智能防重**：添加新域名时，会自动检测该域名是否已存在，避免 Caddy 报错。
## ✨ 核心功能

  * **⚡️ 极速配置**：自动识别系统 (Debian/Ubuntu/CentOS) 并安装最新版 Caddy。
  * **🛠 端口自动修复**：一键检测并强制清理占用 80/443 端口的 Nginx/Apache 进程，解决 Caddy 启动失败问题。
  * **🔒 完美 HTTPS 支持**：
      * 自动申请并续期 Let's Encrypt SSL 证书。
      * **支持反代 HTTPS 后端**：自动修正 Host 头，完美反代远程 Emby 服务器 (解决 404/403 错误)。
  * **🚀 性能优化**：
      * 开启 Gzip 压缩。
      * 透传真实 IP (`X-Forwarded-For`)，方便 Emby 识别客户端。
      * 自动配置开机自启。

## 📖 使用指南

### 1\. 运行脚本

输入上述一键命令后，您将看到如下菜单：

```text
#################################################
#    Caddy + Emby 多站点管理脚本 (V5 Pro)       #
#################################################
 1. 安装环境 & Caddy
 2. 添加/覆盖 反代配置 (支持多站)
 3. 删除指定站点配置 (NEW!)
 4. 查看 Caddy 配置文件
-------------------------------------------------
 5. 停止 Caddy
 6. 重启 Caddy
 7. 查询 443/80 端口占用
 8. 暴力处理端口占用 (修复启动失败)
 9. 卸载 Caddy
-------------------------------------------------
 0. 退出脚本

 请输入数字 [0-9]: 

```
### 2\. 推荐操作步骤

1.  **安装**：输入 `1` 安装 Caddy。
2.  **清理端口**（可选但推荐）：如果您的服务器安装过 Nginx，建议输入 `7` 检查端口占用，必要时再执行 `8` 清理。
3.  **配置**：输入 `2`，按照提示输入您的域名和 Emby 地址。
      * *域名示例*：`emby.yourdomain.com`（请确保已解析到本机 IP）
      * *后端示例*：`127.0.0.1:8096` 或 `https://remote-emby.com:443`

## ❓ 常见问题

**Q: 启动失败，提示 "bind: address already in use"？**
A: 这是因为 80 或 443 端口被 Nginx/Apache 占用了。请在脚本菜单中选择 **[8] 暴力处理端口占用**，然后重新选择 **[6] 重启 Caddy**。

**Q: 反代后 Emby 无法播放或 404？**
A: 脚本已自动处理 Host 头。请确保您输入的后端地址正确。如果是远程 HTTPS 后端，请务必带上 `https://` 前缀。

**Q: 如何查看运行日志？**
A: 使用命令 `systemctl status caddy -l` 或 `journalctl -u caddy -f`。
