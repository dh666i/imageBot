# ImageBot

一个只依赖 Windows PowerShell 的本地图片生成 WebUI。双击 bat 即可启动，浏览器访问本地聊天式界面，通过 OpenAI-compatible 图片接口完成文生图和图生图。

## 特性

- 聊天式界面：像使用 ChatGPT / Gemini 一样输入提示词。
- 文生图：直接输入提示词即可生成图片。
- 图生图：上传、拖拽或粘贴图片后，再输入修改要求。
- 本地保存：可自动保存生成图片到 `outputs/`。
- 本地历史：生成记录写入 `outputs/history.jsonl`。
- 管理员设置：Base URL、API Key、模型、超时、Mock 模式可在页面右上角设置。
- 诊断工具：内置连接测试、配置诊断、错误复制。
- 无后端依赖：不需要 Python、Node.js 或数据库。

## 快速开始

1. 解压或 clone 本项目。
2. 双击 `启动图片WebUI-独立Config版.bat`。
3. 首次启动会自动从 `config.example.ini` 创建 `config.ini`。
4. 编辑 `config.ini`，填写你的 `OPENAI_API_KEY`。
5. 再次双击启动，浏览器会打开 `http://127.0.0.1:7861`。

也可以直接在页面右上角 `设置` 里临时填写 API Key。

## 配置说明

`config.example.ini` 是公开模板，不包含任何 API Key。真实密钥只应该写入本地 `config.ini`，该文件已被 `.gitignore` 排除。

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

Mock 模式会生成本地 SVG 测试图。

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

确认 `config.ini` 里已填写 `OPENAI_API_KEY`，或者在页面右上角 `设置` 中临时填写。

### Base URL 怎么填

填写根地址，例如：

```ini
OPENAI_BASE_URL=https://api.henng.cn
```

不要填写成带 `/v1` 的地址。

## License

MIT

