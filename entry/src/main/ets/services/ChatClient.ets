import { webSocket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Config } from './Config';

export interface StoragePart {
  files: number;
  bytes: number;
}

export interface StorageInfo {
  files: number;
  bytes: number;
  images?: StoragePart;
  audio?: StoragePart;
}

/** 设置页「存储占用」用的现成文案（图片 / 语音各一行） */
export interface StorageStats {
  images: string;
  audio: string;
}

/** 一个可选的音色（装在服务端，app 只负责选） */
export interface VoiceOption {
  id: string;
  name: string;
  desc: string;
  installed: boolean;
}

export interface VoiceState {
  ok?: boolean;
  error?: string;
  current: string;
  voices: VoiceOption[];
}

export interface QuoteRef {
  text: string;
  image?: string;
}

export interface StickerItem {
  file: string;
  name: string;
  meaning: string;
  /** inline = 小表情，能夹在文字里发；pack = 整张表情包；custom = 自己加的 */
  cat?: string;
  /** 图库那边的情绪分类（happy / angry / daily…） */
  tag?: string;
  /** 所属图库名，比如「大肥鱼」 */
  pack?: string;
}

export interface ChatMessage {
  id: string;
  threadId: string;
  role: string;
  text: string;
  image?: string;
  /** 表情包文件名（服务端 /stickers/<file>），和 image 互不影响 */
  sticker?: string;
  /** 已撤回：界面上只留一个「已撤回」占位 */
  recalled?: boolean;
  /** 语音文件（服务端 /files/<name>.mp3） */
  audio?: string;
  /** 语音时长（毫秒），只用来在气泡上显示秒数 */
  audioMs?: number;
  quote?: QuoteRef;
  ts: number;
}

export interface HistoryPage {
  list: ChatMessage[];
  hasMore: boolean;
  /** 这一次到底拉成功了没有：失败的时候别拿空列表把界面清掉 */
  ok: boolean;
}

export interface Thread {
  id: string;
  name: string;
  workspace: string;
  createdAt: number;
}

export interface WorkspaceOption {
  label: string;
  path: string;
}

interface AuthHeader {
  authorization: string;
  'content-type'?: string;
  'bypass-tunnel-reminder'?: string;
  'ngrok-skip-browser-warning'?: string;
}

class HelloPayload {
  type: string = 'hello';
  token: string = '';
}

class SayPayload {
  type: string = 'user';
  threadId: string = '';
  text: string = '';
  ts: string = '';
  image?: string;
  sticker?: string;
  audio?: string;
  audioMs?: number;
  quote?: QuoteRef;
  /** 客户端生成的消息号：重连补发时服务端靠它去重 */
  cid?: string;
}

class ThreadPatch {
  id: string = '';
  workspace: string = '';
  name?: string;
}

class NewThread {
  name: string = '';
  workspace: string = '';
}

class StatePayload {
  type: string = 'state';
  fg: boolean = true;
}

export class ChatClient {
  /** 活着的实例：窗口切前后台时统一上报，不需要页面去拿引用 */
  private static liveClients: Set<ChatClient> = new Set<ChatClient>();
  /** 应用是否在前台（默认按前台算，切后台时由 EntryAbility 通知） */
  private fg: boolean = true;
  private ws: webSocket.WebSocket | null = null;
  /** 当前实际使用的入口，就是 Config 里配的那个 */
  serverUrl: string = Config.SERVER_URL;
  private reconnectTimer: number = -1;
  /** 连上之后多久还没 open 就认定卡住，掐掉重来 */
  private connectTimer: number = -1;
  private connecting: boolean = false;
  /** WS 是否真的 open（断线期间发的消息先塞 outbox） */
  private wsOpen: boolean = false;
  /** 没送出去的原始报文，重连后按顺序补发 */
  private outbox: string[] = [];
  /** 重连尝试次数：第一次立刻重试，之后退避 */
  private retry: number = 0;
  /** 消息序号，拼进 cid 保证唯一 */
  private seq: number = 0;
  /** 是不是已经连上过一次：用来区分「首次连接」和「断线重连」 */
  private opened: boolean = false;
  private closed: boolean = false;
  currentThread: string = 'main';
  onMessage: (m: ChatMessage) => void = () => {};
  onState: (s: string) => void = () => {};
  onThreads: (list: Thread[]) => void = () => {};
  onTyping: (threadId: string, on: boolean) => void = (threadId: string, on: boolean) => {};
  onRecall: (id: string) => void = (id: string) => {};
  /** 断线后重新连上：这时候要把历史重新拉一遍，补齐断线期间漏的 */
  onReconnect: () => void = () => {};

