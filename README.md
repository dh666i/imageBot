# ImageBot

Windows 本地图片生成 WebUI。无需 Python、Node.js 或数据库，双击 bat 即可启动，通过 OpenAI-compatible 图片接口完成文生图和图生图。

[下载最新版](https://github.com/dh666i/imageBot/releases/latest)

## 3 步开始

1. 下载 Release 里的 `ImageBot-v*.zip` 并解压。
2. 双击 `启动图片WebUI-独立Config版.bat`。
3. 首次打开后按配置向导填写 API Key，然后开始生成。

也可以手动复制 `config.example.ini` 为 `config.ini`，再填写：

```ini
OPENAI_API_KEY=你的 API Key
```

## 界面设计

主界面只保留普通用户需要的 3 个动作：

- 上传图片：需要改图时上传、拖拽或粘贴图片。
- 输入需求：用自然语言描述想生成或修改的内容。
- 生成：自动判断文生图或图生图。

尺寸、质量、格式、数量、Base URL、模型等高级参数都在右上角 `设置` 里。

## 功能

- 聊天式图片生成界面。
- 文生图：直接输入提示词即可生成图片。
- 图生图：上传、拖拽或粘贴参考图后输入修改要求。
- 首次配置向导：没有 API Key 时自动引导配置。
- 本地保存：可自动保存生成图片到 `outputs/`。
- 本地历史：生成记录写入 `outputs/history.jsonl`。
- 管理员设置：Base URL、API Key、模型、超时、Mock 模式。
- 诊断工具：连接测试、配置诊断、错误复制。
- 检查更新：设置面板可打开 GitHub Releases。

## 配置

`config.example.ini` 是公开模板，不包含 API Key。真实密钥只应该写入本地 `config.ini`，该文件已被 `.gitignore` 排除。

常用配置：

```ini
OPENAI_BASE_URL=https://api.henng.cn
OPENAI_API_KEY=
OPENAI_IMAGE_MODEL=gpt-image-2
IMAGE_WEBUI_PORT=7861
IMAGE_WEBUI_TIMEOUT=240
IMAGE_WEBUI_SAVE_OUTPUTS=1
IMAGE_WEBUI_OUTPUT_DIR=outputs
IMAGE_WEBUI_LOG_DIR=logs
IMAGE_WEBUI_MOCK=0
```

`OPENAI_BASE_URL` 填根地址即可，不要带 `/v1`。程序会自动请求：

```text
/v1/images/generations
/v1/images/edits
```

## Mock 测试模式

如果只想测试界面、不请求上游、不消耗额度：

```ini
IMAGE_WEBUI_MOCK=1
```

也可以在首次配置向导中点击 `先试用 Mock`。

## 自动发布

项目包含 GitHub Actions 发布流程：

- 推送 `v*` tag 时自动打包。
- 发布包内自动生成空 `config.ini`。
- 自动扫描 `sk-...` 形式的密钥，发现后中止发布。
- 自动上传 zip 到 GitHub Release。

## 文件说明

- `启动图片WebUI-独立Config版.bat`：Windows 双击启动器。
- `openai_images_webui_no_python_config.ps1`：本地 WebUI 服务和接口代理。
- `webui_index.html`：聊天式前端界面。
- `config.example.ini`：公开配置模板。
- `config.ini`：本地私有配置，不应提交到仓库。
- `outputs/`：生成图片和历史记录，不应提交到仓库。
- `logs/`：运行日志，不应提交到仓库。

## 常见问题

### 生成卡住或 504

本地默认超时是 240 秒。如果仍然约 60 秒失败，通常是中转、网关或 CDN 的回源超时限制，需要在上游网关处调高等待时间。

### Key 缺失

首次打开页面会出现配置向导。也可以在右上角 `设置` 里填写 API Key。

### Base URL 怎么填

填写根地址，例如：

```ini
OPENAI_BASE_URL=https://api.henng.cn
```

不要填写成带 `/v1` 的地址。

## License

MIT

