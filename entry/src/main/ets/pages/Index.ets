import { ChatClient, ChatMessage, QuoteRef, StickerItem, StorageStats, Thread, VoiceOption, WorkspaceOption } from '../services/ChatClient';
import { CHIBI_PROMPT, CHIBI_SUMMARY, CHIBI_TAGS, MATURE_PROMPT, MATURE_SUMMARY, MATURE_TAGS, WHALE_SOURCE_REPO, WHALE_SOURCE_URL } from '../common/WhaleInfo';
import { KeyboardAvoidMode, window, curves, ComponentUtils, uiMaterial } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { promptAction } from '@kit.ArkUI';
import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import matrix4 from '@ohos.matrix4';
import { preferences } from '@kit.ArkData';
import { pushService } from '@kit.PushKit';
import { motion } from '@kit.MultimodalAwarenessKit';

interface SelOption {
  value: string;
}

/** 气泡里的富文本片段：普通文字，或者一张小表情 */
interface RichPart {
  kind: string;
  value: string;
}

@Entry
@Component
struct Index {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State status: string = '连接中';
  @State threads: Thread[] = [];
  @State workspaces: WorkspaceOption[] = [];
  @State current: string = 'main';
  @State showSidebar: boolean = true;
  /** 折叠态侧栏浮层的退出动画：0=在位上，-1=已滑出 */
  @State sbX: number = 0;
  @State sbClosing: boolean = false;
  private sbTimer: number = -1;
  @State uploading: boolean = false;
  @State showWsPicker: boolean = false;
  @State typing: boolean = false;
  @State dotCount: number = 1;
  @State foldT: number = 0;
  private client: ChatClient = new ChatClient();
  private scroller: Scroller = new Scroller();
  private lastSentText: string = '';
  private lastSentImage: string = '';
  private lastSentTs: number = 0;
  private userToggledSidebar: boolean = false;
  private inputCtrl: TextInputController = new TextInputController();
  private richCtrl: RichEditorController = new RichEditorController();
  /** 输入框里按顺序插进去的小表情文件名，用来还原成 [e:xxx] */
  private inlineOrder: string[] = [];
  @State inputHasImg: boolean = false;
  @State winW: number = 800;
  // 折叠机展开状态：true = 展开（大屏，侧栏并排）；false = 折叠（窄屏，侧栏浮层）
  @State foldExpanded: boolean = true;
  /** 折叠态侧栏实测宽度（并排态要沿用同一个值） */
  @State foldedPanelW: number = 0;
  @State previewSrc: string = '';
  @State quoteText: string = '';
  @State quoteImage: string = '';
  @State showSettings: boolean = false;
  @State stClosing: boolean = false;
  @State showAbout: boolean = false;
  @State matOk: boolean = false;
  private matThin: uiMaterial.ImmersiveMaterial | undefined = undefined;
  /** 头部头像飞进介绍页头像卡的位移与缩放 */
  @State aboutAvX: number = 0;
  @State aboutAvY: number = 0;
  @State aboutAvScale: number = 1;
  @State aboutFade: number = 1;
  @State aboutContent: number = 1;
  @State aboutFlyVis: boolean = false;
  @State aboutFlyX: number = 0;
  @State aboutFlyY: number = 0;
  @State aboutFlyScale: number = 1;
  @State aboutFlyPx: number = 0;
  @State aboutFlyPy: number = 0;
  @State stickers: StickerItem[] = [];
  @State stickerTab: string = 'inline';
  /** 各聊天区的未读数（threadId -> n），侧栏收起时在 ☰ 上落一个红点 */
  @State unread: Record<string, number> = {};
  /** 各聊天区最近一页消息的内存缓存：切回来先秒出，再后台刷新 */
  private threadCache: Map<string, ChatMessage[]> = new Map();
  private threadHasMore: Map<string, boolean> = new Map();
  private cacheStore: preferences.Preferences | null = null;
  private cacheLoaded: boolean = false;
  @State showStickers: boolean = false;
  @State cacheSize: string = '--';
  @State storageInfo: string = '--';
  @State audioStorage: string = '--';
  /** 音色：当前选中的 id、可选列表、选择面板开关 */
  @State voiceId: string = 'hutao';
  @State voiceOptions: VoiceOption[] = [];
  @State showVoice: boolean = false;
  @State vcClosing: boolean = false;
  @State voiceBusy: boolean = false;
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  @State splash: boolean = true;
  @State splashOpacity: number = 1;
  @State splashScale: number = 0.84;
  @State splashFrame: number = 0;
  private splashAt: number = 0;
  private splashLeaving: boolean = false;
  @State splashDot: number = 0;
  private splashTimer: number = -1;
  private afterSplash: Array<() => void> = [];
  private typingGuard: number = -1;
  @State splashTitle: number = 1;
  @State splashBg: number = 1;
  @State flyX: number = 0;
  @State flyY: number = 0;
  @State flySize: number = 96;
  @State flyRadius: number = 22;
  /** 握持手：right / left / both / none，用来把常用控件挪到顺手的一侧 */
  @State holdSide: string = 'right';
  /** 智感握持开关，用户可在设置里关掉 */
  @State holdEnabled: boolean = true;
  private holdBound: boolean = false;
  private holdTimer: number = -1;
  @State kbInset: number = 0;
  @State bounceId: string = '';
  /** 语音：正在播的那条消息 id，空串=没在播 */
  @State playingId: string = '';
  /** 暂停中的那条（再点同一气泡继续播） */
  private pausedId: string = '';
  /** 语音播放位置，ms；只在播放中变化 */
  @State voicePos: number = 0;
  /** 当前这条的真实时长，ms（播放器回报，拿不到就用 audioMs） */
  private voiceDurMs: number = 0;
  /** 波形高度，写死一份，避免每帧重算 */
  private readonly voiceBars: number[] = [7, 11, 6, 14, 9, 16, 8, 12, 6, 15, 10, 13, 7, 11, 9, 15, 6, 12];
  private avPlayer: media.AVPlayer | null = null;

  /** 录音：按住说话 */
  @State recOn: boolean = false;
  @State recSec: number = 0;
  @State recHint: string = '';
  private recorder: media.AVRecorder | null = null;
  private recPath: string = '';
  private recStartAt: number = 0;
  private recTimer: number = -1;
  private recPreparing: boolean = false;
  private recFd: number = -1;
  @State bounceScale: number = 1;
  @State hasMore: boolean = true;
  /** 上一次「连上就补历史」的时间：连接抖动时不至于每 3 秒拉一遍 */
  private lastSyncAt: number = 0;
  @State loadingOlder: boolean = false;

  /** 侧滑返回：先逐层收浮层，最后在聊天页要连滑两次才退出 */
  private exitArmedAt: number = 0;

  onBackPress(): boolean {
    if (this.showAbout) {
      this.closeAbout();
      return true;
    }
    if (this.showVoice) {
      this.closeVoice();
      return true;
    }
    if (this.showSettings) {
      this.closeSettings();
      return true;
    }
    if (this.previewSrc !== '') {
      this.previewSrc = '';
      return true;
    }
    if (this.showWsPicker) {
      this.showWsPicker = false;
      return true;
    }
    if (this.showStickers) {
      this.showStickers = false;
      return true;
    }
    if (this.quoteText !== '' || this.quoteImage !== '') {
      this.quoteText = '';
      this.quoteImage = '';
      return true;
    }
    if (this.kbInset > 0) {
      try {
        this.richCtrl.stopEditing();
      } catch (e) {
        // 输入法已经收起就不用管
      }
      return true;
    }
    if (this.sidebarOverlay() && this.showSidebar) {
      this.closeSidebarOverlay();
      return true;
    }
    const now: number = Date.now();
    if (this.exitArmedAt > 0 && now - this.exitArmedAt < 2000) {
      this.exitArmedAt = 0;
      return false;
    }
    this.exitArmedAt = now;
    promptAction.showToast({ message: '再滑一次退出大肥鱼', duration: 1600 });
    return true;
  }

  private kbTimer: number = -1;

  // 键盘高度做 260ms ease-out 补间：直接赋值在这台机器上不产生过渡
  private tweenKb(target: number): void {
    if (this.kbTimer >= 0) {
      clearInterval(this.kbTimer);
      this.kbTimer = -1;
    }
    const from: number = this.kbInset;
    const dur: number = 300;
    const t0: number = Date.now();
    this.kbTimer = setInterval(() => {
      const k: number = Math.min(1, (Date.now() - t0) / dur);
      const e: number = 1 - Math.pow(1 - k, 3);
      this.kbInset = from + (target - from) * e;
      if (k >= 1) {
        clearInterval(this.kbTimer);
        this.kbTimer = -1;
        this.kbInset = target;
      }
    }, 16);
  }

    // 底部让位：表情包由占位负责，这里只补键盘（两者不再叠加）
  private bottomInset(): number {
    return this.kbInset;
  }