  /** ws(s)://host/ws?token=… → http(s)://host */
  baseUrl(): string {
    let u = this.serverUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');
    const i = u.indexOf('/ws');
    if (i >= 0) {
      u = u.slice(0, i);
    }
    const q = u.indexOf('?');
    if (q >= 0) {
      u = u.slice(0, q);
    }
    return u;
  }

  /** 图片/语音/表情这类静态资源的地址：服务端要求带 token */
  mediaUrl(p: string): string {
    if (!p || p.length === 0) {
      return '';
    }
    const sep = p.indexOf('?') >= 0 ? '&' : '?';
    return `${this.baseUrl()}${p}${sep}token=${encodeURIComponent(Config.TOKEN)}`;
  }

  private async request(
    method: http.RequestMethod,
    path: string,
    body?: string | ArrayBuffer,
    contentType?: string,
  ): Promise<string> {
    const req = http.createHttp();
    try {
      const auth = `Bearer ${Config.TOKEN}`;
      const header: AuthHeader = contentType
        ? {
          authorization: auth,
          'content-type': contentType,
          'bypass-tunnel-reminder': 'true',
          'ngrok-skip-browser-warning': 'true',
        }
        : { authorization: auth, 'bypass-tunnel-reminder': 'true', 'ngrok-skip-browser-warning': 'true' };
      const opts: http.HttpRequestOptions = {
        method: method,
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 15000,
      };
      const res = await req.request(`${this.baseUrl()}${path}`, opts);
      const code = Number(res.responseCode);
      if (!(code >= 200 && code < 300)) {
        throw new Error(`HTTP ${code}: ${String(res.result).slice(0, 160)}`);
      }
      return String(res.result);
    } finally {
      req.destroy();
    }
  }

