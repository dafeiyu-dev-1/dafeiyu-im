# 部署与配置

这个仓库由两部分组成：

- `entry/`：HarmonyOS 手机端（ArkTS / ArkUI），用 DevEco Studio 打开根目录即可。
- `server/`：Node.js 桌面端服务（WebSocket + REST），负责消息中转、TTS/ASR、推送。

手机端通过一条公网隧道连到你自己的电脑，所以「电脑 + 手机」要一直在线。

## 0. 客户端首次构建

仓库里不带构建缓存和第三方依赖，**请用 DevEco Studio 打开根目录**（推荐 HarmonyOS SDK 6.0 / API 26，DevEco 26.0 系列）：

1. 打开工程后等 IDE 自动执行 `ohpm install` 与 hvigor 依赖安装（首次会拉 `@ohos/hvigor`、`@ohos/hvigor-ohos-plugin`）。
2. 在 `Project Structure → Signing Configs` 里勾自动签名，或用你自己的证书/Profile。
3. 把 `AppScope/app.json5` 的 `bundleName`（示例为 `com.dafeiyu.im`）改成你自己的，避免与已发布应用冲突。
4. Run 到手机。

命令行裸跑 `hvigor assembleHap` 需要本机已装好上面那套依赖；干净环境下直接跑会报 `Cannot find module '@ohos/hvigor'` 或 `00302013 Script Error`，这不是代码问题。

## 1. 服务端

> 两个硬要求：`IM_TOKEN` 必须是非空且不等于 `change-me` 的值（否则进程直接退出）；服务端默认只监听 `127.0.0.1`，公网请用隧道转发，需要局域网直连时再设 `IM_BIND=0.0.0.0`。

```bash
cd server
npm install
cp .env.cmd.example .env.cmd   # Windows；Linux/macOS 用 export 设同样的变量
# 编辑 .env.cmd：至少填 IM_TOKEN（随便一个长随机串）
node index.mjs
```

默认监听 `8787`。健康检查：`curl http://127.0.0.1:8787/health`。

可选能力（不配也能跑，只是功能降级）：

| 变量 | 作用 |
| --- | --- |
| `STICKER_SEED` | 首次启动时把表情包从这个目录导入 |
| `DEFAULT_WORKSPACE` | 手机端「工作区」列表里的默认目录 |
| `TTS_DAEMON` | 本地音色合成守护进程地址（默认 `http://127.0.0.1:8788`），没有则语音退化为纯文字 |
| `PUSH_APP_ID` / `PUSH_CLIENT_ID` / `PUSH_CLIENT_SECRET` / `PUSH_SERVICE_ACCOUNT` / `PUSH_PROJECT_ID` | 华为推送（见第 4 节） |

## 2. 公网入口（隧道）

手机不在同一局域网时，需要一个公网可访问的 wss 地址。两种常见做法：

- **ngrok**：`ngrok http 8787`，把分配到的域名写进客户端。
- **cloudflared**：`cloudflared tunnel --url http://127.0.0.1:8787`。

拿到地址后，客户端配置见 `entry/src/main/ets/services/Config.ets`：

```ts
static readonly SERVER_URL: string = 'wss://your-tunnel.example.com/ws?token=YOUR_TOKEN';
static readonly TOKEN: string = 'YOUR_TOKEN';
```

注意 token 必须拼在 URL 上：服务端在握手阶段就校验，不带会直接断开（close code 1006）。

## 3. 客户端

1. DevEco Studio 打开仓库根目录（需要 HarmonyOS SDK，`targetAPIVersion` 26）。
2. 改 `AppScope/app.json5` 的 `bundleName`（例如 `com.yourname.im`）。
3. 在 `build-profile.json5` 里配置你自己的签名证书与 Profile（华为开发者联盟申请调试证书）。
4. 改 `Config.ets` 的地址与 token。
5. 真机运行 / 打包 HAP。

## 4. 华为推送（可选）

推送依赖 AGC 项目与应用：

1. 在 AGC 创建应用，包名与 `bundleName` 一致。
2. 开通「推送服务」，申请「自分类权益 · 即时通讯」。
3. 创建**服务账号**并下载 JSON（`server/data/service-account.json`，已在 `.gitignore` 里）。
4. 项目 ID、发送者 ID 填进 `server/.env.cmd`。
5. 在应用里拿到的设备 token 会存到 `server/data/push-tokens.json`。

常见坑：重装应用后通知权限会被重置，需要在 `EntryAbility.onCreate` 里引导开启，否则接口返回成功但收不到通知。

## 5. 语音（可选）

语音链路：文本 → edge-tts 合成中性女声 → RVC 换成目标音色 → 回传手机。

- 守护进程在 `8788`，仓库不包含音色权重（体积大且有各自许可），需要自己训练或获取。
- 权重放 `rvc-app/assets/weights/*.pth` 与索引放在 ASCII 路径下（某些库对非 ASCII 路径会报错）。
- 客户端 `Config.VOICE_ENABLED` 控制是否启用语音 UI。

## 6. 目录说明

```text
entry/            手机端（ArkTS）
server/           Node 服务（WebSocket / REST / 推送 / TTS 转发）
bridge/           DSH 侧桥接：把手机消息送进 agent、把回复推回手机
tools/            启动脚本与运维小工具
docs/             这份文档与资源说明
```
