/**
 * 客户端连接配置（开源副本用占位值，发布前请改成你自己的）
 *
 * 1. 先在服务端生成一个访问 token（任意随机串，服务端用环境变量 IM_TOKEN 指定）
 * 2. 把你的隧道/域名填进 SERVER_URL，token 必须拼在 URL 上：
 *    服务端在 WebSocket 握手阶段就校验 token，不带会直接断开（close code 1006）
 * 3. TOKEN 与 SERVER_URL 里的 token 保持一致
 *
 * 如果你想把配置放到构建期注入，也可以改成从 BuildProfile 或 AppStorage 读，
 * 这里留成常量是为了让第一次跑起来最省事。
 */
export class Config {
  // 例：'wss://your-tunnel.example.com/ws?token=YOUR_TOKEN'
  static readonly SERVER_URL: string = 'wss://your-tunnel.example.com/ws?token=CHANGE_ME';
  static readonly TOKEN: string = 'CHANGE_ME';

  // 是否启用语音（TTS/ASR）。服务端没部署语音守护进程时改成 false，应用会退化成纯文字。
  static readonly VOICE_ENABLED: boolean = false;
}