  async loadThreads(): Promise<Thread[]> {
    try {
      const txt = await this.request(http.RequestMethod.GET, '/threads');
      const obj = JSON.parse(txt) as Record<string, Object>;
      const list = obj.list as Thread[];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  async loadStickers(): Promise<StickerItem[]> {
    try {
      const txt = await this.request(http.RequestMethod.GET, '/stickers');
      const obj = JSON.parse(txt) as Record<string, Object>;
      const list = obj.list as StickerItem[];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  async loadWorkspaces(): Promise<WorkspaceOption[]> {
    try {
      const txt = await this.request(http.RequestMethod.GET, '/workspaces');
      const obj = JSON.parse(txt) as Record<string, Object>;
      const list = obj.list as WorkspaceOption[];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  async createThread(name: string, workspace: string): Promise<void> {
    const p = new NewThread();
    p.name = name;
    p.workspace = workspace;
    await this.request(http.RequestMethod.POST, '/threads', JSON.stringify(p), 'application/json');
  }

  async deleteThread(id: string): Promise<void> {
    await this.request(http.RequestMethod.DELETE, `/threads?id=${encodeURIComponent(id)}`);
  }

  async patchThread(id: string, workspace: string, name?: string): Promise<void> {
    const payload = new ThreadPatch();
    payload.id = id;
    payload.workspace = workspace;
    if (name) {
      payload.name = name;
    }
    await this.request(http.RequestMethod.PATCH, '/threads', JSON.stringify(payload), 'application/json');
  }

  /** 上传图片字节，返回服务端路径（/files/xxx.jpg） */
  async uploadImage(buf: ArrayBuffer): Promise<string> {
    const txt = await this.request(http.RequestMethod.POST, '/upload', buf, 'image/jpeg');
    const obj = JSON.parse(txt) as Record<string, Object>;
    const p = obj.path as string;
    return p ?? '';
  }

  /** 加一张自己的表情到库里，成功返回文件名 */
  async addSticker(buf: ArrayBuffer): Promise<string> {
    try {
      const txt = await this.request(http.RequestMethod.POST, '/stickers/add', buf, 'image/png');
      const obj = JSON.parse(txt) as Record<string, Object>;
      return (obj.file as string) ?? '';
    } catch (e) {
      return '';
    }
  }

  /** 把自定义表情移到最前 */
  async moveStickerFront(file: string): Promise<boolean> {
    try {
      const txt = await this.request(http.RequestMethod.POST, '/stickers/front', JSON.stringify({ file }), 'application/json');
      const obj = JSON.parse(txt) as Record<string, Object>;
      return obj.ok === true;
    } catch (e) {
      return false;
    }
  }

  /** 上报华为推送 token（拿不到 token 的机器不会调到这里） */
  async registerPushToken(token: string): Promise<boolean> {
    try {
      const txt = await this.request(http.RequestMethod.POST, '/push/register', JSON.stringify({ token }), 'application/json');
      const obj = JSON.parse(txt) as Record<string, Object>;
      return obj.ok === true;
    } catch (e) {
      return false;
    }
  }

  /** 删掉自己加的表情 */
  async deleteSticker(file: string): Promise<boolean> {
    try {
      const txt = await this.request(http.RequestMethod.POST, '/stickers/delete', JSON.stringify({ file }), 'application/json');
      const obj = JSON.parse(txt) as Record<string, Object>;
      return obj.ok === true;
    } catch (e) {
      return false;
    }
  }

  /** 上传语音（m4a），返回服务端路径 /files/xxx.m4a */
  async uploadAudio(buf: ArrayBuffer): Promise<string> {
    const txt = await this.request(http.RequestMethod.POST, '/upload', buf, 'audio/mp4');
    const obj = JSON.parse(txt) as Record<string, Object>;
    const p = obj.path as string;
    return p ?? '';
  }

  async loadHistory(threadId: string, limit: number = 50, before: number = 0): Promise<HistoryPage> {
    try {
      const tail = before > 0 ? `&before=${before}` : '';
      const txt = await this.request(http.RequestMethod.GET,
        `/history?limit=${limit}&thread=${encodeURIComponent(threadId)}${tail}`);
      const obj = JSON.parse(txt) as Record<string, Object>;
      const list = obj.list as ChatMessage[];
      return { list: Array.isArray(list) ? list : [], hasMore: obj.hasMore === true, ok: true };
    } catch (e) {
      return { list: [], hasMore: false, ok: false };
    }
  }

  /** 撤回两小时内的消息 */
  async recall(id: string): Promise<boolean> {
    try {
      const txt = await this.request(http.RequestMethod.POST, '/recall', JSON.stringify({ id }), 'application/json');
      const obj = JSON.parse(txt) as Record<string, Object>;
      return obj.ok === true;
    } catch (e) {
      return false;
    }
  }

  /** 掐掉旧连接：不这么做的话重连时旧 socket 的 close/error 还会再触发一轮重连，越堆越多 */
  private detachAndClose(): void {
    const ws = this.ws;
    this.ws = null;
    if (this.connectTimer !== -1) {
      clearTimeout(this.connectTimer);
      this.connectTimer = -1;
    }
    this.connecting = false;
    if (ws === null) {
      return;
    }
    try {
      ws.off('open');
      ws.off('message');
      ws.off('close');
      ws.off('error');
    } catch (e) {
      // 老系统不支持 off 就算了
    }
    try {
      ws.close();
    } catch (e) {
      // 已经断了就算了
    }
  }

  /** EntryAbility 在 onForeground/onBackground 里调用 */
  static notifyForeground(fg: boolean): void {
    ChatClient.liveClients.forEach((c: ChatClient) => {
      c.fg = fg;
      c.sendState();
    });
  }

  /** 把前后台状态发给服务端：后台时服务端才会补一条推送 */
  private sendState(): void {
    if (this.ws && this.wsOpen) {
      try {
        const p = new StatePayload();
        p.fg = this.fg;
        this.ws.send(JSON.stringify(p), (e: BusinessError) => {
          if (e) {
            // 状态丢了不影响主流程，重连后会再发一次
          }
        });
      } catch (e) {
        // 忽略
      }
    }
  }

  connect(): void {
    ChatClient.liveClients.add(this);
    this.closed = false;
    this.detachAndClose();
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    this.connecting = true;
    // 卡在「连接中」多半是 TCP 建起来了但隧道那头没回，connect 回调要等系统超时（能到一两分钟）。
    // 自己掐个 8 秒的闸，超时就当这次失败，重来。
    this.connectTimer = setTimeout(() => {
      this.connectTimer = -1;
      if (this.connecting) {
        this.detachAndClose();
        this.onState('error');
        this.scheduleReconnect();
      }
    }, 8000);

    ws.on('open', (err: BusinessError, value: Object) => {
      this.connecting = false;
      if (this.connectTimer !== -1) {
        clearTimeout(this.connectTimer);
        this.connectTimer = -1;
      }
      this.wsOpen = true;
      this.retry = 0;
      this.onState('online');
      this.flushOutbox();
      this.sendState();
      const hello = new HelloPayload();
      hello.token = Config.TOKEN;
      ws.send(JSON.stringify(hello), (e: BusinessError) => {
        if (e) {
          this.onState('error');
        }
      });
      if (this.opened) {
        this.onReconnect();
      } else {
        this.opened = true;
      }
    });

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value !== 'string') {
        return;
      }
      try {
        const obj = JSON.parse(value) as ChatMessage;
        if (obj && (obj.text || obj.image || obj.sticker || obj.audio) && (obj.role === 'her' || obj.role === 'me')) {
          this.onMessage(obj);
          return;
        }
        const rec = JSON.parse(value) as Record<string, Object>;
        if (rec.type === 'recall') {
          this.onRecall(String(rec.id ?? ''));
          return;
        }
        if (rec.type === 'threads') {
          this.onThreads(rec.list as Thread[]);
          return;
        }
        if (rec.type === 'typing') {
          this.onTyping(String(rec.threadId ?? 'main'), rec.on === true);
        }
      } catch (e) {
        // ignore malformed
      }
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      this.connecting = false;
      this.wsOpen = false;
      this.onState('offline');
      this.scheduleReconnect();
    });

    ws.on('error', (err: BusinessError) => {
      this.connecting = false;
      this.wsOpen = false;
      this.onState('error');
      this.scheduleReconnect();
    });

    ws.connect(this.serverUrl, (err: BusinessError) => {
      if (err) {
        this.connecting = false;
        this.onState('error');
        this.scheduleReconnect();
      }
    });
  }

  private scheduleReconnect(): void {
    if (this.closed) {
      return;
    }
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
    }
    this.retry += 1;
    const delay = this.retry <= 1 ? 200 : Math.min(1000 * Math.pow(2, this.retry - 2), 8000);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connect();
    }, delay);
  }