  aboutToAppear(): void {
    try {
      this.matOk = uiMaterial.isImmersiveMaterialSupported();
      const info = uiMaterial.getMaterialInfo();
      console.info('[mat] supported=' + this.matOk + ' state=' + info.state + ' type=' + info.type);
      if (this.matOk) {
        this.matThin = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
      }
    } catch (e) {
      console.info('[mat] probe failed: ' + JSON.stringify(e));
    }
    this.startPulse();
    setTimeout(() => {
      this.refreshVoice();
    }, 1500);
    // 开屏：头像从 0.84 弹到 1，至少让它演完再退场
    this.splashAt = Date.now();
    setTimeout(() => {
      animateTo({ duration: 860, curve: curves.springMotion(0.55, 0.95) }, () => {
        this.splashScale = 1;
      });
    }, 60);
    this.splashTimer = setInterval(() => {
      this.splashDot = (this.splashDot + 1) % 3;
    }, 320);
    // 仓库不自带字体，界面走系统默认字体。
    // 想用 Noto Sans SC：把 .otf 放到 rawfile/fonts/ 并在此处 registerFont，同时附上 OFL 许可文本。
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    } catch (e) {
      // 老系统不支持就不管
    }
    // 折叠态屏幕窄，默认把侧栏收起来
    try {
      const w = px2vp(display.getDefaultDisplaySync().width);
      this.foldExpanded = w >= 700;
      this.showSidebar = w >= 700;
    } catch (e) {
      this.showSidebar = true;
    }
    try {
      const st: display.FoldStatus = display.getFoldStatus();
      if (st === display.FoldStatus.FOLD_STATUS_FOLDED || st === display.FoldStatus.FOLD_STATUS_HALF_FOLDED) {
        this.foldExpanded = false;
        this.showSidebar = false;
      }
    } catch (e) {
      // 非折叠机：沿用宽度判断
    }
    this.syncSettingsStats();
    this.loadFoldedW();
    this.watchFold();
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        try {
          const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          this.safeTop = px2vp(sys.topRect.height);
          this.safeBottom = px2vp(sys.bottomRect.height);
        } catch (e) {
          // 拿不到就按 0 处理
        }
        win.on('keyboardHeightChange', (h: number) => {
          const target = h > 0 ? px2vp(h) : 0;
          this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, () => {
            if (target > 0) {
              this.showStickers = false;
            }
            this.kbInset = target;
          });
          if (h > 0) {
            setTimeout(() => {
              this.scrollToBottom();
            }, 300);
          }
        });
      });
    } catch (e) {
      // 忽略
    }
    this.scrollToBottom();
    // 先用盘里的缓存把界面铺上，别等网络
    this.bootFromDisk();
    this.syncPushToken();
    // 连不上（电脑关机 / 网断了）也先把界面放出来，别一直卡在开屏
    setTimeout(() => {
      this.dismissSplash();
    }, 5000);

    this.client.onState = (s: string) => {
      this.status = s === 'online' ? '在线' : s === 'offline' ? '已断开 · 电脑没开？' : '连接中';
      if (s === 'online') {
        this.dismissSplash();
        // 连上就把历史补齐。断线期间漏的消息、以及断线时拉历史失败留下的一片空白，都靠这一下。
        // 连接抖动时会连着 open 好几次，这里 4 秒内只补一次。
        const sync = () => {
          const now = Date.now();
          if (now - this.lastSyncAt > 4000) {
            this.lastSyncAt = now;
            this.refreshThreads();
          }
        };
        if (this.splash) {
          this.afterSplash.push(sync);
        } else {
          sync();
        }
      }
    };
    this.client.onMessage = (m: ChatMessage) => {
      if (m.threadId && m.threadId !== this.current) {
        if (m.role === 'her') {
          const next: Record<string, number> = {};
          for (const k of Object.keys(this.unread)) {
            next[k] = this.unread[k];
          }
          next[m.threadId] = (next[m.threadId] ?? 0) + 1;
          this.unread = next;
        }
        return;
      }
      // 同一条消息的更新（比如语音转文字补上了）直接替换，不新增
      const sameId = this.messages.findIndex((x: ChatMessage) => x.id === m.id);
      if (sameId >= 0) {
        this.messages[sameId] = m;
        this.messages = this.messages.slice();
        return;
      }
      if (m.role === 'me') {
        // 自己刚发出去的那条：用服务端的正式消息替换本地临时消息。
        // 不替换的话会并排出现两条一样的，而且临时 id 撤不回。
        // 语音那条：本地先插一条空文字的临时消息，服务端转完文字才回传，
        // 所以不能比文字，只比音频文件（内容寻址，同一个文件就是同一条）
        const i = this.messages.findIndex((x: ChatMessage) => x.role === 'me' &&
          (x.audio || m.audio
            ? (x.audio ?? '') === (m.audio ?? '')
            : x.text === m.text && (x.image ?? '') === (m.image ?? '') &&
              (x.sticker ?? '') === (m.sticker ?? '')) &&
          Math.abs(m.ts - x.ts) < 15000);
        if (i >= 0) {
          this.messages[i] = m;
          this.messages = this.messages.slice();
          return;
        }
      }
      this.messages.push(m);
      this.messages = this.messages.slice();
      if (m.role !== 'me') {
        this.typing = false;
        if (this.typingGuard > 0) {
          clearTimeout(this.typingGuard);
          this.typingGuard = -1;
        }
      }
      this.scrollToBottom();
      // 表情包的高度要等图片解码后才定下来，再补一次滚到底
      if (m.sticker) {
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 900);
      }
    };
    this.client.onRecall = (id: string) => {
      const i = this.messages.findIndex((x: ChatMessage) => x.id === id);
      if (i >= 0) {
        this.messages[i].recalled = true;
        this.messages = this.messages.slice();
      }
    };
    this.client.onThreads = (list: Thread[]) => {
      this.threads = list;
    };
    this.client.onTyping = (threadId: string, on: boolean) => {
      if (threadId !== this.current) {
        return;
      }
      animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.typing = on;
      });
      if (on) {
        this.scrollToBottom();
      }
    };
    setInterval(() => {
      this.dotCount = (this.dotCount % 3) + 1;
    }, 420);

    // 先问一下公告栏现在用哪个地址（隧道重启会换），再连。
    // 但公告栏那边不理我们的时候不能把启动卡死：2.5 秒没回来就先用老地址直连。
    let started = false;
    const startConnect = (): void => {
      if (started) {
        return;
      }
      started = true;
      this.client.connect();
    };
    setTimeout(() => {
      startConnect();
    }, 2500);
    startConnect();
    this.client.loadWorkspaces().then((list: WorkspaceOption[]) => {
      this.workspaces = list;
    });
    this.client.loadStickers().then((list: StickerItem[]) => {
      this.stickers = list;
    });
  }

  aboutToDisappear(): void {
    try {
      motion.off('holdingHandChanged');
    } catch (e) {
      // 没订阅成功过就算了
    }
    if (this.pulseTimer >= 0) {
      clearInterval(this.pulseTimer);
      this.pulseTimer = -1;
    }
    this.client.close();
  }

  // 从推送通知点进来：Ability 把 threadId 放到 AppStorage
  private consumeOpenThread(): void {
    const tid: string = AppStorage.get<string>('openThread') ?? '';
    if (tid.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>('openThread', '');
    if (tid === this.current) {
      return;
    }
    if (this.threads.some((t) => t.id === tid)) {
      this.switchThread(tid);
    }
  }

  private async refreshThreads(): Promise<void> {
    const list = await this.client.loadThreads();
    if (list.length === 0 && this.threads.length > 0) {
      // 没拉到就别拿空数组把侧栏抹了，等下一次
      return;
    }
    this.threads = list;
    if (list.length > 0 && !list.some((t) => t.id === this.current)) {
      this.current = list[0].id;
    }
    this.persistThreads();
    this.client.currentThread = this.current;
    this.consumeOpenThread();
    const ids: string[] = [];
    for (const t of list) {
      ids.push(t.id);
    }
    await this.hydrateCache(ids);
    const warm: ChatMessage[] | undefined = this.threadCache.get(this.current);
    if (warm && warm.length > 0) {
      this.messages = warm;
      this.hasMore = this.threadHasMore.get(this.current) ?? true;
      this.jumpToLatest();
      this.dismissSplash();
      this.afterSplash.push(() => { this.reloadMessages(); });
    } else {
      await this.reloadMessages();
    }
    this.watchHoldingHand();
    this.prefetchOtherThreads();
  }

  /** 开机第一帧：不等网络，先从盘里把上次的会话列表和最后一页铺上 */
  private async bootFromDisk(): Promise<void> {
    try {
      if (!this.cacheStore) {
        this.cacheStore = await preferences.getPreferences(getContext(this), 'im_thread_cache');
      }
    } catch (e) {
      this.cacheStore = null;
      return;
    }
    const store = this.cacheStore;
    try {
      const rawThreads: string = store.getSync('threads', '') as string;
      if (rawThreads && rawThreads.length > 3) {
        const arr = JSON.parse(rawThreads) as Thread[];
        if (Array.isArray(arr) && arr.length > 0 && this.threads.length === 0) {
          this.threads = arr;
        }
      }
      this.holdEnabled = store.getSync('hold_enabled', true) as boolean;
      const last: string = store.getSync('current', '') as string;
      if (last.length > 0 && this.current === 'main') {
        this.current = last;
      }
      this.client.currentThread = this.current;
      const cached: string = store.getSync(`c_${this.current}`, '') as string;
      if (cached && cached.length > 3) {
        const arr2 = JSON.parse(cached) as ChatMessage[];
        if (Array.isArray(arr2) && arr2.length > 0) {
          this.messages = arr2;
          this.threadCache.set(this.current, arr2);
          this.hasMore = store.getSync(`h_${this.current}`, true) as boolean;
          this.jumpToLatest();
        }
      }
    } catch (e) {
      // 盘上的数据坏了就当没有
    }
  }

  private saveHoldPref(on: boolean): void {
    if (!this.cacheStore) {
      return;
    }
    try {
      this.cacheStore.putSync('hold_enabled', on);
      this.cacheStore.flush();
    } catch (e) {
      // 写失败无所谓
    }
  }

  /** 会话列表和当前会话也记一份，冷启动先按这个画 */
  private persistThreads(): void {
    if (!this.cacheStore) {
      return;
    }
    try {
      this.cacheStore.putSync('threads', JSON.stringify(this.threads));
      this.cacheStore.putSync('current', this.current);
      this.cacheStore.flush();
    } catch (e) {
      // 写失败无所谓
    }
  }

  /** 冷启动把上次存的每个会话最后一页读回内存，做到首屏也秒开 */
  private async hydrateCache(ids: string[]): Promise<void> {
    if (this.cacheLoaded) {
      return;
    }
    this.cacheLoaded = true;
    try {
      this.cacheStore = await preferences.getPreferences(getContext(this), 'im_thread_cache');
    } catch (e) {
      this.cacheStore = null;
      return;
    }
    for (const id of ids) {
      try {
        const raw: string = this.cacheStore.getSync(`c_${id}`, '') as string;
        if (!raw || raw.length < 3) {
          continue;
        }
        const arr = JSON.parse(raw) as ChatMessage[];
        if (Array.isArray(arr) && arr.length > 0 && !this.threadCache.has(id)) {
          this.threadCache.set(id, arr);
          this.threadHasMore.set(id, this.cacheStore.getSync(`h_${id}`, true) as boolean);
        }
      } catch (e) {
        // 某一条坏了就跳过
      }
    }
  }

  /** 把某一页写盘（只留最近 40 条，别把 preferences 撑爆） */
  private saveCache(id: string): void {
    if (!this.cacheStore) {
      return;
    }
    const list: ChatMessage[] = this.threadCache.get(id) ?? [];
    if (list.length === 0) {
      return;
    }
    try {
      this.cacheStore.putSync(`c_${id}`, JSON.stringify(list.slice(-40)));
      this.cacheStore.putSync(`h_${id}`, this.threadHasMore.get(id) ?? true);
      this.cacheStore.flush();
    } catch (e) {
      // 写失败不影响用
    }
  }

  /** 后台把别的聊天区的最近一页拉进缓存，切过去时不用等网络 */
  private async prefetchOtherThreads(): Promise<void> {
    const ids: string[] = [];
    for (const t of this.threads) {
      if (t.id !== this.current && !this.threadCache.has(t.id)) {
        ids.push(t.id);
      }
    }
    for (const id of ids) {
      try {
        const page = await this.client.loadHistory(id, 30);
        if (page.ok && !this.threadCache.has(id)) {
          this.threadCache.set(id, page.list);
          this.threadHasMore.set(id, page.hasMore);
        }
      } catch (e) {
        // 预取失败就算了，真切过去再拉
      }
    }
  }

  /** 设置里切换智感握持 */
  private setHoldEnabled(on: boolean): void {
    if (on === this.holdEnabled) {
      return;
    }
    this.holdEnabled = on;
    this.saveHoldPref(on);
    if (!on) {
      try {
        motion.off('holdingHandChanged');
      } catch (e) {
        // 没订阅成功也没关系
      }
      this.holdBound = false;
      if (this.holdTimer >= 0) {
        clearTimeout(this.holdTimer);
        this.holdTimer = -1;
      }
      this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
        this.holdSide = 'right';
      });
    } else {
      this.holdBound = false;
      this.watchHoldingHand();
    }
  }

  /** 订阅华为智感握姿：手机拿在左手就把输入条翻到左边 */
  private watchHoldingHand(): void {
    if (this.holdBound || !this.holdEnabled) {
      return;
    }
    this.holdBound = true;
    try {
      motion.on('holdingHandChanged', (st: number) => {
        // 3=双手 0/16=放下或未识别：都保持当前布局，别左右乱跳
        if (st !== motion.HoldingHandStatus.LEFT_HAND_HELD && st !== motion.HoldingHandStatus.RIGHT_HAND_HELD) {
          return;
        }
        const next: string = st === motion.HoldingHandStatus.LEFT_HAND_HELD ? 'left' : 'right';
        console.info('[HOLD] status=' + st + ' side=' + next);
        // 手来回挪的时候会连发好几次，稳 600ms 再换，避免界面抖
        if (this.holdTimer >= 0) {
          clearTimeout(this.holdTimer);
        }
        this.holdTimer = setTimeout(() => {
          if (next !== this.holdSide) {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.holdSide = next;
            });
          }
        }, 600);
      });
      console.info('[HOLD] subscribed');
    } catch (e) {
      console.info('[HOLD] subscribe failed: ' + JSON.stringify(e));
    }
  }

  /** 左手握持时，把控件挪到左边 */
  private leftHold(): boolean {
    return this.holdSide === 'left';
  }

  private dismissSplash(): void {
    if (!this.splash || this.splashLeaving) {
      return;
    }
    this.splashLeaving = true;
    if (this.splashTimer >= 0) {
      clearInterval(this.splashTimer);
      this.splashTimer = -1;
    }
    // 开屏至少要演满 1.6 秒，把加载时间藏在这段动画里
    const hold: number = Math.max(0, 1600 - (Date.now() - this.splashAt));
    setTimeout(() => {
      // 图标从屏幕中间缩到顶栏那个小圆头像上，落地后整层淡出
      const d: number[] = this.flightDelta();
      const ok: boolean = d.length === 2;
      // 文字先走，别和飞过去的图标叠在一起
      animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
        this.splashTitle = 0;
      });
      animateTo({ duration: 460, curve: Curve.FastOutSlowIn }, () => {
        this.splashBg = 0;
        if (ok) {
          this.flyX = d[0];
          this.flyY = d[1];
          this.flySize = 42;
          this.flyRadius = 21;
          this.splashFrame = 1;
        }
      });
      setTimeout(() => {
        animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
          this.splashOpacity = 0;
        });
        setTimeout(() => {
          this.splash = false;
          const q: Array<() => void> = this.afterSplash;
          this.afterSplash = [];
          q.forEach((f: () => void) => { try { f(); } catch (e) {} });
          this.flyX = 0;
          this.flyY = 0;
          this.flySize = 96;
          this.flyRadius = 22;
          this.splashTitle = 1;
          this.splashBg = 1;
          this.splashFrame = 0;
        }, 220);
      }, ok ? 470 : 60);
    }, hold);
  }

  /** 开屏图标 → 顶栏头像的位移（vp），拿不到布局就返回空数组，退化成纯淡出 */
  private flightDelta(): number[] {
    try {
      const cu: ComponentUtils = this.getUIContext().getComponentUtils();
      const a = cu.getRectangleById('splashIcon');
      const b = cu.getRectangleById('hdrAvatar');
      if (b.size.width <= 0 || a.size.width <= 0) {
        return [];
      }
      const s: number = this.getUIContext().vp2px(1);
      const ax: number = a.windowOffset.x + a.size.width / 2;
      const ay: number = a.windowOffset.y + a.size.height / 2;
      const bx: number = b.windowOffset.x + b.size.width / 2;
      const by: number = b.windowOffset.y + b.size.height / 2;
      return [(bx - ax) / s, (by - ay) / s];
    } catch (e) {
      return [];
    }
  }

  /** 打开介绍页：先让它按原位排好，再量两个头像的落点 */
  private openAbout(): void {
    this.aboutAvX = 0;
    this.aboutAvY = 0;
    this.aboutAvScale = 1;
    this.aboutFade = 1;
    // 先进页面：内容透明、浮层头像从顶栏位置起飞
    this.aboutContent = 0;
    this.showAbout = true;
    setTimeout(() => {
      const r: number[] = this.aboutHeroRect();
      if (r.length !== 3) {
        this.aboutContent = 1;
        this.aboutFlyVis = false;
        return;
      }
      this.aboutFlyPx = r[0];
      this.aboutFlyPy = r[1];
      const d: number[] = this.aboutAvatarDelta();
      if (d.length !== 3) {
        this.aboutContent = 1;
        this.aboutFlyVis = false;
        return;
      }
      this.aboutFlyVis = true;
      this.aboutFlyX = d[0];
      this.aboutFlyY = d[1];
      this.aboutFlyScale = d[2];
      setTimeout(() => {
        // 第一段：头像从顶栏飞到介绍页里的位置
        animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
          this.aboutFlyX = 0;
          this.aboutFlyY = 0;
          this.aboutFlyScale = 1;
        });
        // 第二段：落位之后内容再淡进来
        setTimeout(() => {
          animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
            this.aboutContent = 1;
          });
          setTimeout(() => {
            this.aboutFlyVis = false;
          }, 240);
        }, 330);
      }, 40);
    }, 16);
  }

  private closeAbout(): void {
    // 退出保持原来的做法：头像边飞边缩回顶栏，整页同时淡出
    const r: number[] = this.aboutHeroRect();
    const d: number[] = this.aboutAvatarDelta();
    if (r.length !== 3 || d.length !== 3) {
      this.showAbout = false;
      this.aboutContent = 1;
      return;
    }
    this.aboutFlyPx = r[0];
    this.aboutFlyPy = r[1];
    this.aboutFlyX = 0;
    this.aboutFlyY = 0;
    this.aboutFlyScale = 1;
    this.aboutFlyVis = true;
    setTimeout(() => {
      animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
        this.aboutFlyX = d[0];
        this.aboutFlyY = d[1];
        this.aboutFlyScale = d[2];
        this.aboutContent = 0;
        // 整层（含背景渐变）一起淡，不然会看成「先飞走、页面才消失」
        this.aboutFade = 0;
      });
      setTimeout(() => {
        this.showAbout = false;
        this.aboutFlyVis = false;
        this.aboutFlyX = 0;
        this.aboutFlyY = 0;
        this.aboutFlyScale = 1;
        this.aboutContent = 1;
        this.aboutFade = 1;
      }, 330);
    }, 30);
  }

  private aboutHeroRect(): number[] {
    try {
      const cu: ComponentUtils = this.getUIContext().getComponentUtils();
      const a = cu.getRectangleById('aboutHeroAvatar');
      if (a.size.width <= 0) {
        return [];
      }
      const s: number = this.getUIContext().vp2px(1);
      return [(a.windowOffset.x + a.size.width / 2) / s, (a.windowOffset.y + a.size.height / 2) / s, a.size.width / s];
    } catch (e) {
      return [];
    }
  }

  private aboutAvatarDelta(): number[] {
    try {
      const cu: ComponentUtils = this.getUIContext().getComponentUtils();
      const a = cu.getRectangleById('aboutHeroAvatar');
      const b = cu.getRectangleById('hdrAvatar');
      if (a.size.width <= 0 || b.size.width <= 0) {
        return [];
      }
      const s: number = this.getUIContext().vp2px(1);
      const ax: number = a.windowOffset.x + a.size.width / 2;
      const ay: number = a.windowOffset.y + a.size.height / 2;
      const bx: number = b.windowOffset.x + b.size.width / 2;
      const by: number = b.windowOffset.y + b.size.height / 2;
      return [(bx - ax) / s, (by - ay) / s, b.size.width / a.size.width];
    } catch (e) {
      return [];
    }
  }

  private async reloadMessages(): Promise<void> {
    const page = await this.client.loadHistory(this.current);
    if (!page.ok) {
      // 没拉到就别拿空列表把现有聊天记录清了；等下一次连上再补
      return;
    }
    this.messages = page.list;
    this.hasMore = page.hasMore;
    this.threadCache.set(this.current, page.list);
    this.threadHasMore.set(this.current, page.hasMore);
    this.saveCache(this.current);
    this.jumpToLatest();
    this.dismissSplash();
  }

  private unreadTotal(): number {
    let n: number = 0;
    for (const k of Object.keys(this.unread)) {
      n += this.unread[k];
    }
    return n;
  }

  private async switchThread(id: string): Promise<void> {
    if (this.current === id) {
      return;
    }
    this.stopVoice();
    this.current = id;
    this.client.currentThread = id;
    this.persistThreads();
    if ((this.unread[id] ?? 0) > 0) {
      const next: Record<string, number> = {};
      for (const k of Object.keys(this.unread)) {
        if (k !== id) {
          next[k] = this.unread[k];
        }
      }
      this.unread = next;
    }
    this.typing = false;
    const cached: ChatMessage[] | undefined = this.threadCache.get(id);
    if (cached && cached.length > 0) {
      // 秒开：先用上次那一页垫着，再去拉最新的
      this.messages = cached;
      this.hasMore = this.threadHasMore.get(id) ?? true;
      this.jumpToLatest();
      this.reloadMessages();
    } else {
      this.messages = [];
      this.hasMore = true;
      await this.reloadMessages();
    }
  }

  /** 停掉语音（切会话、退出时用） */
  private stopVoice(): void {
    this.playingId = '';
    this.pausedId = '';
    this.voicePos = 0;
    if (this.avPlayer) {
      try {
        this.avPlayer.pause();
      } catch (e) {
      }
    }
  }

  /** 点语音气泡：播放 / 暂停 / 续播，全程共用一个 AVPlayer */
  private async playVoice(m: ChatMessage): Promise<void> {
    if (!m.audio) {
      return;
    }
    try {
      if (this.playingId === m.id) {
        this.playingId = '';
        this.pausedId = m.id;
        if (this.avPlayer) {
          this.avPlayer.pause();
        }
        return;
      }
      if (this.pausedId === m.id && this.avPlayer && this.avPlayer.state !== 'idle') {
        this.playingId = m.id;
        this.pausedId = '';
        this.avPlayer.play();
        return;
      }
      if (!this.avPlayer) {
        // 用播放器自己的 timeUpdate 推进度，约 100ms 一次，不另起定时器
        const p: media.AVPlayer = await media.createAVPlayer();
        p.on('stateChange', (state: string) => {
          if (state === 'initialized') {
            p.prepare();
          } else if (state === 'prepared') {
            p.play();
          } else if (state === 'completed') {
            this.playingId = '';
            this.pausedId = '';
            this.voicePos = 0;
          }
        });
        p.on('timeUpdate', (t: number) => {
          if (this.playingId === '') {
            return;
          }
          if (Math.floor(t / 100) === Math.floor(this.voicePos / 100)) {
            return;
          }
          this.voicePos = t;
        });
        p.on('durationUpdate', (d: number) => {
          if (d > 0) {
            this.voiceDurMs = d;
          }
        });
        p.on('error', (err: BusinessError) => {
          console.error(`[VOICE] ${err.code} ${err.message}`);
          this.playingId = '';
          this.pausedId = '';
        });
        this.avPlayer = p;
      } else if (this.avPlayer.state !== 'idle') {
        await this.avPlayer.reset();
      }
      this.playingId = m.id;
      this.pausedId = '';
      this.voicePos = 0;
      this.voiceDurMs = m.audioMs ?? 0;
      this.avPlayer.url = this.client.mediaUrl(m.audio);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[VOICE] play failed ${err.code} ${err.message}`);
      this.playingId = '';
      this.pausedId = '';
    }
  }

  /** 语音气泡上显示的秒数 */
  private voiceLen(m: ChatMessage): string {
    const ms: number = m.audioMs ?? 0;
    if (ms <= 0) {
      return '语音';
    }
    const s: number = Math.max(1, Math.round(ms / 1000));
    return `${s}″`;
  }

  /** 这条语音的总时长，ms */
  private voiceTotalMs(m: ChatMessage): number {
    if ((this.playingId === m.id || this.pausedId === m.id) && this.voiceDurMs > 0) {
      return this.voiceDurMs;
    }
    return m.audioMs ?? 0;
  }

  /** ms → m:ss */
  private fmtSec(ms: number): string {
    const total: number = Math.max(0, Math.round(ms / 1000));
    const mm: number = Math.floor(total / 60);
    const ss: number = total % 60;
    return `${mm}:${ss < 10 ? '0' : ''}${ss}`;
  }

  /** 气泡角落的时间：播放中显示「已播 / 总长」，否则只显示总长 */
  private voiceTime(m: ChatMessage): string {
    const total: string = this.fmtSec(this.voiceTotalMs(m));
    if (this.playingId === m.id || this.pausedId === m.id) {
      return `${this.fmtSec(this.voicePos)} / ${total}`;
    }
    return total;
  }

  /** 波形第 i 根是否已播过 */
  private voiceBarOn(m: ChatMessage, i: number): boolean {
    if (this.playingId !== m.id && this.pausedId !== m.id) {
      return false;
    }
    const total: number = this.voiceTotalMs(m);
    if (total <= 0) {
      return false;
    }
    const ratio: number = this.voicePos / total;
    return i / this.voiceBars.length < ratio;
  }

  private voiceBarOff(m: ChatMessage): string {
    return m.role === 'me' ? '#9DBBE4' : '#B9CDEC';
  }

  /** 语音气泡：播放键 + 波形进度 + 时间 */
  @Builder
  voiceBubble(m: ChatMessage) {
    Row({ space: 10 }) {
      Stack() {
        if (this.playingId === m.id) {
          Row({ space: 3 }) {
            Column().width(3).height(10).borderRadius(1.5).backgroundColor('#FFFFFF')
            Column().width(3).height(10).borderRadius(1.5).backgroundColor('#FFFFFF')
          }
        } else {
          Text('▶')
            .fontSize(10)
            .fontFamily('NotoSansSC')
            .fontColor('#FFFFFF')
            .margin({ left: 2 })
        }
      }
      .width(30)
      .height(30)
      .borderRadius(15)
      .backgroundColor(m.role === 'me' ? '#3A66B0' : '#4A76BE')
      .alignContent(Alignment.Center)

      Column({ space: 4 }) {
        Row({ space: 2.5 }) {
          ForEach(this.voiceBars, (h: number, i: number) => {
            Column()
              .width(3)
              .height(h)
              .borderRadius(1.5)
              .backgroundColor(this.voiceBarOn(m, i) ? '#3A66B0' : this.voiceBarOff(m))
          }, (h: number, i: number) => `${i}`)
        }
        .height(18)
        .alignItems(VerticalAlign.Center)

        Text(this.voiceTime(m))
          .fontSize(10)
          .fontFamily('NotoSansSC')
          .fontColor(m.role === 'me' ? '#3A66B0' : '#6E86AE')
          .opacity(0.85)
      }
      .alignItems(HorizontalAlign.End)
    }
    .padding({ left: 12, right: 14, top: 9, bottom: 9 })
    .backgroundColor(m.role === 'me' ? '#D8E9FF' : '#E9F0FB')
    .borderRadius(16)
    .onClick(() => {
      this.playVoice(m);
    })
  }

  /** 按住说话：按下开始录，松开发送 */
  private async startRecord(): Promise<void> {
    if (this.recOn || this.recPreparing || this.uploading) {
      return;
    }
    this.recPreparing = true;
    try {
      const at = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'];
      const res = await at.requestPermissionsFromUser(getContext(this), perms);
      const granted: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
      if (!granted) {
        this.flashStatus('要先给麦克风权限', 2400);
        return;
      }
      const dir: string = getContext(this).cacheDir;
      this.recPath = `${dir}/rec_${Date.now()}.m4a`;
      const file: fs.File = fs.openSync(this.recPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      this.recFd = file.fd;
      const rec: media.AVRecorder = await media.createAVRecorder();
      const profile: media.AVRecorderProfile = {
        audioBitrate: 32000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 16000,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4A,
      };
      const cfg: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: profile,
        url: `fd://${file.fd}`,
      };
      await rec.prepare(cfg);
      await rec.start();
      this.recorder = rec;
      this.recStartAt = Date.now();
      this.recSec = 0;
      this.recOn = true;
      this.recTimer = setInterval(() => {
        this.recSec = Math.floor((Date.now() - this.recStartAt) / 1000);
        if (this.recSec >= 60) {
          this.stopRecord(true);
        }
      }, 200);
    } catch (e) {
      const err = e as BusinessError;
      this.recOn = false;
      this.flashStatus(`录音失败:${err?.message ?? ''}`.slice(0, 40), 2600);
      this.closeRecFile();
    } finally {
      this.recPreparing = false;
    }
  }

  private closeRecFile(): void {
    if (this.recFd >= 0) {
      try {
        fs.closeSync(this.recFd);
      } catch (e) {
        // 已经关了就算了
      }
      this.recFd = -1;
    }
  }

  /** 结束录音：sendIt=true 就上传并当语音发出去 */
  private async stopRecord(sendIt: boolean): Promise<void> {
    if (!this.recOn) {
      return;
    }
    this.recOn = false;
    if (this.recTimer >= 0) {
      clearInterval(this.recTimer);
      this.recTimer = -1;
    }
    const ms: number = Date.now() - this.recStartAt;
    const rec = this.recorder;
    this.recorder = null;
    try {
      if (rec) {
        await rec.stop();
        await rec.release();
      }
    } catch (e) {
      // 停不下来就当没录上
    }
    this.closeRecFile();
    if (!sendIt) {
      try {
        fs.unlinkSync(this.recPath);
      } catch (e) {
      }
      return;
    }
    if (ms < 1200) {
      this.flashStatus('太短了，按住多说两秒', 2000);
      try {
        fs.unlinkSync(this.recPath);
      } catch (e) {
      }
      return;
    }
    this.uploading = true;
    this.status = '发语音…';
    try {
      const st = fs.statSync(this.recPath);
      const buf = new ArrayBuffer(st.size);
      const f: fs.File = fs.openSync(this.recPath, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const serverPath = await this.client.uploadAudio(buf);
      try {
        fs.unlinkSync(this.recPath);
      } catch (e) {
      }
      if (!serverPath) {
        this.flashStatus('语音上传失败');
        return;
      }
      const m: ChatMessage = {
        id: String(Date.now()),
        threadId: this.current,
        role: 'me',
        text: '',
        audio: serverPath,
        audioMs: ms,
        ts: Date.now(),
      };
      this.lastSentText = '';
      this.lastSentImage = '';
      this.lastSentTs = m.ts;
      this.messages.push(m);
      this.messages = this.messages.slice();
      this.client.send('', undefined, undefined, undefined, serverPath, ms);
      this.status = '在线';
      this.scrollToBottom();
    } catch (e) {
      const err = e as BusinessError;
      this.flashStatus(`语音失败:${err?.message ?? ''}`.slice(0, 40), 2600);
    } finally {
      this.uploading = false;
    }
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 320);
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 700);
  }

  /** 切会话/加载完历史后跳到最后一条：图片解码会继续撑高列表，所以多补几次 */
  private jumpToLatest(): void {
    const last: number = this.messages.length - 1;
    const jump = (): void => {
      if (last >= 0) {
        try {
          this.scroller.scrollToIndex(last, true, ScrollAlign.END);
        } catch (e) {
          this.scroller.scrollEdge(Edge.Bottom);
        }
      }
      this.scroller.scrollEdge(Edge.Bottom);
    };
    setTimeout(jump, 30);
    setTimeout(jump, 200);
    setTimeout(jump, 600);
    setTimeout(jump, 1200);
  }

  private quoteLine(text: string): string {
    const end = text.indexOf('〕');
    if (text.startsWith('〔引用：') && end > 0) {
      return text.substring(0, end + 1);
    }
    return '';
  }

  private quoteBody(text: string): string {
    if (text.startsWith('〔引用：')) {
      const nl = text.indexOf('\n');
      if (nl > 0) {
        return text.substring(nl + 1);
      }
    }
    return text;
  }

  private openPreview(src: string): void {
    animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.previewSrc = src;
    });
  }

  private closePreview(): void {
    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.previewSrc = '';
    });
  }

  private jelly(id: string): void {
    this.bounceId = id;
    this.bounceScale = 1.06;
    animateTo({ duration: 120, curve: Curve.Friction }, () => {
      this.bounceScale = 0.965;
    });
    setTimeout(() => {
      animateTo({ duration: 220, curve: curves.springMotion(0.45, 0.72) }, () => {
        this.bounceScale = 1;
      });
    }, 120);
    setTimeout(() => {
      if (this.bounceId === id) {
        this.bounceId = '';
      }
    }, 460);
  }

  private copyMessage(m: ChatMessage): void {
    if (!m.text) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, m.text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.status = '已复制';
      setTimeout(() => {
        if (this.status === '已复制') {
          this.status = '在线';
        }
      }, 1500);
    }).catch(() => {
      this.status = '复制失败';
    });
  }

  // 划到顶时往前翻一页，保持原来的第一屏不动
  private async loadOlder(): Promise<void> {
    if (this.loadingOlder || !this.hasMore || this.messages.length === 0) {
      return;
    }
    this.loadingOlder = true;
    const oldest = this.messages[0].ts;
    const tid = this.current;
    const page = await this.client.loadHistory(tid, 50, oldest);
    if (this.current !== tid) {
      this.loadingOlder = false;
      return;
    }
    if (page.list.length > 0) {
      this.messages = page.list.concat(this.messages);
      const keep = page.list.length;
      setTimeout(() => {
        this.scroller.scrollToIndex(keep);
      }, 40);
    }
    this.hasMore = page.hasMore;
    this.loadingOlder = false;
  }

  private fmtTime(ts: number): string {
    const d = new Date(ts);
    const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mm = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    return `${hh}:${mm}`;
  }

  /** 同一天算一组：用本地日期的 yyyy-m-d 当 key */
  private dayKey(ts: number): string {
    const d = new Date(ts);
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
  }

  /** 这一天在列表里要不要单独标个日期（换天了才标） */
  private isDayStart(i: number): boolean {
    if (i <= 0) {
      return true;
    }
    const prev = this.messages[i - 1];
    const cur = this.messages[i];
    if (!prev || !cur) {
      return true;
    }
    return this.dayKey(prev.ts) !== this.dayKey(cur.ts);
  }

  /** 日期分隔条上的字：今天 / 昨天 / 11月11日 / 2025年12月31日 */
  private dayLabel(ts: number): string {
    const now = new Date();
    const d = new Date(ts);
    const md = `${d.getMonth() + 1}月${d.getDate()}日`;
    const todayKey = `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
    if (this.dayKey(ts) === todayKey) {
      return `今天 · ${md}`;
    }
    const y = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    const yKey = `${y.getFullYear()}-${y.getMonth() + 1}-${y.getDate()}`;
    if (this.dayKey(ts) === yKey) {
      return `昨天 · ${md}`;
    }
    if (d.getFullYear() === now.getFullYear()) {
      return md;
    }
    return `${d.getFullYear()}年${md}`;
  }


  private canRecall(m: ChatMessage): boolean {
    return m.role === 'me' && !m.recalled && Date.now() - m.ts < 2 * 60 * 60 * 1000;
  }

  private recallMessage(m: ChatMessage): void {
    this.client.recall(m.id).then((ok: boolean) => {
      if (ok) {
        m.recalled = true;
        this.messages = this.messages.slice();
        this.flashStatus('已撤回');
      } else {
        this.flashStatus('撤回失败');
      }
    });
  }

  /** 标题下面那颗状态灯的颜色 */
  @State pulseOn: boolean = false;
  private pulseTimer: number = -1;

  private statusColor(): string {
    if (this.status.indexOf('在线') >= 0) return '#34C759';
    if (this.status.indexOf('断开') >= 0) return '#FF453A';
    if (this.status.indexOf('连接') >= 0) return '#FFB020';
    return '#9AA6BC';
  }

  // 副标题：宽度够就「状态 · 会话名」，太窄时优先保会话名（状态交给圆点表示）
  private subtitleText(): string {
    const picked: Thread | null = this.currentThread() ?? (this.threads.length > 0 ? this.threads[0] : null);
    const name: string = picked?.name ?? (this.threads.length === 0 ? '主聊天' : '');
    const chatW: number = this.winW - this.sideShift();
    if (chatW < 330) {
      if (this.status === '在线') return name;
      return this.status;
    }
    if (name.length === 0) return this.status;
    return `${this.status} · ${name}`;
  }

  private startPulse(): void {
    if (this.pulseTimer >= 0) return;
    this.pulseTimer = setInterval(() => {
      const on: boolean = !this.pulseOn;
      this.getUIContext().animateTo({ duration: 1500, curve: Curve.EaseInOut }, () => {
        this.pulseOn = on;
      });
    }, 1500);
  }

  /** 设置页：图片 / 音频占用一起拉 */
  /** 拿华为推送 token 并上报给服务端；没有 Push 权限/设备不支持就安静跳过 */
  private async syncPushToken(): Promise<void> {
    try {
      const token = await pushService.getToken();
      if (!token) return;
      const ok = await this.client.registerPushToken(token);
      console.info(`[PUSH] token registered ok=${ok} len=${token.length}`);
    } catch (e) {
      console.info(`[PUSH] getToken failed: ${JSON.stringify(e)}`);
    }
  }

  private syncSettingsStats(): void {
    this.client.loadStorageStats().then((v: StorageStats) => {
      this.storageInfo = v.images;
      this.audioStorage = v.audio;
    }).catch(() => {
      this.storageInfo = '--';
      this.audioStorage = '--';
    });
  }

  private async refreshCacheSize(): Promise<void> {
    try {
      const dir = getContext(this).cacheDir;
      const names = await fs.listFile(dir);
      let total = 0;
      for (const n of names) {
        try {
          const st = fs.statSync(`${dir}/${n}`);
          total += st.size;
        } catch (e) {
          // 跳过
        }
      }
      const kb = total / 1024;
      this.cacheSize = kb < 1024 ? `${kb.toFixed(0)} KB` : `${(kb / 1024).toFixed(1)} MB`;
    } catch (e) {
      this.cacheSize = '--';
    }
  }

  private clearCache(): void {
    try {
      const dir = getContext(this).cacheDir;
      const names = fs.listFileSync(dir);
      for (const n of names) {
        try {
          fs.unlinkSync(`${dir}/${n}`);
        } catch (e) {
          // 跳过
        }
      }
      this.cacheSize = '0 KB';
      this.status = '缓存已清理';
    } catch (e) {
      this.status = '清理失败';
    }
  }

  private async createThread(): Promise<void> {
    const ws = this.workspaces.length > 0 ? this.workspaces[0].path : '';
    const name = `聊天 ${this.threads.length + 1}`;
    try {
      await this.client.createThread(name, ws);
      await this.refreshThreads();
      const list = this.threads;
      if (list.length > 0) {
        await this.switchThread(list[list.length - 1].id);
      }
    } catch (e) {
      this.status = '新建失败';
    }
  }

  private deleteThread(id: string): void {
    AlertDialog.show({
      title: '删除聊天区',
      message: '这个聊天区的消息记录会一起消失（她的记忆不受影响）',
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E84026',
        action: () => {
          this.client.deleteThread(id).then(() => {
            this.refreshThreads();
          });
        },
      },
    });
  }

  private currentThread(): Thread | null {
    const t = this.threads.find((x) => x.id === this.current);
    return t ?? null;
  }

  private closeVoice(): void {
    if (!this.showVoice || this.vcClosing) {
      return;
    }
    this.vcClosing = true;
    setTimeout(() => {
      this.showVoice = false;
      this.vcClosing = false;
    }, 210);
  }

  private closeSettings(): void {
    if (!this.showSettings || this.stClosing) {
      return;
    }
    this.stClosing = true;
    setTimeout(() => {
      this.showSettings = false;
      this.stClosing = false;
    }, 230);
  }

  private workspaceLabel(): string {
    const t = this.currentThread();
    if (!t) {
      return '';
    }
    const w = this.workspaces.find((x) => x.path === t.workspace);
    return w ? w.label : '工作区';
  }

  private async changeWorkspace(path: string): Promise<void> {
    const t = this.currentThread();
    if (!t) {
      return;
    }
    await this.client.patchThread(t.id, path);
    await this.refreshThreads();
  }

  private send(): void {
    const raw = this.inputText.trim();
    if (!raw) {
      return;
    }
    let quote: QuoteRef | undefined = undefined;
    if (this.quoteText !== '' || this.quoteImage !== '') {
      quote = { text: this.quoteText };
      if (this.quoteImage !== '') {
        quote.image = this.quoteImage;
      }
    }
    this.quoteText = '';
    this.quoteImage = '';
    const m: ChatMessage = {
      id: String(Date.now()),
      threadId: this.current,
      role: 'me',
      text: raw,
      ts: Date.now()
    };
    if (quote) {
      m.quote = quote;
    }
    this.lastSentText = raw;
    this.lastSentTs = m.ts;
    this.messages.push(m);
    this.messages = this.messages.slice();
    this.inputText = '';
    this.inputHasImg = false;
    this.inlineOrder = [];
    try {
      this.richCtrl.deleteSpans();
    } catch (e) {
      // 编辑器还没就绪就不管
    }
    this.client.send(raw, undefined, quote);
    // 发出去就先挂上「正在输入」，不等服务端事件；收到回复再撤
    this.typing = true;
    if (this.typingGuard > 0) {
      clearTimeout(this.typingGuard);
    }
    this.typingGuard = setTimeout(() => {
      this.typing = false;
      this.typingGuard = -1;
    }, 300000);
    this.scrollToBottom();
  }

  private inlineStickers(): StickerItem[] {
    return this.stickers.filter((s: StickerItem) => s.cat === 'inline');
  }

  private packStickers(): StickerItem[] {
    return this.stickers.filter((s: StickerItem) => s.cat === 'pack');
  }

  private customStickers(): StickerItem[] {
    return this.stickers.filter((s: StickerItem) => s.cat === 'custom');
  }

  private tabStickers(): StickerItem[] {
    if (this.stickerTab === 'custom') {
      return this.customStickers();
    }
    return this.stickerTab === 'inline' ? this.inlineStickers() : this.packStickers();
  }

  /** 点小表情：直接把图插进输入框，跟文字一起发 */
  private insertInlineSticker(file: string): void {
    let caret: number = -1;
    try {
      caret = this.richCtrl.getCaretOffset();
    } catch (e) {
      caret = -1;
    }
    if (caret < 0) {
      // 没焦点就接在末尾
      this.richCtrl.setCaretOffset(0);
      caret = this.inlineOrder.length + this.inputText.length;
    }
    try {
      this.richCtrl.addImageSpan(this.client.mediaUrl(`/stickers/${encodeURIComponent(file)}`), {
        offset: caret,
        imageStyle: { size: [19, 19] }
      });
      this.inlineOrder.push(file);
      this.richCtrl.setCaretOffset(caret + 1);
    } catch (e) {
      this.inputText = `${this.inputText}[e:${file}]`;
    }
    this.syncInputText();
    this.scrollToBottom();
  }

  /** 从编辑器里还原出可发送的文本：文字原样，小表情按插入顺序还原成 [e:xxx] */
  private syncInputText(): void {
    let out: string = '';
    let imgIndex: number = 0;
    try {
      const spans: RichEditorSpan[] = this.richCtrl.getSpans();
      for (let i = 0; i < spans.length; i++) {
        const textSpan: RichEditorTextSpanResult = spans[i] as RichEditorTextSpanResult;
        const value: string = textSpan.value;
        if (value !== undefined && value !== null) {
          out += value;
        } else {
          const file: string = imgIndex < this.inlineOrder.length ? this.inlineOrder[imgIndex] : '';
          imgIndex += 1;
          if (file !== '') {
            out += `[e:${file}]`;
          }
        }
      }
      // 图被删掉时，顺序表跟着缩
      if (imgIndex < this.inlineOrder.length) {
        this.inlineOrder = this.inlineOrder.slice(0, imgIndex);
      }
    } catch (e) {
      out = this.inputText;
    }
    this.inputText = out;
    this.inputHasImg = imgIndex > 0;
  }

  /** 长按「自定义」里的表情：弹出「移到最前 / 删除」 */
  private openStickerMenu(file: string): void {
    try {
      promptAction.showActionMenu({
        title: '这张表情',
        buttons: [
          { text: '移到最前', color: '#1D3A6E' },
          { text: '删除', color: '#E5453F' },
        ],
      }).then((r: promptAction.ActionMenuSuccessResponse) => {
        if (r.index === 0) {
          this.client.moveStickerFront(file).then((ok: boolean) => {
            if (ok) {
              this.reloadStickers();
            }
          });
        } else if (r.index === 1) {
          this.confirmDeleteSticker(file);
        }
      }).catch(() => {});
    } catch (e) {
      this.confirmDeleteSticker(file);
    }
  }

  /** 重新拉一遍表情列表 */
  private reloadStickers(): void {
    this.client.loadStickers().then((l: StickerItem[]) => {
      if (l.length > 0) {
        this.stickers = l;
      }
    }).catch(() => {});
  }

  /** 长按「自定义」里的表情：确认后删掉 */
  private confirmDeleteSticker(file: string): void {
    AlertDialog.show({
      title: '删掉这张？',
      message: file,
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E5453F',
        action: () => {
          this.client.deleteSticker(file).then((ok: boolean) => {
            if (ok) {
              this.stickers = this.stickers.filter((x: StickerItem) => x.file !== file);
            }
          });
        },
      },
    });
  }

  private sendSticker(file: string): void {
    const m: ChatMessage = {
      id: String(Date.now()),
      threadId: this.current,
      role: 'me',
      text: '',
      sticker: file,
      ts: Date.now(),
    };
    // 空字符串会和服务端回显的这条对上，用来去重
    this.lastSentText = '';
    this.lastSentImage = '';
    this.lastSentTs = m.ts;
    this.messages.push(m);
    this.messages = this.messages.slice();
    this.client.send('', undefined, undefined, file);
    animateTo({ duration: 160, curve: Curve.FastOutSlowIn }, () => {
      this.showStickers = false;
    });
    this.scrollToBottom();
  }

  // 临时状态：显示一会儿自动回到在线，不会一直挂在标题下面
  private flashStatus(text: string, ms: number = 1600): void {
    this.status = text;
    setTimeout(() => {
      if (this.status === text) {
        this.status = '在线';
      }
    }, ms);
  }

  /** 从相册挑一张，加进表情库 */
  private async addStickerFromGallery(): Promise<void> {
    if (this.uploading) {
      return;
    }
    this.uploading = true;
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const res = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      const uris = res.photoUris;
      if (!uris || uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const name = await this.client.addSticker(buf);
      if (name === '') {
        this.flashStatus('没加进去');
        return;
      }
      const list = await this.client.loadStickers();
      this.stickers = list;
      this.flashStatus('加好了');
    } catch (e) {
      this.flashStatus('没加进去');
    } finally {
      this.uploading = false;
    }
  }

  private async pickAndSendImage(): Promise<void> {
    if (this.uploading) {
      return;
    }
    this.uploading = true;
    this.status = '选图…';
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const res = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      const uris = res.photoUris;
      if (!uris || uris.length === 0) {
        this.flashStatus('没选到图');
        return;
      }
      this.status = '读取…';
      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      this.status = '上传…';
      const serverPath = await this.client.uploadImage(buf);
      if (!serverPath) {
        this.flashStatus('上传失败');
        return;
      }
      const m: ChatMessage = {
        id: String(Date.now()),
        threadId: this.current,
        role: 'me',
        text: '',
        image: serverPath,
        ts: Date.now(),
      };
      this.lastSentText = '';
      this.lastSentImage = serverPath;
      this.lastSentTs = m.ts;
      this.messages.push(m);
      this.messages = this.messages.slice();
      this.client.send('', serverPath);
      this.status = '在线';
      this.scrollToBottom();
    } catch (e) {
      const err = e as BusinessError;
      this.flashStatus(`图片失败:${err?.message ?? ''}`.slice(0, 40), 2600);
    } finally {
      this.uploading = false;
    }
  }

  // 折叠过渡只在一开一合那一下播一次：先折进去，再铺平回来。
  // 不再监听 foldAngleChange —— 那个事件在折叠态会反复上报，是误触发的根源。
  private lastFoldStatus: string = '';
  private foldAnimating: boolean = false;
  private lastFoldAt: number = 0;

  private applyFold(t: number): void {
    this.foldT = Math.max(0, Math.min(1, t));
  }

  // 带透视的绕 Y 轴旋转矩阵（列主序），d 越大透视越弱
  private foldMatrix(): matrix4.Matrix4Transit {
    const deg: number = -18 * this.foldT;
    const r: number = deg * Math.PI / 180;
    const c: number = Math.cos(r);
    const s: number = Math.sin(r);
    const d: number = 1200;
    const m: [number, number, number, number, number, number, number, number,
      number, number, number, number, number, number, number, number] = [
      c, 0, -s, s / d,
      0, 1, 0, 0,
      s, 0, c, -c / d,
      0, 0, 0, 1
    ];
    return matrix4.init(m);
  }

  private playFoldTransition(): void {
    const now: number = Date.now();
    // 防重入 + 900ms 内不重播：折叠态下状态反复上报也不会再触发
    if (this.foldAnimating || now - this.lastFoldAt < 900) {
      return;
    }
    this.foldAnimating = true;
    this.lastFoldAt = now;
    animateTo({
      duration: 150,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        animateTo({
          duration: 280,
          curve: curves.springMotion(0.44, 0.86),
          onFinish: () => {
            this.foldAnimating = false;
          }
        }, () => {
          this.applyFold(0);
        });
      }
    }, () => {
      this.applyFold(0.55);
    });
  }

  // 折叠/窄屏时侧栏走浮层；展开态保持并排
  /** 并排侧栏宽度：沿用折叠态量到的宽度，没量到就先按当前屏宽算 */
  private parallelW(): number {
    return this.foldedPanelW > 0 ? this.foldedPanelW : this.sidePanelW();
  }

  private async loadFoldedW(): Promise<void> {
    try {
      const p = await preferences.getPreferences(getContext(this), 'im_layout');
      const v = p.getSync('folded_panel_w', 0) as number;
      if (v > 0) {
        this.foldedPanelW = v;
      }
    } catch (e) {
      // 老版本没存过就算了，按默认值走
    }
  }

  private saveFoldedW(v: number): void {
    preferences.getPreferences(getContext(this), 'im_layout').then((p: preferences.Preferences) => {
      p.putSync('folded_panel_w', v);
      p.flush();
    }).catch(() => {
    });
  }

  /** 聊天区右侧给并排侧栏让出的宽度：折叠态的侧栏是浮层，不占布局 */
  private sideShift(): number {
    return this.sidebarOverlay() ? 0 : (this.showSidebar ? this.parallelW() : 0);
  }

  private sidePanelW(): number {
    return this.winW * 0.78 > 300 ? 300 : this.winW * 0.78;
  }

  @Builder
  settingsBody() {
    Row() {
      Column()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor('#E4E9F2')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ bottom: -2 })

    Row() {
      Text('设置')
        .fontSize(15)
        .fontFamily('NotoSansSC')
        .fontWeight(FontWeight.Bold)
        .fontColor('#1D1D1F')
      Blank()
      Text('✕')
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontColor('#8A8A90')
        .padding(4)
        .onClick(() => {
          this.closeSettings();
        })
    }
    .width('100%')

    Column({ space: 7 }) {
      Text('关于')
        .fontSize(10)
        .fontFamily('NotoSansSC')
        .fontColor('#9A9AA0')
        .width('100%')
      this.settingRow('名称', '大肥鱼 IM')
      this.settingRow('版本', this.appVersion())
      this.settingRow('服务器', 'ngrok 固定域名')
      this.settingRow('聊天区', `${this.threads.length} 个`)
      this.settingRow('消息', `${this.messages.length} 条`)
      Row() {
        Text('图片存储').fontSize(13).fontColor('#3A3A3E')
        Blank()
        Text(this.storageInfo).fontSize(13).fontColor('#8A8A93')
      }
      .width('100%')
      .padding({ top: 5, bottom: 5 })
      Row() {
        Text('音频存储').fontSize(13).fontColor('#3A3A3E')
        Blank()
        Text(this.audioStorage).fontSize(13).fontColor('#8A8A93')
      }
      .width('100%')
      .padding({ top: 5, bottom: 5 })
    }
    .width('100%')

    Divider().strokeWidth(0.5).color('#ECECEF')

    Column({ space: 7 }) {
      Text('个性化')
        .fontSize(10)
        .fontFamily('NotoSansSC')
        .fontColor('#9A9AA0')
        .width('100%')
      Row() {
        Column({ space: 2 }) {
          Text('她的声音')
            .fontSize(13)
            .fontFamily('NotoSansSC')
            .fontColor('#333333')
          Text('语音消息用哪副嗓子')
            .fontSize(10)
            .fontFamily('NotoSansSC')
            .fontColor('#9A9AA0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.voiceLabel())
          .fontSize(13)
          .fontFamily('NotoSansSC')
          .fontColor('#3C7DFF')
        Text('›')
          .fontSize(16)
          .fontFamily('NotoSansSC')
          .fontColor('#C0C4CC')
          .margin({ left: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 5, bottom: 5 })
      .onClick(() => {
        this.refreshVoice();
        animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
          this.vcClosing = false;
          this.showVoice = true;
        });
      })
    }
    .width('100%')

    Divider().strokeWidth(0.5).color('#ECECEF')

    Column({ space: 7 }) {
      Text('手势')
        .fontSize(10)
        .fontFamily('NotoSansSC')
        .fontColor('#9A9AA0')
        .width('100%')
      Row() {
        Column({ space: 2 }) {
          Text('智感握持')
            .fontSize(13)
            .fontFamily('NotoSansSC')
            .fontColor('#333333')
          Text('左手拿手机时，输入条翻到左边')
            .fontSize(10)
            .fontFamily('NotoSansSC')
            .fontColor('#9A9AA0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.holdEnabled })
          .selectedColor('#3C7DFF')
          .onChange((on: boolean) => {
            this.setHoldEnabled(on);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')

    Divider().strokeWidth(0.5).color('#ECECEF')

    Column({ space: 7 }) {
      Text('缓存')
        .fontSize(10)
        .fontFamily('NotoSansSC')
        .fontColor('#9A9AA0')
        .width('100%')
      Row() {
        Text('本地缓存')
          .fontSize(12)
          .fontFamily('NotoSansSC')
          .fontColor('#333333')
          .layoutWeight(1)
        Text(this.cacheSize)
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor('#8A8A90')
      }
      .width('100%')
      Button('清理缓存')
        .width('100%')
        .height(30)
        .fontSize(12)
        .fontFamily('NotoSansSC')
        .backgroundColor('#EDF1F9')
        .fontColor('#3C7DFF')
        .onClick(() => {
          this.clearCache();
        })
    }
    .width('100%')
  }

  /** 折叠态浮层：打开（插进来由 transition 负责滑入） */
  private openSidebarOverlay(): void {
    if (this.sbTimer >= 0) {
      clearTimeout(this.sbTimer);
      this.sbTimer = -1;
    }
    this.sbClosing = false;
    this.sbX = 0;
    this.showSidebar = true;
  }

  /** 折叠态浮层：关掉时先滑出去，等动画走完再真正卸载 */
  private closeSidebarOverlay(): void {
    if (!this.showSidebar) {
      return;
    }
    if (this.sbClosing) {
      // 已经在关了：再点一次就直接收干净，避免卡在半路
      this.finishSidebarClose();
      return;
    }
    this.sbClosing = true;
    this.sbX = -1;
    this.sbTimer = setTimeout(() => {
      this.sbTimer = -1;
      this.finishSidebarClose();
    }, 250);
  }

  private finishSidebarClose(): void {
    if (this.sbTimer >= 0) {
      clearTimeout(this.sbTimer);
      this.sbTimer = -1;
    }
    this.showSidebar = false;
    this.sbClosing = false;
    this.sbX = 0;
  }

  private sidebarOverlay(): boolean {
    return !this.foldExpanded || this.winW < 700;
  }

  private watchFold(): void {
    try {
      this.foldT = 0;
      // 启动时先读当前折叠状态当基准，不播动画
      try {
        this.lastFoldStatus = `${display.getFoldStatus()}`;
      } catch (e) {
        this.lastFoldStatus = '';
      }
      display.on('foldStatusChange', (status: display.FoldStatus) => {
        const key: string = `${status}`;
        if (key === this.lastFoldStatus) {
          return;
        }
        // 拿不到初始状态时，第一次只记账、不播
        if (this.lastFoldStatus === '') {
          this.lastFoldStatus = key;
          return;
        }
        this.lastFoldStatus = key;
        // 折叠/展开时同步侧栏呈现方式：折叠 -> 浮层；展开 -> 并排
        try {
          const st2: display.FoldStatus = display.getFoldStatus();
          const exp: boolean = st2 === display.FoldStatus.FOLD_STATUS_EXPANDED;
          this.foldExpanded = exp;
          if (!exp) {
            this.showSidebar = false;
            this.userToggledSidebar = false;
          }
        } catch (e) {
        }
        this.playFoldTransition();
      });
    } catch (e) {
      // 非折叠机 / 老系统：不注册，foldT 恒为 0
    }
  }

  @Builder
  imgMenu(m: ChatMessage) {
    Column() {
      Text('查看大图')
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontColor('#222222')
        .width('100%')
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          this.openPreview(this.client.mediaUrl(m.image ?? ''));
        })
      Divider().strokeWidth(0.5).color('#EEEEEE')
      Text('引用')
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontColor('#222222')
        .width('100%')
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          this.quoteText = '图片';
          this.quoteImage = m.image ? m.image : '';
        })
      if (this.canRecall(m)) {
        Divider().strokeWidth(0.5).color('#EEEEEE')
        Text('撤回')
          .fontSize(13)
          .fontFamily('NotoSansSC')
          .fontColor('#E84026')
          .width('100%')
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          .onClick(() => {
            this.recallMessage(m);
          })
      }
    }
    .width(108)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
  }

  @Builder
  msgMenu(m: ChatMessage) {
    Column() {
      Text('复制')
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontColor('#222222')
        .width('100%')
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          this.copyMessage(m);
        })
      Divider().strokeWidth(0.5).color('#EEEEEE')
      Text('引用')
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontColor('#222222')
        .width('100%')
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          const body = this.quoteBody(m.text);
          this.quoteText = body.length > 40 ? `${body.substring(0, 40)}…` : body;
          this.quoteImage = '';
        })
      if (this.canRecall(m)) {
        Divider().strokeWidth(0.5).color('#EEEEEE')
        Text('撤回')
          .fontSize(13)
          .fontFamily('NotoSansSC')
          .fontColor('#E84026')
          .width('100%')
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          .onClick(() => {
            this.recallMessage(m);
          })
      }
    }
    .width(108)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
  }

  /** 把含 [e:文件名] 的文字切成「文本 / 小表情」片段 */
  private richParts(text: string): RichPart[] {
    const out: RichPart[] = [];
    const re: RegExp = new RegExp('\\[e:([^\\]]+)\\]', 'g');
    let last: number = 0;
    let m: RegExpExecArray | null = re.exec(text);
    while (m !== null) {
      if (m.index > last) {
        out.push({ kind: 'text', value: text.substring(last, m.index) });
      }
      out.push({ kind: 'img', value: m[1] });
      last = m.index + m[0].length;
      m = re.exec(text);
    }
    if (last < text.length) {
      out.push({ kind: 'text', value: text.substring(last) });
    }
    return out;
  }

  /** 把文字拆成「字 / 西文词 / 空格 / 小表情」，交给 Flex 逐块排 */
  private richRuns(text: string): RichPart[] {
    const out: RichPart[] = [];
    const parts: RichPart[] = this.richParts(text);
    for (let i = 0; i < parts.length; i++) {
      const p: RichPart = parts[i];
      if (p.kind === 'img') {
        out.push(p);
        continue;
      }
      let buf: string = '';
      for (let j = 0; j < p.value.length; j++) {
        const ch: string = p.value.charAt(j);
        const code: number = ch.charCodeAt(0);
        const isWord: boolean = (code < 128) && (/[A-Za-z0-9']/.test(ch));
        if (isWord) {
          buf += ch;
          continue;
        }
        if (buf !== '') {
          out.push({ kind: 'text', value: buf });
          buf = '';
        }
        out.push({ kind: 'text', value: ch });
      }
      if (buf !== '') {
        out.push({ kind: 'text', value: buf });
      }
    }
    return out;
  }

  private runWidth(p: RichPart): number {
    if (p.kind === 'img') {
      return 21;
    }
    let w: number = 0;
    for (let i = 0; i < p.value.length; i++) {
      const code: number = p.value.charCodeAt(i);
      w += code < 128 ? (p.value.charAt(i) === ' ' ? 4.6 : 9.2) : 16.8;
    }
    return w;
  }

  /** 估算这行文字铺开有多宽，用来决定气泡宽度 */
  private richWidth(text: string): number {
    const runs: RichPart[] = this.richRuns(text);
    let w: number = 0;
    for (let i = 0; i < runs.length; i++) {
      w += this.runWidth(runs[i]);
    }
    return w;
  }

  private chatWidth(): number {
    return this.winW - this.sideShift() - 28;
  }

  /** 气泡正文按 \n 切成段：换行是要真分段的，不能让 Flex 折行去猜 */
  private textLines(text: string): string[] {
    const clean: string = text.split('\r').join('');
    return clean.split('\n');
  }

  /** 一行铺开有多宽（空行也给一点宽度，免得整段塌掉） */
  private lineWidth(line: string): number {
    return Math.min(Math.max(this.richWidth(line) + 2, 20), Math.max(80, this.chatWidth() * 0.78 - 26));
  }

  /** 气泡正文：普通文字 + 与字号同高的小表情，一段一行 */
  @Builder
  richText(text: string, color: string) {
    Column({ space: 0 }) {
      ForEach(this.textLines(text), (line: string, li: number) => {
        if (line === '') {
          Text(' ')
            .fontSize(16)
            .fontFamily('NotoSansSC')
            .lineHeight(24)
        } else {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Baseline }) {
            ForEach(this.richRuns(line), (p: RichPart, i: number) => {
              if (p.kind === 'img') {
                Image(this.client.mediaUrl(`/stickers/${encodeURIComponent(p.value)}`))
                  .width(19)
                  .height(19)
                  .objectFit(ImageFit.Contain)
                  .margin({ left: 1, right: 1 })
                  .alignSelf(ItemAlign.Center)
                  .offset({ y: 3 })
              } else {
                Text(p.value)
                  .fontSize(16)
                  .fontFamily('NotoSansSC')
                  .fontColor(color)
                  .letterSpacing(0.3)
                  .lineHeight(24)
              }
            }, (p: RichPart, i: number) => `${i}_${p.kind}_${p.value}`)
          }
          .width(this.lineWidth(line))
        }
      }, (line: string, li: number) => `${li}_${line}`)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  stickerActions(st: StickerItem) {
    Column() {
      Text('移到最前')
        .fontSize(14)
        .fontFamily('NotoSansSC')
        .fontColor('#1D3A6E')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.client.moveStickerFront(st.file).then((ok: boolean) => {
            if (ok) {
              this.reloadStickers();
            }
          });
        })
      Divider().color('#EEEEF2')
      Text('删除')
        .fontSize(14)
        .fontFamily('NotoSansSC')
        .fontColor('#E5453F')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.confirmDeleteSticker(st.file);
        })
    }
    .width(132)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .shadow({ radius: 18, color: '#33000000', offsetY: 6 })
  }

  @Builder
  headerMenu() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Text('☰')
        .fontSize(17)
        .fontFamily('NotoSansSC')
        .fontColor('#3A3A3C')
        .textAlign(TextAlign.Center)
        .width(30)
        .height(30)
        .lineHeight(30)
        .borderRadius(10)
      if (!this.showSidebar && this.unreadTotal() > 0) {
        Circle()
          .width(8)
          .height(8)
          .fill('#FF453A')
          .offset({ x: 3, y: 4 })
      }
    }
    .width(30)
    .height(30)
    .onClick(() => {
      this.userToggledSidebar = true;
      if (this.sidebarOverlay()) {
        // 折叠态：侧栏是浮层，消息区不该跟着收缩，开关都走自己的动画
        if (this.showSidebar) {
          this.closeSidebarOverlay();
        } else {
          this.openSidebarOverlay();
        }
      } else {
        animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
          this.showSidebar = !this.showSidebar;
        });
      }
    })
  }

  @Builder
  inputIcons() {
    Row({ space: 8 }) {
      Image($rawfile('icons/lucide_smile.svg'))
        .width(34)
        .height(34)
        .padding(7)
        .backgroundColor(this.showStickers ? '#144D8DFF' : '#08FFFFFF')
        .backgroundEffect({ radius: 12, saturation: 1.5, brightness: 1.05 })
        .border({ width: 1, color: this.showStickers ? '#663C7DFF' : '#3322375C' })
        .shadow({ radius: 5, color: '#122E5A8C', offsetY: 1 })
        .borderRadius(17)
        .onClick(() => {
          if (this.stickers.length === 0) {
            this.client.loadStickers().then((list: StickerItem[]) => {
              this.stickers = list;
            });
          }
          const open = !this.showStickers;
          if (open) {
            this.richCtrl.stopEditing();
          }
          this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
            this.showStickers = open;
          });
          this.scrollToBottom();
        })
      Image($rawfile('icons/lucide_image.svg'))
        .width(34)
        .height(34)
        .padding(7)
        .backgroundColor('#08FFFFFF')
        .backgroundEffect({ radius: 12, saturation: 1.5, brightness: 1.05 })
        .border({ width: 1, color: '#3322375C' })
        .shadow({ radius: 5, color: '#122E5A8C', offsetY: 1 })
        .borderRadius(17)
        .onClick(() => {
          this.pickAndSendImage();
        })
      Image($rawfile('icons/lucide_mic.svg'))
        .width(34)
        .height(34)
        .padding(7)
        .backgroundColor(this.recOn ? '#14E4574C' : '#08FFFFFF')
        .backgroundEffect({ radius: 12, saturation: 1.5, brightness: 1.05 })
        .border({ width: 1, color: this.recOn ? '#66E4574C' : '#3322375C' })
        .shadow({ radius: 5, color: '#122E5A8C', offsetY: 1 })
        .borderRadius(17)
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.startRecord();
          } else if (e.type === TouchType.Up) {
            this.stopRecord(true);
          } else if (e.type === TouchType.Cancel) {
            this.stopRecord(false);
          }
        })
    }
  }

  @Builder
  inputField() {
        Stack({ alignContent: Alignment.Start }) {
          RichEditor({ controller: this.richCtrl })
            .id('msgInput')
            .width('100%')
            .height(34)
            .backgroundColor(Color.Transparent)
            .caretColor('#3C7DFF')
            .onReady(() => {
              this.richCtrl.setTypingStyle({
                fontFamily: 'NotoSansSC',
                fontSize: 15,
                fontColor: '#1D1D1F'
              });
            })
            .onDidChange(() => {
              this.syncInputText();
            })
          if (this.inputText === '' && !this.inputHasImg) {
            Row() {
              Text('说点什么…')
                .fontSize(15)
                .fontFamily('NotoSansSC')
                .fontColor('#9A9AA0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height('100%')
            .padding({ left: 5 })
            .alignItems(VerticalAlign.Center)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .layoutWeight(1)
        .height(34)
        .padding({ left: 12, right: 12 })
        .backgroundColor('#1A22375C')
        .borderRadius(17)
        .border({ width: 1, color: '#26FFFFFF' })
        .onClick(() => {
          // 点输入框：面板先收，等它滑出去再聚焦。抢在动画前聚焦会让编辑器被面板盖着，
          // 系统判定不可见就不弹键盘了。
          if (this.showStickers) {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.showStickers = false;
            });
            setTimeout(() => {
              this.getUIContext().getFocusController().requestFocus('msgInput');
            }, 240);
          } else {
            this.getUIContext().getFocusController().requestFocus('msgInput');
          }
        })
  }

  @Builder
  inputSend() {
    Row() {
      Image($rawfile('icons/lucide_send.svg'))
        .width(34)
        .height(34)
        .padding(8)
        .backgroundColor('#3C7DFF')
        .borderRadius(17)
        .border({ width: 1, color: '#8CFFFFFF' })
        .shadow({ radius: 10, color: '#3D3C7DFF', offsetY: 3 })
        .onClick(() => {
          this.send();
        })
    }
  }

  @Builder
  stickerPanel() {
    Column() {
      Row({ space: 6 }) {
        Text(`小表情 · ${this.inlineStickers().length}`)
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor(this.stickerTab === 'inline' ? '#1D3A6E' : '#8A8A8E')
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(this.stickerTab === 'inline' ? '#E8F0FF' : Color.Transparent)
          .borderRadius(9)
          .onClick(() => {
            this.stickerTab = 'inline';
          })
        Text(`表情包 · ${this.packStickers().length}`)
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor(this.stickerTab === 'pack' ? '#1D3A6E' : '#8A8A8E')
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(this.stickerTab === 'pack' ? '#E8F0FF' : Color.Transparent)
          .borderRadius(9)
          .onClick(() => {
            this.stickerTab = 'pack';
          })
        Text(`自定义 · ${this.customStickers().length}`)
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor(this.stickerTab === 'custom' ? '#1D3A6E' : '#8A8A8E')
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(this.stickerTab === 'custom' ? '#E8F0FF' : Color.Transparent)
          .borderRadius(9)
          .onClick(() => {
            this.stickerTab = 'custom';
          })
        Blank()
        Text('收起')
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor('#5F5F66')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
              this.showStickers = false;
            });
          })
      }
      .width('100%')
      .padding({ left: 14, right: 12, top: 6, bottom: 2 })

      Grid() {
        if (this.stickerTab === 'custom') {
          GridItem() {
            Stack() {
              Text('＋')
                .fontSize(20)
                .fontFamily('NotoSansSC')
                .fontColor('#9AA0AA')
            }
            .width(40)
            .height(40)
            .borderRadius(9)
            .border({ width: 1, color: '#D6DAE2', style: BorderStyle.Dashed })
            .onClick(() => {
              this.addStickerFromGallery();
            })
          }
        }
        ForEach(this.tabStickers(),
          (st: StickerItem) => {
            GridItem() {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(this.client.mediaUrl(`/stickers/${encodeURIComponent(st.file)}`))
                  .width(this.stickerTab === 'pack' ? 54 : 40)
                  .height(this.stickerTab === 'pack' ? 54 : 40)
                  .objectFit(ImageFit.Contain)
                  .onClick(() => {
                    if (this.stickerTab === 'inline') {
                      this.insertInlineSticker(st.file);
                    } else {
                      this.sendSticker(st.file);
                    }
                  })
                  .bindContextMenu(this.stickerActions(st), ResponseType.LongPress)
              }
              .width(this.stickerTab === 'pack' ? 54 : 40)
              .height(this.stickerTab === 'pack' ? 54 : 40)
            }
          }, (st: StickerItem) => `${this.stickerTab}_${st.file}`)
      }
      .columnsTemplate(this.stickerTab === 'pack' ? '1fr 1fr 1fr 1fr 1fr' : '1fr 1fr 1fr 1fr 1fr 1fr 1fr')
      .columnsGap(6)
      .rowsGap(6)
      .height(258)
      .scrollBar(BarState.Off)
      .padding({ left: 12, right: 12, top: 6, bottom: 10 })
    }
    .width('100%')
  }

  /** 从服务端拉音色列表 + 当前值 */
  private async refreshVoice(): Promise<void> {
    try {
      const st = await this.client.loadVoice();
      if (st.current) {
        this.voiceId = st.current;
      }
      this.voiceOptions = st.voices;
    } catch (e) {
      // 服务端没连上就先保持默认，下次打开设置再试
    }
  }

  /** 安装包真实版本号，别和代码里写的对上不上 */
  private appVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      return '—';
    }
  }

  /** 当前音色的显示名 */
  private voiceLabel(): string {
    for (const v of this.voiceOptions) {
      if (v.id === this.voiceId) {
        return v.name;
      }
    }
    return '胡桃';
  }

  /** 点选一个音色：未安装的只提示，不切换 */
  private async pickVoice(v: VoiceOption): Promise<void> {
    if (this.voiceBusy) {
      return;
    }
    if (!v.installed) {
      promptAction.showToast({ message: `${v.name} 的音色包还没装`, duration: 1600 });
      return;
    }
    if (v.id === this.voiceId) {
      animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.showVoice = false;
      });
      return;
    }
    this.voiceBusy = true;
    try {
      const st = await this.client.setVoice(v.id);
      this.voiceId = st.current;
      this.voiceOptions = st.voices;
      promptAction.showToast({ message: `换成${v.name}的声音了`, duration: 1400 });
      animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        this.showVoice = false;
      });
    } catch (e) {
      const err = e as Error;
      promptAction.showToast({ message: `切换失败：${err.message}`.slice(0, 40), duration: 1800 });
    } finally {
      this.voiceBusy = false;
    }
  }

  @Builder
  settingRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontColor('#333333')
        .layoutWeight(1)
      Text(value)
        .fontSize(12)
        .fontFamily('NotoSansSC')
        .fontColor('#8A8A90')
    }
    .width('100%')
  }

  private copyWhaleText(t: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, t);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '已复制到剪贴板', duration: 1500 });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    });
  }

  @Builder
  aboutChip(t: string) {
    Text(t)
      .fontSize(11)
      .fontFamily('NotoSansSC')
      .fontColor('#46566F')
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor('#EFF5FF')
      .borderRadius(9)
      .margin({ right: 6, bottom: 6 })
  }

  @Builder
  aboutCharCard(title: string, sub: string, img: Resource, tags: string[], paras: string[], prompt: string) {
    Column({ space: 8 }) {
      Image(img)
        .width('100%')
        .aspectRatio(4 / 3)
        .objectFit(ImageFit.Contain)
        .borderRadius(14)
        .border({ width: 1, color: '#E8F0FB' })
        .backgroundColor('#FFFFFF')
      Row() {
        Text(title)
          .fontSize(16)
          .fontFamily('NotoSansSC')
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
        Blank()
        Text('图源：鲸鱼娘开源资产库')
          .fontSize(9)
          .fontFamily('NotoSansSC')
          .fontColor('#9AA6B6')
      }
      .width('100%')

      if (sub.length > 0) {
        Text(sub)
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor('#7A8698')
          .width('100%')
      }

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(tags, (t: string) => {
          this.aboutChip(t)
        }, (t: string) => t)
      }
      .width('100%')

      ForEach(paras, (p: string) => {
        Text(p)
          .fontSize(13)
          .fontFamily('NotoSansSC')
          .fontColor('#454B57')
          .lineHeight(21)
          .width('100%')
      }, (p: string) => p.slice(0, 12))

      Row() {
        Row({ space: 5 }) {
          Text('复制提示词')
            .fontSize(12)
            .fontFamily('NotoSansSC')
            .fontColor('#3C7DFF')
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor('#F1F6FF')
        .borderRadius(10)
        .onClick(() => {
          this.copyWhaleText(prompt);
        })
        Blank()
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .border({ width: 1, color: '#EEF3FC' })
    .shadow({ radius: 12, color: '#101D3A66', offsetY: 3 })
  }

  @Builder
  aboutSourceCard() {
    Column({ space: 6 }) {
      Text('资料来源')
        .fontSize(13)
        .fontFamily('NotoSansSC')
        .fontWeight(FontWeight.Bold)
        .fontColor('#2C3A4F')
      Text('鲸鱼娘开源资产库 · 社区维护')
        .fontSize(12)
        .fontFamily('NotoSansSC')
        .fontColor('#4B5A72')
      Text(WHALE_SOURCE_URL)
        .fontSize(11)
        .fontFamily('NotoSansSC')
        .fontColor('#3C7DFF')
        .maxLines(2)
        .onClick(() => {
          this.copyWhaleText(WHALE_SOURCE_URL);
        })
      Text(WHALE_SOURCE_REPO)
        .fontSize(11)
        .fontFamily('NotoSansSC')
        .fontColor('#3C7DFF')
        .maxLines(2)
        .onClick(() => {
          this.copyWhaleText(WHALE_SOURCE_REPO);
        })
      Text('形象来源（原项目，B站）：@上善无形 · @ZipZipPipe · 当前为占位图')
        .fontSize(11)
        .fontFamily('NotoSansSC')
        .fontColor('#7A8698')
      Text('本页文案与设定图整理自该站，内容为节选；完整提示词可用上方按钮复制。该站由社区维护，不代表深度求索公司或其官方立场，二创请遵循项目页的许可说明。')
        .fontSize(11)
        .fontFamily('NotoSansSC')
        .fontColor('#7A8698')
        .lineHeight(18)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor('#F7FAFF')
    .borderRadius(16)
    .border({ width: 1, color: '#E9F1FC' })
  }

  @Builder
  aboutPage() {
    Stack({ alignContent: Alignment.Top }) {
      Row({ space: 10 }) {
        Row() {
          Image($rawfile('icons/lucide_chevron_left.svg'))
            .width(18)
            .height(18)
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor('#F2F7FF')
        .border({ width: 1, color: '#E4EDFA' })
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.closeAbout();
        })
        Text('关于大肥鱼')
          .fontSize(17)
          .fontFamily('NotoSansSC')
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
        Blank()
      }
      .width('100%')
      .height(60 + this.safeTop)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: this.safeTop })
      .backgroundColor('#4DF5F8FF')
      .backgroundEffect({ radius: 26, saturation: 1.8, brightness: 1.06 })
      .border({ width: { top: 1, bottom: 1 }, color: '#CCFFFFFF' })
      .opacity(this.aboutContent)
      .zIndex(1)

      Scroll() {
        Column({ space: 14 }) {
          // 头像 + 名字
          Row({ space: 12 }) {
            Image($r('app.media.avatar'))
              .id('aboutHeroAvatar')
              .width(64)
              .height(64)
              .borderRadius(32)
              .objectFit(ImageFit.Cover)
              .border({ width: 2, color: '#E9F0FF' })
              .shadow({ radius: 10, color: '#223C7DFF' })
              .opacity(this.aboutFlyVis ? 0 : 1)
              .translate({ x: this.aboutAvX, y: this.aboutAvY })
              .scale({ x: this.aboutAvScale, y: this.aboutAvScale })
            Column({ space: 3 }) {
              Text('大肥鱼')
                .fontSize(20)
                .fontFamily('NotoSansSC')
                .fontWeight(FontWeight.Bold)
                .fontColor('#1D1D1F')
              Text('住在耳机和屏幕之间的鲸鱼娘')
                .fontSize(12)
                .fontFamily('NotoSansSC')
                .fontColor('#6B7A90')
              Text('社区开源形象 · 非官方设定')
                .fontSize(10)
                .fontFamily('NotoSansSC')
                .fontColor('#9AA6B6')
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FFFFFF')
          .borderRadius(18)
          .border({ width: 1, color: '#EEF3FC' })
          .shadow({ radius: 12, color: '#101D3A55', offsetY: 3 })

          if (this.winW >= 700) {
            Row({ space: 12 }) {
              Column() {
                this.aboutCharCard('Q 版大肥鱼', '大头小身子，软乎乎的三头身', $rawfile('whale/chibi.png'),
                  CHIBI_TAGS, CHIBI_SUMMARY, CHIBI_PROMPT)
              }
              .layoutWeight(1)

              Column() {
                this.aboutCharCard('成熟比例鲸鱼娘', '同一只鱼长大之后', $rawfile('whale/mature.png'),
                  MATURE_TAGS, MATURE_SUMMARY, MATURE_PROMPT)
              }
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            this.aboutCharCard('Q 版大肥鱼', '大头小身子，软乎乎的三头身', $rawfile('whale/chibi.png'),
              CHIBI_TAGS, CHIBI_SUMMARY, CHIBI_PROMPT)
            this.aboutCharCard('成熟比例鲸鱼娘', '同一只鱼长大之后', $rawfile('whale/mature.png'),
              MATURE_TAGS, MATURE_SUMMARY, MATURE_PROMPT)
          }

          this.aboutSourceCard()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14 + 60 + this.safeTop, bottom: this.safeBottom + 26 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .opacity(this.aboutContent)

      // 过渡用的浮层头像：内容还没出来/已经淡掉时，由它单独完成飞行
      if (this.aboutFlyVis) {
        Image($r('app.media.avatar'))
          .width(64)
          .height(64)
          .borderRadius(32)
          .objectFit(ImageFit.Cover)
          .border({ width: 2, color: '#E9F0FF' })
          .shadow({ radius: 10, color: '#223C7DFF' })
          .position({
            x: this.aboutFlyPx - 32 + this.aboutFlyX,
            y: this.aboutFlyPy - 32 + this.aboutFlyY
          })
          .scale({ x: this.aboutFlyScale, y: this.aboutFlyScale })
          .zIndex(5)
      }
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 180,
      colors: [['#F6FAFF', 0.0], ['#EFF5FF', 0.4], ['#E8F1FF', 1.0]]
    })
  }

  @Builder
  sidebarItem(t: Thread) {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(t.id === this.current ? 22 : 0)
        .borderRadius(2)
        .backgroundColor('#3C7DFF')
      Column({ space: 3 }) {
        Row({ space: 5 }) {
          Text(t.name)
            .fontSize(14)
            .fontFamily('NotoSansSC')
            .fontWeight(t.id === this.current ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(t.id === this.current ? '#1D3A6E' : '#33343A')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (t.id !== this.current && (this.unread[t.id] ?? 0) > 0) {
            Text(`${Math.min(this.unread[t.id], 99)}`)
              .fontSize(10)
              .fontFamily('NotoSansSC')
              .fontColor('#FFFFFF')
              .textAlign(TextAlign.Center)
              .constraintSize({ minWidth: 17 })
              .height(17)
              .padding({ left: 4, right: 4 })
              .borderRadius(9)
              .backgroundColor('#FF453A')
          }
        }
        .width('100%')
        Text(this.workspaces.find((w) => w.path === t.workspace)?.label ?? '工作区')
          .fontSize(11)
          .fontFamily('NotoSansSC')
          .fontColor(t.id === this.current ? '#6F8BC0' : '#9AA3B2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('×')
        .fontSize(14)
        .fontFamily('NotoSansSC')
        .fontColor('#B9BFCA')
        .padding({ left: 6, right: 6 })
        .onClick(() => {
          this.deleteThread(t.id);
        })
    }
    .width('100%')
    .padding({ left: 8, right: 5, top: 10, bottom: 10 })
    .backgroundColor(t.id === this.current ? '#F2F7FF' : '#FFFFFF')
    .border({ width: 1, color: t.id === this.current ? '#D6E4FF' : '#F0F3F9' })
    .borderRadius(12)
    .shadow({ radius: 6, color: '#08003366', offsetY: 1 })
    .animation({ duration: 180, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      this.switchThread(t.id);
    })
  }


  @Builder
  sidebarPanel() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text('聊天区')
          .fontSize(15)
          .fontFamily('NotoSansSC')
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
          .lineHeight(26)
        Text(`${this.threads.length}`)
          .fontSize(10)
          .fontFamily('NotoSansSC')
          .fontColor('#8A8A8E')
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor('#EDEDF0')
          .borderRadius(8)
        Blank()
        Button('＋')
          .type(ButtonType.Circle)
          .width(28)
          .height(28)
          .fontSize(16)
          .fontFamily('NotoSansSC')
          .padding(0)
          .fontColor('#FFFFFF')
          .backgroundColor('#3C7DFF')
          .shadow({ radius: 8, color: '#333C7DFF', offsetY: 2 })
          .onClick(() => {
            this.createThread();
          })
      }
      .width('100%')
      .height(60 + this.safeTop)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 10, top: this.safeTop })
      .border({ width: { bottom: 0.5 }, color: '#EFEFF3' })

      List({ space: 6 }) {
        ForEach(this.threads, (t: Thread) => {
          ListItem() {
            this.sidebarItem(t)
          }
        }, (t: Thread) => t.id)
      }
      .layoutWeight(1)
      .padding({ left: 8, right: 8, top: 2 })

      Row({ space: 8 }) {
        Image($rawfile('icons/gear.svg'))
          .width(16)
          .height(16)
        Text('设置')
          .fontSize(13)
          .fontFamily('NotoSansSC')
          .fontColor('#5F5F66')
        Blank()
      }
      .width('92%')
      .padding({ left: 10, right: 10, top: 9, bottom: 9 })
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#F0F3F9' })
      .borderRadius(12)
      // 与底部输入坞中心对齐：坞高 56vp、离底 28vp → 中心线距底 56vp；
      // 本行高约 36vp，面板底部内边距 8vp，故下外边距取 30vp（8+30+18=56）
      .margin({ bottom: 30 })
      .onClick(() => {
        animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
          this.stClosing = false;
          this.showSettings = true;
        });
        this.refreshCacheSize();
        this.syncSettingsStats();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 8 })
    .linearGradient({
      angle: 180,
      colors: [['#D9F2F7FF', 0.0], ['#E6F9FEFF', 0.45], ['#F2FFFFFF', 1.0]],
    })
    .border({ width: { right: 0.5 }, color: '#E6EEFB' })
    .borderRadius({ topRight: 22, bottomRight: 22 })
    .clip(true)
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
    Row() {
      // 侧边栏：展开态并排
      if (this.showSidebar && !this.sidebarOverlay()) {
        Column() {
          this.sidebarPanel()
        }
        .width(this.parallelW())
        .height('100%')
        .clip(true)
      }

      // 聊天区
      Column() {
        Stack({ alignContent: Alignment.Top }) {
        Row({ space: 8 }) {
          this.headerMenu()
          Image($r('app.media.avatar'))
            .id('hdrAvatar')
            .width(42)
            .height(42)
            .borderRadius(21)
            .objectFit(ImageFit.Cover)
            .border({ width: 2, color: '#E9F0FF' })
            .shadow({ radius: 8, color: '#223C7DFF' })
            .onClick(() => {
              this.openAbout();
            })
          Column({ space: 1 }) {
            Text('大肥鱼')
              .fontSize(18)
              .fontFamily('NotoSansSC')
              .fontWeight(FontWeight.Bold)
              .letterSpacing(0.8)
              .fontColor('#1D1D1F')
              .lineHeight(24)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 5 }) {
              // 状态灯：在线绿、断开红、连接中黄；其余临时提示用灰蓝
              Stack() {
                // 在线时圆点自己呼吸：亮暗 + 一点点放大，1.5s 一个来回
                Circle()
                  .width(7)
                  .height(7)
                  .fill(this.typing ? '#3C7DFF' : this.statusColor())
                  .opacity(this.pulseOn && !this.typing && this.statusColor() === '#34C759' ? 0.55 : 1)
                  .scale({
                    x: this.pulseOn && !this.typing && this.statusColor() === '#34C759' ? 1.16 : 1,
                    y: this.pulseOn && !this.typing && this.statusColor() === '#34C759' ? 1.16 : 1
                  })
              }
              .width(7)
              .height(7)
              Text(this.typing
                ? `正在输入${'.'.repeat(this.dotCount)}`
                : this.subtitleText())
                .fontSize(11)
                .fontFamily('NotoSansSC')
                .fontColor(this.typing ? '#3C7DFF' : '#8A8A8E')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Row() {
            Text(this.showSidebar && !this.sidebarOverlay() && this.winW < 560 ? '' : this.workspaceLabel())
              .fontSize(11.5)
              .fontFamily('NotoSansSC')
              .fontColor('#4A4A4E')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('▾')
              .fontSize(9)
              .fontFamily('NotoSansSC')
              .fontColor('#4A4A4E')
              .margin({ left: 3, top: 1 })
          }
          .height(28)
          .padding({ left: 10, right: 10 })
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor('#F2F3F6')
          .borderRadius(14)
          .onClick(() => {
            animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
              this.showWsPicker = !this.showWsPicker;
            });
          })
        }
        .width('100%')
        .height(60 + this.safeTop)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 14, top: this.safeTop })
        .backgroundColor('#38EEF5FF')
        .backgroundEffect({ radius: 44, saturation: 2.05, brightness: 1.07 })
        .border({ width: { top: 1, bottom: 1 }, color: { top: '#B8FFFFFF', bottom: '#4DFFFFFF' } })
        .shadow({ radius: 18, color: '#1F2E5A8C', offsetY: 4 })
        .zIndex(2)

        List({ scroller: this.scroller, space: 10 }) {
          ForEach(this.messages, (m: ChatMessage, mi: number) => {
            ListItem() {
              Column({ space: 10 }) {
                if (this.isDayStart(mi)) {
                  Row() {
                    Text(this.dayLabel(m.ts))
                      .fontSize(11)
                      .fontFamily('NotoSansSC')
                      .letterSpacing(0.6)
                      .fontColor('#7E8797')
                      .padding({ left: 11, right: 11, top: 4, bottom: 4 })
                      .backgroundColor('#F7FAFF')
                      .borderRadius(10)
                      .border({ width: 0.5, color: '#D9E2F2' })
                      .shadow({ radius: 4, color: '#0F2C5C1A', offsetY: 1 })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                  .margin({ top: 2 })
                }
              Row() {
                if (m.role === 'me') {
                  Blank()
                }
                if (!m.recalled && m.role === 'me') {
                  Text(this.fmtTime(m.ts))
                    .fontFamily('NotoSansSC')
                    .fontSize(11)
                    .fontColor('#A3A9B4')
                    .margin({ right: 6, bottom: 3 })
                }
                if (m.recalled) {
                  Text('已撤回')
                    .fontSize(11)
                    .fontFamily('NotoSansSC')
                    .fontColor('#9A9AA2')
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                } else {
                Column({ space: 6 }) {
                  if (m.sticker) {
                    Image(this.client.mediaUrl(`/stickers/${encodeURIComponent(m.sticker ?? '')}`))
                      .width(178)
                      .constraintSize({ maxHeight: 240 })
                      .objectFit(ImageFit.Contain)
                      .onClick(() => {
                        this.openPreview(this.client.mediaUrl(`/stickers/${encodeURIComponent(m.sticker ?? '')}`));
                      })
                  }
                  if (m.image) {
                    Image(this.client.mediaUrl(m.image ?? ''))
                      .width(160)
                      .constraintSize({ maxHeight: 240 })
                      .borderRadius(12)
                      .objectFit(ImageFit.Contain)
                      .backgroundColor('#F1F1F1')
                      .onClick(() => {
                        this.openPreview(this.client.mediaUrl(m.image ?? ''));
                      })
                      .bindContextMenu(this.imgMenu(m), ResponseType.LongPress)
                  }
                  if (m.audio) {
                    this.voiceBubble(m)
                  }
                  if (m.text) {
                    Column({ space: 5 }) {
                      if (m.quote && m.quote.image) {
                        Row({ space: 6 }) {
                          Image(`${this.client.baseUrl()}${m.quote.image}`)
                            .width(34)
                            .height(34)
                            .borderRadius(5)
                            .objectFit(ImageFit.Cover)
                          Text('图片')
                            .fontSize(11)
                            .fontFamily('NotoSansSC')
                            .fontColor('#6E6E73')
                        }
                        .padding({ left: 5, right: 8, top: 4, bottom: 4 })
                        .backgroundColor('#261E1E28')
                        .borderRadius(7)
                      } else if (m.quote && m.quote.text !== '') {
                        Text(m.quote.text)
                          .fontSize(11)
                          .fontFamily('NotoSansSC')
                          .fontColor('#6E6E73')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                          .backgroundColor('#261E1E28')
                          .borderRadius(7)
                      } else if (this.quoteLine(m.text) !== '') {
                        Text(this.quoteLine(m.text))
                          .fontSize(11)
                          .fontFamily('NotoSansSC')
                          .fontColor('#6E6E73')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                          .backgroundColor('#261E1E28')
                          .borderRadius(7)
                      }
                      this.richText(this.quoteBody(m.text), '#1D1D1F')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .padding({ left: 13, right: 13, top: 11, bottom: 11 })
                    .borderRadius(17)
                    .backgroundColor(m.role === 'me' ? '#D8E9FF' : '#F1F1F1')
                    .constraintSize({ maxWidth: '78%' })
                    .scale({
                      x: this.bounceId === m.id ? this.bounceScale : 1,
                      y: this.bounceId === m.id ? this.bounceScale : 1
                    })
                    .onClick(() => {
                      this.jelly(m.id);
                    })
                    .bindContextMenu(this.msgMenu(m), ResponseType.LongPress)
                  }
                }
                .alignItems(m.role === 'me' ? HorizontalAlign.End : HorizontalAlign.Start)
                }

                if (!m.recalled && m.role !== 'me') {
                  Text(this.fmtTime(m.ts))
                    .fontFamily('NotoSansSC')
                    .fontSize(11)
                    .fontColor('#A3A9B4')
                    .margin({ left: 6, bottom: 3 })
                }

                if (m.role !== 'me') {
                  Blank()
                }
              }
              .alignItems(VerticalAlign.Bottom)
              .width('100%')
              .transition(TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: 8 }))
                .animation({ duration: 200, curve: Curve.FastOutSlowIn }))
              }
              .width('100%')
            }
            // key 里带上撤回标记：只改对象内容、key 不变的话 ForEach 不会重建这一条
          }, (m: ChatMessage) => `${m.id}_${m.recalled ? 'r' : 'n'}`)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 14, right: 18 })
        .contentStartOffset(60 + this.safeTop)
        .onReachStart(() => {
          this.loadOlder();
        })
        .linearGradient({
          angle: 180,
          colors: [['#E6EDFB', 0.0], ['#F3F7FF', 0.55], ['#FFFFFF', 1.0]],
        })
        .contentEndOffset(118)
        .translate({ y: -this.bottomInset() })


        Column() {
        if (this.typing) {
          Row({ space: 6 }) {
            Text('大肥鱼 正在输入')
              .fontSize(11)
              .fontFamily('NotoSansSC')
              .fontColor('#8A8A8E')
            Row({ space: 3 }) {
              Circle().width(4).height(4).fill(this.dotCount >= 1 ? '#3C7DFF' : '#C9D6F5')
              Circle().width(4).height(4).fill(this.dotCount >= 2 ? '#3C7DFF' : '#C9D6F5')
              Circle().width(4).height(4).fill(this.dotCount >= 3 ? '#3C7DFF' : '#C9D6F5')
            }
          }
          .width('100%')
          .padding({ left: 16, bottom: 4 })
          .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
        }

        Column() {
          if (this.quoteText !== '' || this.quoteImage !== '') {
            Row({ space: 6 }) {
              if (this.quoteImage !== '') {
                Image(`${this.client.baseUrl()}${this.quoteImage}`)
                  .width(26)
                  .height(26)
                  .borderRadius(4)
                  .objectFit(ImageFit.Cover)
              }
              Text(this.quoteImage !== '' ? '引用：图片' : `引用：${this.quoteText}`)
                .fontSize(11)
                .fontFamily('NotoSansSC')
                .fontColor('#5F5F66')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('✕')
                .fontSize(12)
                .fontFamily('NotoSansSC')
                .fontColor('#8A8A90')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .onClick(() => {
                  this.quoteText = '';
                  this.quoteImage = '';
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 2 })
          }
          if (this.recOn) {
            Row({ space: 7 }) {
              Text('●')
                .fontSize(9)
                .fontFamily('NotoSansSC')
                .fontColor('#E4574C')
              Text(`正在录音 ${this.recSec}″ · 松开发送`)
                .fontSize(12)
                .fontFamily('NotoSansSC')
                .fontColor('#8A4A44')
            }
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor('#FFF1EF')
            .borderRadius(14)
            .margin({ bottom: 4 })
          }
          Row({ space: 8 }) {
            if (this.leftHold()) {
              this.inputSend()
            }
            if (!this.leftHold()) {
              this.inputIcons()
            }
            this.inputField()
            if (this.leftHold()) {
              this.inputIcons()
            }
            if (!this.leftHold()) {
              this.inputSend()
            }
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 9, bottom: 9 })
        .backgroundColor('#38EEF5FF')
        .backgroundEffect({ radius: 44, saturation: 2.05, brightness: 1.07 })
        .borderRadius(28)
        .border({ width: { top: 1, bottom: 1, left: 1, right: 1 }, color: { top: '#B8FFFFFF', bottom: '#4DFFFFFF', left: '#80FFFFFF', right: '#80FFFFFF' } })
        .shadow({ radius: 28, color: '#2E1E3C6E', offsetY: 10 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ left: 15.1, right: 15.1, bottom: 28 })
        .translate({ y: -this.bottomInset() })
        
        .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .layoutWeight(1)

        // 表情包栏：占用底部空间，气泡区整体上移而不是被盖住
        Column() {
          if (this.showStickers) {
            this.stickerPanel()
          }
        }
        .width('100%')
        .height(this.showStickers ? 288 : 0)
        .clip(true)
        .justifyContent(FlexAlign.End)
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })

        // 键盘占位：高度跟着键盘走，气泡区平滑收缩
        Column()
          .width('100%')
          .height(0)
      }
      .layoutWeight(1)
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .transform(this.foldMatrix())
    .translate({ y: 6 * this.foldT })
    .scale({ x: 1 - 0.05 * this.foldT, y: 1 - 0.03 * this.foldT })
    .opacity(1 - 0.18 * this.foldT)

      if (this.foldT > 0.01) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#000000')
            .opacity(0.26 * this.foldT)
          Column()
            .width(1.5)
            .height('100%')
            .backgroundColor('#FFFFFF')
            .opacity(0.22 * this.foldT)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

      // 折叠/窄屏：侧栏浮在最上层（带遮罩、玻璃底、左侧滑入）
      if ((this.showSidebar || this.sbClosing) && this.sidebarOverlay()) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#40101528')
            .opacity(1 + this.sbX)
            .animation({ duration: 240, curve: Curve.FastOutSlowIn })
            .onClick(() => {
              this.closeSidebarOverlay();
            })
          Column() {
            this.sidebarPanel()
          }
          .width(this.sidePanelW())
          .height('100%')
          .backgroundColor('#CCFFFFFF')
          .backgroundEffect({ radius: 28, saturation: 1.7, brightness: 1.05 })
          .border({ width: { right: 0.5 }, color: '#E6EEFB' })
          .borderRadius({ topRight: 26, bottomRight: 26 })
          .shadow({ radius: 30, color: '#402E5A8C', offsetX: 8 })
          .clip(true)
          .translate({ x: this.sbX * this.sidePanelW() })
          .opacity(1 + this.sbX * 0.35)
          .animation({ duration: 240, curve: Curve.FastOutSlowIn })
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ x: -40 }))
            .animation({ duration: 240, curve: Curve.FastOutSlowIn }))
        }
        .width('100%')
        .height('100%')
        .zIndex(30)
      }

      if (this.showWsPicker) {
        Column() {
          Blank()
            .width('100%')
            .height('100%')
            .onClick(() => {
              animateTo({ duration: 160, curve: Curve.FastOutSlowIn }, () => {
                this.showWsPicker = false;
              });
            })
        }
        .width('100%')
        .height('100%')

        Column({ space: 0 }) {
          ForEach(this.workspaces, (w: WorkspaceOption) => {
            Text(w.label)
              .fontSize(13)
              .fontFamily('NotoSansSC')
              .fontColor(this.currentThread()?.workspace === w.path ? '#3C7DFF' : '#222222')
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .onClick(() => {
                this.showWsPicker = false;
                this.changeWorkspace(w.path);
              })
          }, (w: WorkspaceOption) => w.path)
        }
        .width(150)
        .margin({ top: 74, right: 18 })
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .shadow({ radius: 18, color: '#22000000', offsetY: 4 })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 }))
          .animation({ duration: 180, curve: Curve.FastOutSlowIn }))
      }

      if (this.showSettings) {
        Stack({ alignContent: this.sidebarOverlay() ? Alignment.BottomStart : Alignment.Bottom }) {
          Column() {
            Blank()
              .width('100%')
              .height('100%')
              .onClick(() => {
                this.closeSettings();
              })
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#2E14203A')
          .opacity(this.stClosing ? 0 : 1)
          .animation({ duration: 200, curve: Curve.FastOutSlowIn })

          Column({ space: 12 }) {
            this.settingsBody()
          }
          .width(this.sidebarOverlay() ? this.sidePanelW() : '100%')
          .padding({ left: 18, right: 18, top: 12, bottom: 30 })
          .backgroundColor('#FFFFFF')
          .borderRadius(this.sidebarOverlay() ? { topRight: 22, bottomRight: 22 } : { topLeft: 22, topRight: 22 })
          .shadow({ radius: 24, color: '#26000000', offsetY: -6 })
          .opacity(this.stClosing ? 0 : 1)
          .translate({ y: this.stClosing ? 320 : 0 })
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
        }
        .width('100%')
        .height('100%')
        .zIndex(40)
      }

      if (this.showVoice) {
        Stack({ alignContent: this.sidebarOverlay() ? Alignment.BottomStart : Alignment.Bottom }) {
          Column() {
            Blank()
              .width('100%')
              .height('100%')
              .onClick(() => {
                this.closeVoice();
              })
          }
          .width('100%')
          .height('100%')
          .opacity(this.vcClosing ? 0 : 1)
          .animation({ duration: 180, curve: Curve.FastOutSlowIn })

          Column({ space: 14 }) {
            Row() {
              Text('她的声音')
                .fontSize(15)
                .fontFamily('NotoSansSC')
                .fontWeight(FontWeight.Bold)
                .fontColor('#1D1D1F')
              Blank()
              Text('✕')
                .fontSize(13)
                .fontFamily('NotoSansSC')
                .fontColor('#8A8A90')
                .padding(4)
                .onClick(() => {
                  this.closeVoice();
                })
            }
            .width('100%')

            Column() {
              ForEach(this.voiceOptions, (v: VoiceOption, i: number) => {
                Row() {
                  Column({ space: 2 }) {
                    Text(v.name)
                      .fontSize(14)
                      .fontFamily('NotoSansSC')
                      .fontColor(v.installed ? '#333333' : '#B0B4BC')
                    Text(v.desc || '')
                      .fontSize(10)
                      .fontFamily('NotoSansSC')
                      .fontColor('#9A9AA0')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (!v.installed) {
                    Text('待装')
                      .fontSize(10)
                      .fontFamily('NotoSansSC')
                      .fontColor('#B0B4BC')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(6)
                      .backgroundColor('#F2F3F6')
                  } else if (this.voiceId === v.id) {
                    Text('✓')
                      .fontSize(14)
                      .fontFamily('NotoSansSC')
                      .fontColor('#3C7DFF')
                  }
                }
                .width('100%')
                .padding({ top: 11, bottom: 11 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.pickVoice(v);
                })

                if (i < this.voiceOptions.length - 1) {
                  Divider().strokeWidth(0.5).color('#F0F1F4')
                }
              }, (v: VoiceOption) => v.id)
            }
            .width('100%')

            if (this.voiceOptions.length === 0) {
              Text('还没连上服务端，等一下再试')
                .fontSize(11)
                .fontFamily('NotoSansSC')
                .fontColor('#9A9AA0')
            }
          }
          .width(this.sidebarOverlay() ? this.sidePanelW() : '100%')
          .padding({ left: 18, right: 18, top: 14, bottom: 26 })
          .backgroundColor('#FFFFFF')
          .borderRadius(this.sidebarOverlay() ? { topRight: 22, bottomRight: 22 } : { topLeft: 22, topRight: 22 })
          .shadow({ radius: 24, color: '#26000000', offsetY: -6 })
          .opacity(this.vcClosing ? 0 : 1)
          .translate({ y: this.vcClosing ? 300 : 0 })
          .animation({ duration: 200, curve: Curve.FastOutSlowIn })
        }
        .width('100%')
        .height('100%')
        .zIndex(50)
      }

      if (this.showAbout) {
        Stack() {
          this.aboutPage()
        }
        .width('100%')
        .height('100%')
        .opacity(this.aboutFade)
        .zIndex(60)
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: 24 }))
          .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
      }

      if (this.splash) {
        Stack() {
          Stack()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['#F6FAFF', 0.0], ['#EEF5FF', 0.35], ['#E6F0FF', 0.7], ['#DDE9FF', 1.0]]
            })
            .opacity(this.splashBg)
          Column({ space: 10 }) {
            Stack() {
              Image($r('app.media.avatar_alpha'))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .opacity(1 - this.splashFrame)
              Image($r('app.media.avatar'))
                .width('100%')
                .height('100%')
                .borderRadius(this.flyRadius)
                .clip(true)
                .objectFit(ImageFit.Cover)
                .border({ width: 2, color: '#E9F0FF' })
                .shadow({ radius: 8, color: '#223C7DFF' })
                .opacity(this.splashFrame)
            }
            .id('splashIcon')
            .width(this.flySize)
            .height(this.flySize)
            .scale({ x: this.splashScale, y: this.splashScale })
            .translate({ x: this.flyX, y: this.flyY })
            Column({ space: 6 }) {
              Text('大肥鱼')
                .fontSize(22)
                .fontFamily('NotoSansSC')
                .fontWeight(FontWeight.Bold)
                .fontColor('#1D1D1F')
              Text('在的，你随时喊。')
                .fontSize(12)
                .fontFamily('NotoSansSC')
                .fontColor('#7A8698')
              Text('形象来源（原项目）：B站 @上善无形 · @ZipZipPipe · 当前为占位图')
                .fontSize(10)
                .fontFamily('NotoSansSC')
                .fontColor('#9AA6B6')
                .margin({ top: 1 })
              Row({ space: 6 }) {
                ForEach([0, 1, 2], (i: number) => {
                  Circle()
                    .width(6)
                    .height(6)
                    .fill('#8FB4E8')
                    .opacity(this.splashDot === i ? 1 : 0.3)
                }, (i: number) => `${i}`)
              }
              .margin({ top: 6 })
            }
            .opacity(this.splashTitle)
            .margin({ top: 6 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .opacity(this.splashOpacity)
      }

      if (this.previewSrc !== '') {
        Stack() {
          Image(this.previewSrc)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F2000000')
        .onClick(() => {
          this.closePreview();
        })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 }))
          .animation({ duration: 220, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w = Number(newArea.width);
      if (w > 0) {
        this.winW = w;
      }
      // 折叠/窄屏时记下浮层侧栏的实际宽度，展开后的并排侧栏沿用它
      if (w > 0 && w < 700) {
        const pw: number = w * 0.78 > 300 ? 300 : w * 0.78;
        if (Math.abs(pw - this.foldedPanelW) > 0.5) {
          this.foldedPanelW = pw;
          this.saveFoldedW(pw);
        }
      }
      if (!this.userToggledSidebar && w > 0) {
        const want = w >= 700;
        if (want !== this.showSidebar) {
          animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
            this.showSidebar = want;
          });
        }
      }
    })
  }
}
