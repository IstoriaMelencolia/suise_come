# Local Agent Pet / 本地 Agent 桌边提醒器

这是一个运行在 Windows 本地的 Agent 桌边提醒器。
当 Claude Code 或 Codex App 需要用户确认、等待输入或任务完成时，程序会从屏幕边缘弹出随机图片，并播放随机语音。

本项目不内置任何角色图片、游戏立绘或语音素材。用户需要自行准备拥有使用权的图片和语音文件。

## 功能特性

* 支持 Claude Code 触发 ask / finish
* 支持 Codex App 触发 ask / finish
* 支持随机读取图片
* 支持随机播放 ask 语音
* 支持随机播放 finish 语音
* 支持从屏幕四个边缘随机冒出
* 支持用户手动调整图片大小、裁切比例和露出比例
* 支持项目文件夹移动后重新部署
* 不依赖固定素材文件名

## 项目目录

```text
project-root
├─ suisen_pet
│  ├─ pet.py
│  ├─ suisen_cli.py
│  ├─ config.py
│  ├─ claude_hook.ps1
│  ├─ codex_hook.ps1
│  ├─ codex_notify.ps1
│  ├─ install_claude_hooks.ps1
│  ├─ uninstall_claude_hooks.ps1
│  ├─ install_codex_integration.ps1
│  ├─ uninstall_codex_integration.ps1
│  └─ logs
├─ suisen_picture
├─ suisen_voice
├─ finish_voice
├─ requirements.txt
├─ setup_env.ps1
└─ check_portable.ps1
```

## 准备素材

### 图片

把图片放入：

```text
suisen_picture
```

支持格式：

```text
.png .jpg .jpeg .webp .bmp .gif
```

程序每次显示时会从该文件夹中随机选择一张图片。

### ask 语音

把需要用户确认时播放的语音放入：

```text
suisen_voice
```

支持格式：

```text
.ogg .wav .mp3 .flac
```

推荐使用：

```text
.ogg .wav
```

### finish 语音

把任务完成时播放的语音放入：

```text
finish_voice
```

支持格式：

```text
.ogg .wav .mp3 .flac
```

如果没有语音文件，图片仍然可以显示，只是不播放声音。
如果没有图片文件，程序不会弹出窗口，并会在日志中提示没有找到图片素材。

## 安装环境

本项目推荐使用 Python 3.12。

在项目根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\setup_env.ps1'
```

然后检查项目状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\check_portable.ps1'
```

## 手动测试

先启动桌边提醒器本体：

```powershell
Set-Location -LiteralPath '你的项目路径'
& '.\.venv\Scripts\python.exe' '.\suisen_pet\pet.py'
```

再打开另一个 PowerShell，运行：

```powershell
Set-Location -LiteralPath '你的项目路径'

& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show test
& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show ask
& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show finish
```

也可以指定方向：

```powershell
& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show ask top
& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show ask bottom
& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show ask left
& '.\.venv\Scripts\python.exe' '.\suisen_pet\suisen_cli.py' show ask right
```

## Claude Code 接入

安装 Claude Code hooks：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\suisen_pet\install_claude_hooks.ps1'
```

打开 Claude Code 后输入：

```text
/hooks
```

检查是否存在：

```text
SessionStart -> start
Notification permission_prompt -> ask
Notification idle_prompt -> finish
SessionEnd -> stop
```

触发逻辑：

```text
SessionStart：自动启动 pet.py
permission_prompt：触发 ask
idle_prompt：触发 finish
SessionEnd：关闭 pet.py
```

卸载 Claude Code hooks：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\suisen_pet\uninstall_claude_hooks.ps1'
```

## Codex App 接入

安装 Codex integration：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\suisen_pet\install_codex_integration.ps1'
```

安装完成后，重启 Codex App。

Codex App 的触发逻辑：

```text
PermissionRequest -> ask
agent-turn-complete notify -> finish
```

Codex App 使用：

```text
%USERPROFILE%\.codex\config.toml
```

本项目默认使用 `config.toml` 的 inline hooks 和顶层 notify，不默认依赖 `hooks.json`。

如果 Codex 设置页面提示 `hooks.json` 解析错误，可以把：

```text
%USERPROFILE%\.codex\hooks.json
```

改名禁用。

卸载 Codex integration：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\suisen_pet\uninstall_codex_integration.ps1'
```

## 移动项目位置

如果把项目移动到新位置，例如：

```text
E:\suisen_come!
```

进入新位置后重新运行：

```powershell
Set-Location -LiteralPath 'E:\suisen_come!'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\setup_env.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\check_portable.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\suisen_pet\install_claude_hooks.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\suisen_pet\install_codex_integration.ps1'
```

`.venv` 和 Claude / Codex 配置中可能记录旧路径，所以移动后需要重新生成环境和 hooks。

## 显示效果调参

显示参数集中在：

```text
suisen_pet\config.py
```

常用配置：

```text
IMAGE_CROP_RATIO
```

控制裁切原图上方多少内容。

```text
TOP_BOTTOM_SCALE
LEFT_RIGHT_SCALE
```

控制上下方向、左右方向的图片大小。

```text
TOP_BOTTOM_VISIBLE_RATIO
LEFT_RIGHT_VISIBLE_RATIO
```

控制从上下边缘、左右边缘露出多少。

```text
SCREEN_SAFE_MARGIN
```

控制距离屏幕边缘的安全距离。

```text
AUTO_EXIT_IDLE_SECONDS
```

控制 pet.py 长时间空闲后自动退出的时间。

修改配置后，需要重启 `pet.py` 才能生效。

## 日志

日志目录：

```text
suisen_pet\logs
```

常见日志：

```text
claude_hook.log
codex_hook.log
codex_notify.log
```

如果没有触发，可以先检查对应日志。

## 版权说明

本项目不提供任何图片、语音、角色立绘、游戏素材或第三方版权内容。

请用户自行准备拥有使用权的素材。
如果公开分享本项目，请不要上传未经授权的游戏图片、角色立绘、语音或其他版权素材。