  /** 读当前音色 + 可选列表 */
  async loadVoice(): Promise<VoiceState> {
    const txt = await this.request(http.RequestMethod.GET, '/voice');
    const obj = JSON.parse(txt) as VoiceState;
    if (!Array.isArray(obj.voices)) {
      obj.voices = [];
    }
    return obj;
  }

  /** 切换音色（服务端持久化，之后所有合成都用它） */
  async setVoice(id: string): Promise<VoiceState> {
    const txt = await this.request(http.RequestMethod.POST, '/voice',
      JSON.stringify({ voice: id }), 'application/json');
    const obj = JSON.parse(txt) as VoiceState;
    if (obj.ok === false) {
      throw new Error(obj.error || '切换失败');
    }
    if (!Array.isArray(obj.voices)) {
      obj.voices = [];
    }
    return obj;
  }

  async loadStorage(): Promise<string> {
    const st = await this.loadStorageStats();
    return st.images;
  }

  async loadStorageStats(): Promise<StorageStats> {
    try {
      const txt = await this.request(http.RequestMethod.GET, '/storage');
      const obj = JSON.parse(txt) as StorageInfo;
      const part = (p?: StoragePart, unit: string = '张'): string => {
        if (!p) return '--';
        const kb = p.bytes / 1024;
        const size = kb < 1024 ? `${kb.toFixed(0)} KB` : `${(kb / 1024).toFixed(1)} MB`;
        return `${p.files} ${unit} · ${size}`;
      };
      return { images: part(obj.images), audio: part(obj.audio, '条') };
    } catch (e) {
      const msg = `E:${(e as Error).message}`.substring(0, 20);
      return { images: msg, audio: msg };
    }
  }

  send(text: string, image?: string, quote?: QuoteRef, sticker?: string,
    audio?: string, audioMs?: number): void {
    if (!this.ws) {
      return;
    }
    const payload = new SayPayload();
    payload.threadId = this.currentThread;
    payload.text = text;
    payload.ts = String(Date.now());
    if (image) {
      payload.image = image;
    }
    if (sticker) {
      payload.sticker = sticker;
    }
    if (audio) {
      payload.audio = audio;
      if (audioMs && audioMs > 0) {
        payload.audioMs = audioMs;
      }
    }
    if (quote) {
      payload.quote = quote;
    }
    payload.cid = `c${Date.now()}_${++this.seq}`;
    const raw = JSON.stringify(payload);
    if (this.ws && this.wsOpen) {
      this.sendRaw(raw);
    } else {
      // 断线时先存着，连上后按顺序补发，免得白打一遍字
      this.outbox.push(raw);
      this.onState('offline');
      this.scheduleReconnect();
    }
  }

  /** 发一帧；失败就留在 outbox 里，等下次重连补 */
  private sendRaw(raw: string): void {
    if (!this.ws) {
      this.outbox.push(raw);
      return;
    }
    this.ws.send(raw, (err: BusinessError) => {
      if (err) {
        this.outbox.push(raw);
        this.wsOpen = false;
        this.onState('error');
        this.scheduleReconnect();
      }
    });
  }

  /** 连上之后把攒着的按顺序补发 */
  private flushOutbox(): void {
    if (this.outbox.length === 0 || !this.ws) {
      return;
    }
    const pending = this.outbox;
    this.outbox = [];
    for (const raw of pending) {
      this.ws.send(raw, (err: BusinessError) => {
        if (err) {
          this.outbox.push(raw);
        }
      });
    }
  }

  /** 还有多少条没送出去（设置页/调试用） */
  pendingCount(): number {
    return this.outbox.length;
  }

  close(): void {
    ChatClient.liveClients.delete(this);
    this.closed = true;
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.detachAndClose();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
}
