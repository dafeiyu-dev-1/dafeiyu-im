# 大肥鱼 IM

一个跑在 HarmonyOS 手机上的**个人自用**通讯客户端：手机 ←WebSocket→ 你自己电脑上的服务 ←→ 你自己的 AI 会话。

消息、语音、图片、推送全部走你自己的服务，不依赖任何第三方 IM 平台。

> 仓库里所有个人信息、密钥、私有路径都已清掉或改成配置项；**应用图标、头像、角色立绘全部是占位图**（浅蓝底 + IM / PLACEHOLDER），可自由替换。

## 目录

- [能做什么](#能做什么)
- [部署前准备](#部署前准备)
- [第一步：启动服务端](#第一步启动服务端)
- [第二步：开一条公网隧道](#第二步开一条公网隧道)
- [第三步：编译并安装手机端](#第三步编译并安装手机端)
- [可选：华为推送](#可选华为推送)
- [可选：语音合成](#可选语音合成)
- [可选：接你自己的 AI](#可选接你自己的-ai)
- [验证是否跑通](#验证是否跑通)
- [常见问题](#常见问题)
- [结构](#结构)
- [已知限制](#已知限制)
- [使用范围与免责](#使用范围与免责)
- [隐私](#隐私)
- [许可](#许可)

## 能做什么

- 手机端原生 ArkTS 界面：会话侧栏、表情/图片/语音气泡、断线重连、未读、撤回、本地消息缓存。
- 桌面端 Node 服务：消息中转、历史记录、图片上传、语音合成转发、华为推送。
- 语音：文本 → 合成 → 转换音色 → 手机端可暂停/续播。
- 折叠屏：展开后侧栏并排。

## 部署前准备

| 需要 | 说明 |
| --- | --- |
| 一台常开的电脑 | 服务端要一直跑着，手机关掉再开也能收到历史。Windows / macOS / Linux 都行。 |
| Node.js 18+ | 只在 `server/` 用。 |
| DevEco Studio | 编译手机端。建议 HarmonyOS SDK 6.0 / API 26（DevEco 26.0 系列）。 |
| 一部 HarmonyOS 手机 | 打开开发者模式与 USB 调试。 |
| 一个公网可达的隧道 | ngrok / cloudflared 等，把本机 `8787` 暴露成 `wss://`。 |

整体是三步：**服务端 → 隧道 → 手机端**，三步都通了才算能用。

## 第一步：启动服务端

```bash
cd server
npm install
cp .env.cmd.example .env.cmd     # Windows
# Linux / macOS：改成用 export 设置同样的变量
```

编辑 `.env.cmd`，至少填两项：

```bat
set IM_TOKEN=换成一个足够长的随机串
set IM_PORT=8787
```

启动：

```bash
node index.mjs
```

看到监听日志后自检：

```bash
curl http://127.0.0.1:8787/health
# {"ok":true,"clients":0,...}
```

这一步没跑通，后面都不用做。

关于默认值（v1.0.1 起）：

- `IM_TOKEN` 必须自己设置，留空或写成 `change-me` 会直接拒绝启动。
- 服务端默认只监听 `127.0.0.1`，公网一律走隧道进来；确实要在局域网里直连，再设 `IM_BIND=0.0.0.0`。
- 图片、语音、表情这些静态资源也要带 `?token=`，手机端已自动拼好；用浏览器直接开 `/files/xxx` 会得到 401，属于预期。

## 第二步：开一条公网隧道

手机和电脑不在同一局域网时，需要一个公网 `wss://` 地址。任选一种：

```bash
# ngrok
ngrok http 8787

# cloudflared
cloudflared tunnel --url http://127.0.0.1:8787
```

把拿到的域名记下来（形如 `https://xxxx.ngrok-free.dev`），客户端里要写成 `wss://` 开头、并在末尾拼 token：

```
wss://xxxx.ngrok-free.dev/ws?token=你的IM_TOKEN
```

> token 必须拼在 URL 上：服务端在握手阶段就校验，不带会直接断开（close code 1006）。
> 免费隧道每次重启域名会变，想固定就走 ngrok 的固定域名或 cloudflared 的命名隧道。

## 第三步：编译并安装手机端

1. 用 DevEco Studio 打开**仓库根目录**，等它自动完成 `ohpm install` 和 hvigor 依赖安装（首次会拉 `@ohos/hvigor` 等，需要联网）。
2. 改 `AppScope/app.json5` 里的 `bundleName`（示例 `com.example.dafeiyuim`），换成你自己的。
3. 在 `Project Structure → Signing Configs` 里勾自动签名，或用你自己的证书 / Profile。
4. 打开 `entry/src/main/ets/services/Config.ets`，填两处：

   ```ts
   static readonly SERVER_URL: string = 'wss://xxxx.example.com/ws?token=YOUR_TOKEN';
   static readonly TOKEN: string = 'YOUR_TOKEN';
   ```

5. 连上手机，Run。

> 命令行裸跑 `hvigor assembleHap` 需要本机已装好同一套依赖；干净环境直接跑会报 `Cannot find module '@ohos/hvigor'` 或 `00302013 Script Error`，这不是代码问题。

## 可选：华为推送

不做也能用（App 在前台时靠 WebSocket）。要收后台通知，需要自建 AGC 应用：

1. AGC 创建应用，包名与 `bundleName` 一致。
2. 开通「推送服务」，申请「自分类权益 · 即时通讯」。
3. 创建**服务账号**，下载 JSON 放到 `server/data/service-account.json`（已在 `.gitignore`）。
4. 把项目 ID、发送者 ID 等填进 `server/.env.cmd`（见 `.env.cmd.example` 的 `PUSH_*`）。
5. 手机上打开 App 获取设备 token，会存到 `server/data/push-tokens.json`。

常见坑：重装应用后通知权限会被重置，需要引导用户重新授权，否则接口返回成功但收不到通知。

## 可选：语音合成

链路：文本 → edge-tts 合成中性女声 → RVC 换成目标音色 → 回传手机。

- 守护进程默认在 `8788`，仓库**不含任何音色权重**（体积大、且各自有许可），需要自己获取或训练。
- 权重放 `rvc-app/assets/weights/*.pth`、索引放对应目录；路径尽量用 ASCII，某些库对非 ASCII 路径会报错。
- 客户端 `Config.VOICE_ENABLED` 控制语音 UI 是否出现；服务端配 `TTS_DAEMON`。
- 不配也能用，只是语音退化为纯文字。

## 可选：接你自己的 AI

`bridge/` 是把手机消息送进 AI 会话、再把回复推回手机的桥接层，属于**可选**组件：

```bash
cd bridge
cp config.example.json config.json   # 填 token 与 serverUrl
npm install
node index.js
```

不接 bridge 的话，`server` 就是一个纯消息中转，可以自己写脚本调 `POST /say` 往手机推消息。

## 验证是否跑通

1. `curl http://127.0.0.1:8787/health` 返回 `ok:true`。
2. 手机端状态从「连接中」变成「在线」。
3. 手机发一条消息，服务端日志出现新消息，`server/data/messages.jsonl` 里能看到。
4. 收到回复（或自己 `curl -X POST /say` 推一条回来），手机端能显示。

## 常见问题

| 现象 | 排查 |
| --- | --- |
| 手机一直「连接中」 | 隧道域名写错 / 忘了 `wss://` / token 没拼在 URL 上 / 服务端没起。 |
| 连上就断（1006） | 基本是 token 不对；看服务端握手日志。 |
| DevEco 报 `Cannot find module '@ohos/hvigor'` | 缺依赖，用 DevEco 打开让它自动装，别用裸 hvigor。 |
| 打包报 `00303074 bundleName ... SigningConfigs` | `app.json5` 的包名和签名配置对不上，改成一致。 |
| 表情包/贴纸目录为空 | 配 `STICKER_SEED` 指向你的表情目录，或手动放进 `server/data/stickers/`。 |

更细的说明见 [docs/SETUP.md](docs/SETUP.md)，素材与授权见 [docs/ASSETS.md](docs/ASSETS.md)。

## 结构

```text
entry/        手机端（ArkTS / ArkUI）
server/       Node 服务（WebSocket / REST / 推送 / TTS 转发）
bridge/       agent 侧桥接（可选）
tools/        启动脚本
docs/         部署说明、资源与许可
```

## 已知限制

- 语音需要自己额外部署音色合成服务，仓库不含任何模型权重。
- 推送需要自建 AGC 应用并申请对应权益，个人开发者可能无法通过审核。
- 界面默认用系统字体；想要 Noto Sans SC 的外观请自行放入 `entry/src/main/resources/rawfile/fonts/` 并在 `Index.ets` 的 `aboutToAppear()` 里注册（同时附上 OFL 许可文本）。
- 角色立绘与图标为占位图，见 [docs/ASSETS.md](docs/ASSETS.md)。
- `AppScope/app.json5` 里的包名是 `com.example.dafeiyuim`，发布前务必改成你自己的。

## 使用范围与免责

- 本项目是**个人自用/学习**用途的软件，不是可供公众注册使用的即时通讯服务。
- 如果你把它部署成对他人开放的服务，需要自行承担合规责任，包括但不限于：ICP 备案、用户实名、内容安全审核、数据留存等要求。
- 语音转换只提供链路与接口，**不附带任何音色模型**。使用他人配音、角色音色或真人声音做转换，可能涉及著作权、表演者权与人格权，请自行取得授权；不要把这类权重随仓库分发。
- 项目名、界面文案与角色形象仅用于个人项目，若与他人商标或在先权利冲突，请自行改名后使用。

## 隐私

- 消息、图片、语音都存在你自己电脑上的 `server/data/`，不上传第三方。
- 语音合成与识别如果启用云端服务，请自行阅读对应服务的隐私条款。
- 仓库不收集任何数据，也没有遥测。

## 许可

- 代码：MIT，见 [LICENSE](LICENSE)。
- 文档与原创文字：CC BY-SA 4.0。
- 角色图片、音色权重、第三方字体**不在**上述许可内，详见 [docs/ASSETS.md](docs/ASSETS.md)。
