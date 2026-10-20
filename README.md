# PCL2 下载限制解除补丁 (PCL2 Download Unlock Patch)

> ⚠️ **声明 / Disclaimer**：  
> 本仓库脚本整理自 GitHub 社区其他开发者的开源成果。因原仓库已被作者删除/下架，为防止工具代码丢失、方便有需要的同学查阅与个人学习研究，特此重新上传归档备份。  
> 本项目仅供 C# / .NET IL 逆向与字节码修补技术交流学习，请勿用于任何侵权或商业用途。

---

## 📖 项目简介

本补丁通过在字节码层面进行 IL Patch，解除 **Plain Craft Launcher 2 (PCL2)** 正式版 (v413+) 中针对 Minecraft 下载页面与整合包安装分发的内置限制。

脚本基于 `Mono.Cecil` 实现动态加载与修补，无需手动重新编译整个启动器源码，支持重复运行（具备幂等检测，已打补丁的项目会自动跳过）。

---

## ⚙️ 修补原理与补丁详情

基于 PCL2 源码中 `RestrictMcDownload` 编译期常量折叠逻辑，脚本进行了以下 6 处 IL 热修复：

| 补丁编号 | 修补目标 | 作用说明 |
| :--- | :--- | :--- |
| **P1** | `PageDownloadInstall._Closure$__._Lambda$__3-0` | 将下载页原有的无条件 throw 异常桩替换为 `ret`，解除下载页入口封锁。 |
| **P2** | `ModModpack.ModpackInstall` (3参) | 移除阻断 throw 桩，重建 `Select Case` 分发逻辑，恢复对 CurseForge / Modrinth / HMCL / MMC / MCBBS / LauncherPack 等整合包源的解析支持。 |
| **P3** | `PageDownloadInstall.LoaderInit` | 移除“关闭下载”相关阻断桩，恢复加载真正的 `DlClientListLoader`（获取官方及镜像客户端版本列表）。 |
| **P4** | `PageDownloadModify.LoadInstanceFinished` | 将隐藏的 `CardMinecraft` 控件可见性从 `Collapsed` (2) 恢复为 `Visible` (0)。 |
| **P5** | `PageDownloadResourceDetail.InitializeStackResourceVersions` | 在整合包资源详情页恢复被隐藏的 `Install_Click` 安装按钮交互逻辑。 |
| **P6** | `ModModpack.ModpackInstall` (0参) | 重建本地整合包导入入口，恢复通过文件对话框选择 `.zip` / `.rar` / `.mrpack` 文件的功能。 |

---

## 🚀 使用指南

### 1. 前置要求
- Windows 10 / 11 操作系统
- PowerShell 5.1 或更高版本
- 联网环境（首次运行需自动从 NuGet 获取 `Mono.Cecil 0.11.5` 依赖库，下载后缓存在临时目录）

### 2. 操作步骤

1. 下载本仓库中的 `pcl2_unlock_patch.ps1` 脚本；
2. 将脚本放置在包含 `Plain Craft Launcher 2.exe`（或 `PCL2.exe`）的同一目录下；
3. **彻底退出正在运行的 PCL2 启动器**（若进程残留，补丁替换将会失败）；
4. 打开 PowerShell / Terminal，执行以下命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\pcl2_unlock_patch.ps1
```

5. 脚本将自动识别并选择目标 exe（若存在多个 exe 会提示输入编号）；
6. 提示 `完成: ... 已打补丁` 后，按回车退出，重新启动 PCL2 即可。

---

## 🛡️ 安全与备份机制

- **原文件备份**：脚本在执行任何修改前，会自动将当前可执行文件完整备份至系统的临时目录：  
  `%TEMP%\pcl_patch\original_backup.exe`
- **安全写回**：修补先写入独立临时文件，并检查 PCL2 进程状态，确认无冲突后再原子覆盖。
- **幂等保护**：每个补丁模块均带有特征码识别，重复对已修补的文件运行不会造成二次损坏。

---

## ⚖️ 免责声明 (Disclaimer)

1. 本脚本为开源技术归档，原作者信息随原仓库删除已不可考；
2. 使用本补丁产生的任何稳定性问题、数据丢失或软件异常，需使用者自行承担；
3. 请支持正版 Minecraft 及原开发者社区生态。
