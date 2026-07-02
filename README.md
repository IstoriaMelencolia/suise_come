# Local Agent Pet / 本地 Agent 桌边提醒器

这是一个运行在 Windows 本地的 Agent 桌边提醒器。
当 Claude Code 或 Codex App 需要用户确认、等待输入或任务完成时，程序会从屏幕边缘弹出随机图片，并播放随机语音。

本项目不内置任何角色图片、游戏立绘或语音素材。用户需要自行准备拥有使用权的图片和语音文件。

## 功能特性

* 支持 Claude Code 触发 ask / finish
* 支持 Codex App 触发 ask / finish
* 支持随机读取图片
* 支持按图片文件名绑定角色语音
* 支持在当前角色目录中随机播放 ask / finish 语音
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
│  └─ suisen01.png
├─ suisen_voice
│  └─ suisen01
│     ├─ ask1.ogg
│     └─ ask2.ogg
├─ finish_voice
│  └─ suisen01
│     ├─ finish1.ogg
│     └─ finish2.ogg
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

程序每次显示时会从该文件夹中随机选择一张图片，并使用图片文件名（不含扩展名）作为角色 key。
例如，`suisen_02.jpg` 的角色 key 是 `suisen_02`。

### ask 语音

把需要用户确认时播放的语音放入对应角色 key 的子目录：

```text
suisen_voice\<角色key>
```

例如图片是 `suisen_picture\suisen_02.jpg`，ask 语音应放在：

```text
suisen_voice\suisen_02
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

把任务完成时播放的语音放入对应角色 key 的子目录：

```text
finish_voice\<角色key>
```

例如图片是 `suisen_picture\suisen_02.jpg`，finish 语音应放在：

```text
finish_voice\suisen_02
```

支持格式：

```text
.ogg .wav .mp3 .flac
```

图片文件名去掉扩展名后，必须与 `suisen_voice` / `finish_voice` 中的文件夹名一致。
程序不会从语音根目录随机抽取文件，因此不会出现图片角色与语音角色不一致的情况。

`show test` 会按 ask 规则查找当前角色的语音。匹配目录不存在或没有支持的语音时，图片仍然正常显示，只是不播放声音。
如果没有图片文件，程序不会弹出窗口，并会在日志中提示没有找到图片素材。

## 单张图片独立配置

可以在图片旁放置同名 JSON，为这一张图片覆盖显示参数。JSON 文件名必须与图片 stem 相同：

```text
suisen_picture\suisen01.png
suisen_picture\suisen01.json
```

`suisen01.json` 示例：

```json
{
  "voice_key": "suisen",
  "crop_ratio": 0.45,
  "top_bottom_scale": 0.40,
  "left_right_scale": 0.40,
  "top_bottom_visible_ratio": 0.70,
  "left_right_visible_ratio": 0.70,
  "allowed_edges": ["bottom", "left", "right"],
  "offset": {
    "top": 0,
    "bottom": 12,
    "left": -8,
    "right": 0
  }
}
```

JSON 只需填写想覆盖的字段，未填写的字段继续使用 `suisen_pet\config.py` 中的全局默认值。支持字段：

```text
voice_key
crop_ratio
top_bottom_scale
left_right_scale
top_bottom_visible_ratio
left_right_visible_ratio
allowed_edges
offset
```

`voice_key` 用于指定语音目录。上例会使用 `suisen_voice\suisen` 和 `finish_voice\suisen`；不填写时仍使用图片 stem `suisen01`。

`allowed_edges` 只限制未指定方向时的随机边缘，可使用 `top`、`bottom`、`left`、`right`。手动执行 `show ask top` 等指定方向命令时，仍以命令中的方向为准。

`offset` 是各方向冒出深度的像素微调：正数会多露出，负数会少露出。没有填写的方向默认为 `0`。

如果 JSON 不存在、内容无法解析或字段值无效，程序会记录日志，并使用对应的全局默认值继续显示，不会中断桌宠。

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

说明：Codex 的 `agent-turn-complete` 表示一次 agent turn 完成，不严格等于用户语义上的“整个任务最终完成”。
为了减少启动 Codex App、复杂任务中间分段完成、连续 turn 完成时的误触发，`codex_notify.ps1` 加入了三层保护：

```text
turn-id 去重
FINISH_DELAY_SECONDS = 10
FINISH_COOLDOWN_SECONDS = 20
```

收到 `agent-turn-complete` 后，脚本会先等待 `FINISH_DELAY_SECONDS` 秒。
如果这段时间内没有新的 completion 覆盖当前 pending turn，才会触发 `show finish`。
如果同一个 `turn-id` 已经触发过，或距离上次真正触发 finish 不到 `FINISH_COOLDOWN_SECONDS` 秒，则会跳过。

如果想让 finish 更快出现，可以降低 `codex_notify.ps1` 里的 `FINISH_DELAY_SECONDS`。
如果觉得 finish 仍然太频繁，可以提高 `FINISH_COOLDOWN_SECONDS`。

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
