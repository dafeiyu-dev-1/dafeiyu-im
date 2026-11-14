import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { WebSocketServer } from 'ws';
import { execFile } from 'node:child_process';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const PORT = Number(process.env.IM_PORT || 8787);
const TOKEN = process.env.IM_TOKEN || 'change-me';
const DATA_DIR = path.join(import.meta.dirname, 'data');
const MSG_FILE = path.join(DATA_DIR, 'messages.jsonl');
const THREAD_FILE = path.join(DATA_DIR, 'threads.json');
const UP_DIR = path.join(DATA_DIR, 'uploads');
const CFG_FILE = path.join(DATA_DIR, 'config.json');
/** 表情包：首次启动时从她的 QQ 表情库拷一份过来，之后以 data/stickers 为准 */
const STICKER_DIR = path.join(DATA_DIR, 'stickers');
// 表情包种子目录：留空则跳过；也可以指向你自己的 stickers 目录
const STICKER_SEED = process.env.STICKER_SEED || '';
const STICKER_EXT = ['.png', '.jpg', '.jpeg', '.gif', '.webp'];
/** 表情分类与自定义顺序：{ inline: [...], custom: [...] } */
const CATS_FILE = path.join(STICKER_DIR, 'cats.json');
// 表情插件（dsh-meme）的图库：有就一起并进表情面板，前缀 meme_
const MEME_ROOTS = [
  path.join(os.homedir(), '.dsh', 'meme-packs'),
  path.join(os.homedir(), '.dsh', 'profiles', 'desktop', 'node_modules', 'dsh-meme', 'memes')
];
/** 名字 → 真实文件路径（贴纸库之外的图，比如插件库） */
const stickerFiles = new Map();
/** 名字 → { tag, meaning, pack }：图库那边的情绪分类与说明 */
const stickerMeta = new Map();

/** 读某个图库包的 index.db，拿到 file_name → {tag, caption} */
function readPackIndex(packDir) {
  const out = new Map();
  const dbFile = path.join(packDir, 'index.db');
  if (!fs.existsSync(dbFile)) return out;
  try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(dbFile, { readOnly: true });
    for (const row of db.prepare('SELECT file_name, tag, caption FROM memes').all()) {
      out.set(row.file_name, { tag: row.tag ?? '', caption: row.caption ?? '' });
    }
    db.close();
  } catch (e) {
    console.warn('[stickers] 读不了图库索引', packDir, e.message);
  }
  return out;
}

function readPackName(packDir) {
  try {
    const m = JSON.parse(fs.readFileSync(path.join(packDir, 'manifest.json'), 'utf8'));
    return m.name || path.basename(packDir);
  } catch {
    return path.basename(packDir);
  }
}

/** 语音合成：独立 python 环境（edge-tts + RVC 胡桃音色） */
const VOICE_ROOT = path.join(import.meta.dirname, '..', '..');
const VOICE_PY = path.join(VOICE_ROOT, 'voice-env', 'Scripts', 'python.exe');
const VOICE_SCRIPT = path.join(VOICE_ROOT, 'voice-dl', 'tts_hutao.py');
/** 常驻合成服务：模型只加载一次，一句约 2 秒 */
const TTS_DAEMON = process.env.TTS_DAEMON || 'http://127.0.0.1:8788';
/** GPU 一次只能跑一个合成任务，按顺序来 */
let ttsQueue = Promise.resolve();
/** 合成参数变了就改这个，旧缓存自动失效（不然会一直发旧音频） */
const TTS_VERSION = 'p5';

/** 音色表（和 voice-dl/tts_daemon.py 的 VOICES 保持一致）；installed 以守护进程回报为准 */
const VOICE_LIST = [
  { id: 'hutao', name: '胡桃', desc: '活泼、尾音上扬' },
  { id: 'tomori', name: '高松灯', desc: '轻、怯、气声多' },
  { id: 'fuxuan', name: '符玄', desc: '清亮、有点距离感（推理包作者：红血球AE3803）' },
  { id: 'xilian', name: '昔涟', desc: '轻柔、气声细（推理包作者：红血球AE3803）' },
];
const PREFS_FILE = path.join(DATA_DIR, 'prefs.json');

function readPrefs() {
  try {
    return JSON.parse(fs.readFileSync(PREFS_FILE, 'utf8')) || {};
  } catch {
    return {};
  }
}

function writePrefs(obj) {
  fs.mkdirSync(path.dirname(PREFS_FILE), { recursive: true });
  fs.writeFileSync(PREFS_FILE, JSON.stringify(obj, null, 2));
}

function voicePref() {
  const v = readPrefs().voice;
  return VOICE_LIST.some((x) => x.id === v) ? v : 'hutao';
}

/** 音色列表 + 当前值；能连上合成服务就用它回报的 installed 状态 */
async function voiceState() {
  let voices = VOICE_LIST.map((v) => ({ ...v, installed: v.id === 'hutao' }));
  let current = voicePref();
  try {
    const r = await fetch(`${TTS_DAEMON}/health`, { signal: AbortSignal.timeout(1500) });
    const j = await r.json();
    if (Array.isArray(j.voices)) {
      const byId = new Map(j.voices.map((v) => [v.id, v]));
      voices = VOICE_LIST.map((v) => {
        const d = byId.get(v.id);
        return { ...v, installed: !!(d && d.installed) };
      });
      // j.voice 是守护进程“已加载”的音色，不代表用户选的偏好，不能覆盖 current
    }
  } catch {
    // 守护进程没起来：保持 fallback，hutao 算可用
  }
  if (!voices.some((v) => v.id === current && v.installed)) current = voicePref();
  return { current, voices };
}

/** ===== 华为 Push Kit ===== */
const PUSH_FILE = path.join(DATA_DIR, 'push-tokens.json');
const PUSH_CONFIG_FILE = path.join(DATA_DIR, 'push-config.json');
// 通知右侧大图需要公网 HTTPS 直链；配了 PUSH_IMAGE_BASE 才会给表情/图片消息带上 image
const PUSH_IMAGE_BASE_ENV = (process.env.PUSH_IMAGE_BASE || '').replace(/\/+$/, '');

/** 通知大图的公网前缀：优先 env，否则用 Cloudflare 备用隧道（换域名时会自动跟着 urls.txt 变） */
function pushImageBase() {
  if (PUSH_IMAGE_BASE_ENV) return PUSH_IMAGE_BASE_ENV;
  try {
    const txt = fs.readFileSync(path.join(import.meta.dirname, '..', 'tools', 'bin', 'urls.txt'), 'utf8');
    const m = txt.match(/wss:\/\/([a-z0-9-]+\.trycloudflare\.com)\/ws/i);
    return m ? `https://${m[1]}` : '';
  } catch {
    return '';
  }
}
const pushConfig = (() => {
  let fileCfg = {};
  try {
    fileCfg = JSON.parse(fs.readFileSync(PUSH_CONFIG_FILE, 'utf8'));
  } catch {
    fileCfg = {};
  }
  return {
    appId: process.env.PUSH_APP_ID || fileCfg.appId || '',
    clientId: process.env.PUSH_CLIENT_ID || fileCfg.clientId || '',
    clientSecret: process.env.PUSH_CLIENT_SECRET || fileCfg.clientSecret || '',
    serviceAccount: process.env.PUSH_SERVICE_ACCOUNT || fileCfg.serviceAccount || '',
    projectId: process.env.PUSH_PROJECT_ID || fileCfg.projectId || '',
  };
})();
const PUSH_APP_ID = pushConfig.appId;
const PUSH_CLIENT_ID = pushConfig.clientId;
const PUSH_CLIENT_SECRET = pushConfig.clientSecret;
/** 服务账号 JSON 路径（AGC 项目设置 → 服务账号 下载的那个），二选一 */
const PUSH_SERVICE_ACCOUNT = pushConfig.serviceAccount;
const PUSH_PROJECT_ID = pushConfig.projectId;
/** 取到的 access_token 缓存 */
let pushTokenCache = { token: '', exp: 0 };

function loadPushTokens() {
  try {
    const arr = JSON.parse(fs.readFileSync(PUSH_FILE, 'utf8'));
    return Array.isArray(arr) ? arr.filter((t) => typeof t === 'string' && t.length > 0) : [];
  } catch {
    return [];
  }
}

function savePushTokens(list) {
  try {
    fs.writeFileSync(PUSH_FILE, JSON.stringify([...new Set(list)], null, 2));
  } catch (e) {
    console.warn('[push] 存 token 失败', e.message);
  }
}

function pushConfigured() {
  return PUSH_APP_ID !== '' && ((PUSH_CLIENT_ID !== '' && PUSH_CLIENT_SECRET !== '') || PUSH_SERVICE_ACCOUNT !== '');
}

/** 用服务账号私钥签一个 JWT（RS256），拿去换 access_token */
function pushServiceAccountJwt(sa) {
  const now = Math.floor(Date.now() / 1000);
  const header = { kid: sa.key_id || sa.kid || '', typ: 'JWT', alg: 'PS256' };
  const claims = {
    aud: 'https://oauth-login.cloud.huawei.com/oauth2/v3/token',
    iss: sa.sub_account || sa.client_id,
    iat: now,
    exp: now + 3600,
  };
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const signInput = `${b64(header)}.${b64(claims)}`;
  // 华为要求 PS256（RSA-PSS + SHA256 + 摘要长度盐）
  const sig = crypto.sign('RSA-SHA256', Buffer.from(signInput), {
    key: sa.private_key,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST,
  });
  return `${signInput}.${sig.toString('base64url')}`;
}

/** 读服务账号 JSON（缓存） */
let saCache = null;
function loadServiceAccount() {
  if (saCache) return saCache;
  if (!PUSH_SERVICE_ACCOUNT) return null;
  try { saCache = JSON.parse(fs.readFileSync(PUSH_SERVICE_ACCOUNT, 'utf8')); } catch (e) { saCache = null; }
  return saCache;
}

/** 拿 access_token：有服务账号私钥走 JWT，否则退回 Client ID/Secret */
async function pushAccessToken() {
  if (pushTokenCache.token && Date.now() < pushTokenCache.exp - 60000) return pushTokenCache.token;
  const sa = loadServiceAccount();
  let body;
  if (sa && sa.private_key) {
    body = new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: pushServiceAccountJwt(sa),
    });
  } else {
    body = new URLSearchParams({ grant_type: 'client_credentials', client_id: PUSH_CLIENT_ID, client_secret: PUSH_CLIENT_SECRET });
  }
  const r = await fetch('https://oauth-login.cloud.huawei.com/oauth2/v3/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
    signal: AbortSignal.timeout(15000),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error(`oauth failed: ${JSON.stringify(j).slice(0, 200)}`);
  pushTokenCache = { token: j.access_token, exp: Date.now() + Number(j.expires_in || 3600) * 1000 };
  return pushTokenCache.token;
}

/** 发一条通知：title/body，点开拉起 App */
async function sendPush(title, body, threadId, imageUrl = '') {
  if (!pushConfigured()) return { ok: false, error: 'push not configured' };
  const tokens = loadPushTokens();
  if (tokens.length === 0) return { ok: false, error: 'no tokens' };
  try {
    const useJwt = PUSH_SERVICE_ACCOUNT !== '';
    // v3 直接吃服务账号 JWT：不用再换 access_token（换 token 那条路华为侧验签一直 20504）
    const access = useJwt ? pushServiceAccountJwt(loadServiceAccount()) : await pushAccessToken();
    const url = useJwt
      ? `https://push-api.cloud.huawei.com/v3/${PUSH_PROJECT_ID}/messages:send`
      : `https://push-api.cloud.huawei.com/v3/${PUSH_APP_ID}/messages:send`;
    const payload = useJwt
      ? {
          pushOptions: { testMessage: false, ttl: 86400 },
          target: { token: tokens },
          payload: {
            notification: {
              category: 'IM',
              title,
              body,
              ...(imageUrl ? { image: imageUrl } : {}),
              clickAction: { actionType: 1, action: 'ohos.want.action.viewData', uri: `dafeiyu://chat?threadId=${threadId}` },
            },
          },
        }
      : {
          message: {
            notification: { title, body },
            data: JSON.stringify({ threadId, kind: 'chat' }),
            token: tokens,
          },
        };
    const r = await fetch(url, {
      method: 'POST',
      headers: { authorization: `Bearer ${access}`, 'content-type': 'application/json', 'push-type': '0' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(15000),
    });
    const txt = await r.text();
    console.log(new Date().toISOString(), '[push]', r.status, txt.slice(0, 300));
    return { ok: r.ok, status: r.status, raw: txt.slice(0, 300) };
  } catch (e) {
    console.log(new Date().toISOString(), '[push] failed:', String((e && e.message) || e).slice(0, 200));
    return { ok: false, error: String((e && e.message) || e) };
  }
}

const FFPROBE = process.env.FFPROBE || 'ffprobe';

/** 读音频时长（毫秒），失败给 0 */
function audioDurationMs(full) {
  return new Promise((resolve) => {
    execFile(FFPROBE, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', full],
      { timeout: 20000, windowsHide: true }, (err, stdout) => {
        if (err) return resolve(0);
        const s = parseFloat(String(stdout || '').trim());
        resolve(Number.isFinite(s) && s > 0 ? Math.round(s * 1000) : 0);
      });
  });
}

/** 语音转文字：优先常驻服务，起不来就一次性进程 */
async function asrFile(fullPath) {
  try {
    const r = await fetch(`${TTS_DAEMON}/asr`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ path: fullPath }),
      signal: AbortSignal.timeout(180000),
    });
    const j = await r.json();
    if (j.ok) return String(j.text || '');
    throw new Error(String(j.error || 'asr failed'));
  } catch (e) {
    console.log(new Date().toISOString(), 'asr daemon 没响应:', String((e && e.message) || e).slice(0, 160));
    const out = await new Promise((resolve, reject) => {
      execFile(VOICE_PY, [path.join(VOICE_ROOT, 'voice-dl', 'asr_once.py'), fullPath], { timeout: 300000, windowsHide: true }, (err, stdout, stderr) => {
        if (err) reject(new Error(String(stderr || err.message).slice(-300)));
        else resolve(stdout);
      });
    });
    return String(out || '').trim();
  }
}

/** 按文件头认图片格式；认不出返回空串 */
function sniffImageExt(b) {
  if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'png';
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8) return 'jpg';
  if (b.length > 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return 'gif';
  if (b.length > 12 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return 'webp';
  return '';
}
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(UP_DIR, { recursive: true });
fs.mkdirSync(STICKER_DIR, { recursive: true });

/**
 * 允许她使用的工作区。切换工作区 = 换一个 cwd，她的人设/记忆照旧（都由 DSH 那边提供）
 * @type {{label:string, path:string}[]}
 */
const WORKSPACES = [
  { label: '默认工作区', path: process.env.DEFAULT_WORKSPACE || process.cwd() },
];

/**
 * @typedef {{id:string,name:string,workspace:string,createdAt:number}} Thread
 * @typedef {{id:string,threadId:string,role:'me'|'her',text:string,image?:string,ts:number,acked?:boolean}} Msg
 */

/** @type {Thread[]} */
let threads = [];
/** @type {Msg[]} */
const messages = [];
/** 撤回事件（给桥插件轮询用；只留最近 200 条） */
const recallEvents = [];

function loadThreads() {
  if (fs.existsSync(THREAD_FILE)) {
    try {
      const arr = JSON.parse(fs.readFileSync(THREAD_FILE, 'utf8'));
      if (Array.isArray(arr)) threads = arr;
    } catch {}
  }
  if (threads.length === 0) {
    threads = [{ id: 'main', name: '主聊天', workspace: WORKSPACES[0].path, createdAt: Date.now() }];
    saveThreads();
  }
}

function saveThreads() {
  fs.writeFileSync(THREAD_FILE, JSON.stringify(threads, null, 2));
}

function loadHistory() {
  if (!fs.existsSync(MSG_FILE)) return;
  for (const line of fs.readFileSync(MSG_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const m = JSON.parse(line);
      if (!m.threadId) m.threadId = 'main';
      messages.push(m);
      // 重启后把历史里的撤回也补进事件队列，免得重启这段空窗里的撤回漏报
      if (m.recalled && m.recalledAt) {
        recallEvents.push({ id: m.id, threadId: m.threadId, ts: m.recalledAt, role: m.role });
      }
    } catch {}
  }
  recallEvents.sort((a, b) => a.ts - b.ts);
  if (recallEvents.length > 200) recallEvents.splice(0, recallEvents.length - 200);
}

function append(m) {
  messages.push(m);
  fs.appendFileSync(MSG_FILE, JSON.stringify(m) + '\n');
}

/** 重写整个消息文件：ack 状态需要落盘，否则重启后会重复投递 */
function rewrite() {
  const tmp = MSG_FILE + '.tmp';
  fs.writeFileSync(tmp, messages.map((m) => JSON.stringify(m)).join('\n') + '\n');
  fs.renameSync(tmp, MSG_FILE);
}

function newId() {
  return crypto.randomBytes(8).toString('hex');
}

/** 表情包清单：文件名 + 从 index.md 里抠出来的释义 */
let stickerList = [];
function seedStickers() {
  const have = fs.readdirSync(STICKER_DIR).filter((f) => STICKER_EXT.includes(path.extname(f).toLowerCase()));
  if (have.length === 0 && fs.existsSync(STICKER_SEED)) {
    for (const f of fs.readdirSync(STICKER_SEED)) {
      if (!STICKER_EXT.includes(path.extname(f).toLowerCase())) continue;
      try {
        fs.copyFileSync(path.join(STICKER_SEED, f), path.join(STICKER_DIR, f));
      } catch {}
    }
  }
  const meaning = new Map();
  const md = path.join(STICKER_SEED, 'index.md');
  if (fs.existsSync(md)) {
    for (const line of fs.readFileSync(md, 'utf8').split('\n')) {
      const m = line.match(/^\|\s*\`([^\`]+)\`\s*\|\s*(.+?)\s*\|\s*$/);
      if (m) meaning.set(m[1].trim(), m[2].trim());
    }
  }
  const groupOf = (f) => {
    const base = f.replace(/\.[^.]+$/, '');
    const i = base.indexOf('-');
    return i > 0 ? base.slice(0, i) : '';
  };
  // 小表情（能夹在文字里）以 cats.json 为准；其余整张发
  let inlineSet = new Set();
  let customOrder = [];
  const catsFile = path.join(STICKER_DIR, 'cats.json');
  if (fs.existsSync(catsFile)) {
    try {
      const cats = JSON.parse(fs.readFileSync(catsFile, 'utf8'));
      for (const f of cats.inline || []) inlineSet.add(f);
      customOrder = Array.isArray(cats.custom) ? cats.custom : [];
    } catch (e) {
      console.warn('cats.json 读不了:', e.message);
    }
  }
  const orderIndex = (f) => {
    const i = customOrder.indexOf(f);
    return i < 0 ? customOrder.length + 1 : i;
  };
  const own = fs
    .readdirSync(STICKER_DIR)
    .filter((f) => STICKER_EXT.includes(path.extname(f).toLowerCase()));
  stickerFiles.clear();
  for (const f of own) stickerFiles.set(f, path.join(STICKER_DIR, f));

  // 把我自己的表情库（memes 插件）也并进来，名字前缀 meme_<包名>_
  const memes = [];
  stickerMeta.clear();
  const walk = (dir, packId, packName, index) => {
    let ents = [];
    try {
      ents = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of ents) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        walk(full, packId, packName, index);
      } else if (STICKER_EXT.includes(path.extname(e.name).toLowerCase())) {
        const safe = e.name.replace(/[^\w\u4e00-\u9fa5.-]/g, '_');
        const short = packId
          .replace(/^dafeiyu-/, '')
          .replace(/[^\w]/g, '')
          .slice(0, 8);
        const name = `meme_${short}_${safe}`;
        if (!stickerFiles.has(name)) {
          stickerFiles.set(name, full);
          memes.push(name);
          const hit = index.get(e.name) || index.get(safe);
          stickerMeta.set(name, {
            tag: hit ? hit.tag : '',
            meaning: hit ? hit.caption : '',
            pack: packName
          });
        }
      }
    }
  };
  for (const root of MEME_ROOTS) {
    let packs = [];
    try {
      packs = fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory());
    } catch {
      continue;
    }
    for (const d of packs) {
      const packDir = path.join(root, d.name);
      const memesDir = path.join(packDir, 'memes');
      if (!fs.existsSync(memesDir)) continue;
      walk(memesDir, d.name, readPackName(packDir), readPackIndex(packDir));
    }
  }

  const isCustom = (f) => f.startsWith('用户_');
  stickerList = [...own, ...memes]
    .sort((a, b) => {
      const ca = isCustom(a);
      const cb = isCustom(b);
      if (ca && cb) return orderIndex(a) - orderIndex(b) || a.localeCompare(b, 'zh');
      if (ca !== cb) return ca ? -1 : 1;
      const ga = groupOf(a);
      const gb = groupOf(b);
      if (ga !== gb) return ga.localeCompare(gb, 'zh');
      return a.localeCompare(b, 'zh');
    })
    .map((f) => {
      const meta = stickerMeta.get(f);
      void orderIndex;
      const cat = inlineSet.has(f) ? 'inline' : f.startsWith('用户_') ? 'custom' : 'pack';
      return {
        file: f,
        name: f.replace(/\.[^.]+$/, ''),
        meaning: meta ? meta.meaning : meaning.get(f) ?? '',
        tag: meta ? meta.tag : '',
        pack: meta ? meta.pack : '',
        cat,
      };
    });
}

const isSticker = (f) =>
  typeof f === 'string' && f !== '' && path.basename(f) === f && STICKER_EXT.includes(path.extname(f).toLowerCase());

const threadById = (id) => threads.find((t) => t.id === id);

/** @type {Set<import('ws').WebSocket>} */
const clients = new Set();

function broadcast(payload) {
  const data = JSON.stringify(payload);
  for (const ws of clients) {
    if (ws.readyState === 1) ws.send(data);
  }
}

function authorized(req) {
  const h = req.headers['authorization'] || '';
  if (h === `Bearer ${TOKEN}`) return true;
  const u = new URL(req.url, 'http://x');
  return u.searchParams.get('token') === TOKEN;
}

function json(res, code, body) {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': buf.length });
  res.end(buf);
}

function readBody(req, limit = 25 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    /** @type {Buffer[]} */
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const EXT_BY_TYPE = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'audio/mp4': 'm4a',
  'audio/m4a': 'm4a',
  'audio/aac': 'm4a',
  'audio/mpeg': 'mp3',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'application/octet-stream': '',
};

/** 按文件头认音频格式：m4a / mp3 / wav；认不出返回空串 */
function sniffAudioExt(b) {
  if (b.length > 12 && b.toString('latin1', 4, 8) === 'ftyp') return 'm4a';
  if (b.length > 3 && b.toString('latin1', 0, 3) === 'ID3') return 'mp3';
  if (b.length > 2 && b[0] === 0xff && (b[1] & 0xe0) === 0xe0) return 'mp3';
  if (b.length > 12 && b.toString('latin1', 0, 4) === 'RIFF' && b.toString('latin1', 8, 12) === 'WAVE') return 'wav';
  return '';
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  if (!u.pathname.startsWith('/files/')) console.log(new Date().toISOString(), req.method, u.pathname);

  // 健康检查免鉴权
  if (u.pathname === '/health') {
    return json(res, 200, { ok: true, clients: clients.size, count: messages.length, threads: threads.length });
  }

  // 图片文件：手机端 <Image> 直接拿，带 token 也行，不带也行（只读静态图）
  if (u.pathname.startsWith('/files/') && req.method === 'GET') {
    const name = path.basename(u.pathname.slice('/files/'.length));
    const p = path.join(UP_DIR, name);
    if (!p.startsWith(UP_DIR) || !fs.existsSync(p)) {
      res.writeHead(404);
      return res.end('not found');
    }
    const ext = path.extname(p).slice(1).toLowerCase();
    const AUDIO_TYPES = { mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', wav: 'audio/wav' };
    const type = AUDIO_TYPES[ext]
      ? AUDIO_TYPES[ext]
      : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : 'image/jpeg';
    res.writeHead(200, { 'content-type': type, 'cache-control': 'public, max-age=31536000' });
    return fs.createReadStream(p).pipe(res);
  }

  // 表情包图片：手机端 <Image> 直接取
  if (u.pathname.startsWith('/stickers/') && req.method === 'GET') {
    let name = path.basename(u.pathname.slice('/stickers/'.length));
    try {
      name = decodeURIComponent(name);
    } catch {
      // 已经是原文就原样用
    }
    const p = stickerFiles.get(name) ?? path.join(STICKER_DIR, name);
    if (!isSticker(name) || !fs.existsSync(p)) {
      res.writeHead(404);
      return res.end('not found');
    }
    const ext = path.extname(p).slice(1).toLowerCase();
    const type =
      ext === 'png' ? 'image/png' : ext === 'gif' ? 'image/gif' : ext === 'webp' ? 'image/webp' : 'image/jpeg';
    res.writeHead(200, { 'content-type': type, 'cache-control': 'public, max-age=31536000' });
    return fs.createReadStream(p).pipe(res);
  }

  if (!authorized(req)) return json(res, 401, { ok: false, error: 'unauthorized' });

  // 表情包清单
  if (u.pathname === '/stickers' && req.method === 'GET') {
    return json(res, 200, { ok: true, list: stickerList });
  }

  // 把某张自定义表情移到最前
  if (u.pathname === '/stickers/front' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)) || '{}');
    const name = path.basename(String(body.file || ''));
    if (!name.startsWith('用户_') || !isSticker(name)) {
      return json(res, 400, { ok: false, error: '只支持自定义表情' });
    }
    const cats = fs.existsSync(CATS_FILE) ? JSON.parse(fs.readFileSync(CATS_FILE, 'utf8')) : {};
    const list = Array.isArray(cats.custom) ? cats.custom.filter((f) => f !== name) : [];
    cats.custom = [name, ...list];
    fs.writeFileSync(CATS_FILE, JSON.stringify(cats, null, 2));
    seedStickers();
    return json(res, 200, { ok: true });
  }

  // 删掉自己加的表情（只允许删「用户_」开头的）
  if (u.pathname === '/stickers/delete' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)) || '{}');
    const name = path.basename(String(body.file || ''));
    if (!name.startsWith('用户_') || !isSticker(name)) {
      return json(res, 400, { ok: false, error: '只能删自己加的' });
    }
    const full = path.join(STICKER_DIR, name);
    try {
      if (fs.existsSync(full)) fs.unlinkSync(full);
      const cats = fs.existsSync(CATS_FILE) ? JSON.parse(fs.readFileSync(CATS_FILE, 'utf8')) : {};
      if (Array.isArray(cats.custom)) {
        cats.custom = cats.custom.filter((f) => f !== name);
        fs.writeFileSync(CATS_FILE, JSON.stringify(cats, null, 2));
      }
    } catch (e) {
      return json(res, 500, { ok: false, error: e.message });
    }
    seedStickers();
    return json(res, 200, { ok: true, total: stickerList.length });
  }

  // 自己加一张表情：直接 POST 图片字节
  if (u.pathname === '/stickers/add' && req.method === 'POST') {
    const buf = await readBody(req);
    const sniffed = sniffImageExt(buf);
    if (!sniffed) {
      return json(res, 400, { ok: false, error: '只收图片' });
    }
    const ext = sniffed.startsWith('.') ? sniffed : `.${sniffed}`;
    const name = `用户_${crypto.createHash('sha256').update(buf).digest('hex').slice(0, 10)}${ext}`;
    const full = path.join(STICKER_DIR, name);
    if (!fs.existsSync(full)) fs.writeFileSync(full, buf);
    seedStickers();
    return json(res, 200, { ok: true, file: name, total: stickerList.length });
  }

  // 可用工作区列表
  if (u.pathname === '/typing' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const threadId = String(body.threadId || 'main');
      const on = !!body.on;
      broadcast({ type: 'typing', threadId, on });
      return json(res, 200, { ok: true, threadId, on });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (u.pathname === '/workspaces' && req.method === 'GET') {
    return json(res, 200, { ok: true, list: WORKSPACES });
  }

  // 聊天区：列表 / 新建 / 改名 / 删除
  if (u.pathname === '/threads' && req.method === 'GET') {
    return json(res, 200, { ok: true, list: threads });
  }

  if (u.pathname === '/threads' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const name = String(body.name || '').trim() || '新聊天';
      const workspace = WORKSPACES.some((w) => w.path === body.workspace) ? body.workspace : WORKSPACES[0].path;
      const t = { id: newId(), name, workspace, createdAt: Date.now() };
      threads.push(t);
      saveThreads();
      broadcast({ type: 'threads', list: threads });
      return json(res, 200, { ok: true, thread: t });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (u.pathname === '/threads' && req.method === 'PATCH') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const t = threadById(String(body.id || ''));
      if (!t) return json(res, 404, { ok: false, error: 'no such thread' });
      if (typeof body.name === 'string' && body.name.trim()) t.name = body.name.trim();
      if (WORKSPACES.some((w) => w.path === body.workspace)) t.workspace = body.workspace;
      saveThreads();
      broadcast({ type: 'threads', list: threads });
      return json(res, 200, { ok: true, thread: t });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (u.pathname === '/threads' && req.method === 'DELETE') {
    const id = u.searchParams.get('id') || '';
    if (threads.length <= 1) return json(res, 400, { ok: false, error: '至少保留一个聊天区' });
    const i = threads.findIndex((t) => t.id === id);
    if (i < 0) return json(res, 404, { ok: false, error: 'no such thread' });
    threads.splice(i, 1);
    saveThreads();
    broadcast({ type: 'threads', list: threads });
    return json(res, 200, { ok: true });
  }

  // 上传图片：原始字节 + content-type
  if (u.pathname === '/upload' && req.method === 'POST') {
    try {
      const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
      const buf = await readBody(req);
      if (buf.length === 0) return json(res, 400, { ok: false, error: 'empty' });
      // 相册给过来的 Content-Type 常常和真格式对不上（PNG 报成 jpeg），
      // 所以优先按文件头的魔数认，认不出来再退回 Content-Type。
      const ext = sniffImageExt(buf) || sniffAudioExt(buf) || EXT_BY_TYPE[type];
      if (!ext) return json(res, 415, { ok: false, error: '只收图片和语音' });
      // 内容寻址：同名文件即同一份内容，重复上传不再落盘
      const hash = crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16);
      const name = `${hash}.${ext}`;
      const full = path.join(UP_DIR, name);
      if (fs.existsSync(full)) {
        return json(res, 200, { ok: true, path: `/files/${name}`, bytes: buf.length, deduped: true });
      }
      fs.writeFileSync(full, buf);
      return json(res, 200, { ok: true, path: `/files/${name}`, bytes: buf.length, deduped: false });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // 存储占用（图片、语音都是内容寻址的，重复内容不会重复占盘）
  if (u.pathname === '/storage' && req.method === 'GET') {
    const AUDIO_EXT = new Set(['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.opus']);
    const img = { files: 0, bytes: 0 };
    const aud = { files: 0, bytes: 0 };
    for (const f of fs.readdirSync(UP_DIR)) {
      const full = path.join(UP_DIR, f);
      const st = fs.statSync(full);
      if (!st.isFile()) continue;
      if (AUDIO_EXT.has(path.extname(f).toLowerCase())) {
        aud.files += 1;
        aud.bytes += st.size;
      } else {
        img.files += 1;
        img.bytes += st.size;
      }
    }
    return json(res, 200, {
      ok: true,
      files: img.files + aud.files,
      bytes: img.bytes + aud.bytes,
      images: img,
      audio: aud,
    });
  }

  // 音色：读当前值 + 列表
  if (u.pathname === '/voice' && req.method === 'GET') {
    try {
      return json(res, 200, { ok: true, ...(await voiceState()) });
    } catch (e) {
      return json(res, 500, { ok: false, error: String((e && e.message) || e) });
    }
  }

  // 音色：切换（只改服务器上的偏好，之后所有合成都用它）
  if (u.pathname === '/voice' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const id = String(body.voice || '').trim();
      const hit = VOICE_LIST.find((v) => v.id === id);
      if (!hit) return json(res, 400, { ok: false, error: 'unknown voice' });
      const st = await voiceState();
      const opt = st.voices.find((v) => v.id === id);
      if (!opt || !opt.installed) return json(res, 400, { ok: false, error: 'voice not installed' });
      const prefs = readPrefs();
      prefs.voice = id;
      writePrefs(prefs);
      console.log(new Date().toISOString(), 'voice ->', id);
      return json(res, 200, { ok: true, ...(await voiceState()) });
    } catch (e) {
      return json(res, 500, { ok: false, error: String((e && e.message) || e) });
    }
  }

  // 语音合成：文本 → 胡桃音色语音（edge-tts → RVC 换音色 → mp3）
  // 同一句文本只合成一次，内容寻址缓存；GPU 一次只跑一个，用串行队列排队
  if (u.pathname === '/tts' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const text = String(body.text || '').trim();
      if (!text) return json(res, 400, { ok: false, error: 'empty' });
      const voice = VOICE_LIST.some((v) => v.id === body.voice) ? String(body.voice) : voicePref();
      const hash = crypto.createHash('sha256').update(`${TTS_VERSION}\n${voice}\n${text}`).digest('hex').slice(0, 16);
      const name = `voice-${hash}.mp3`;
      const full = path.join(UP_DIR, name);
      if (fs.existsSync(full)) return json(res, 200, { ok: true, path: `/files/${name}`, cached: true });
      await (ttsQueue = ttsQueue.then(async () => {
        if (fs.existsSync(full)) return;
        // 优先走常驻合成服务（模型已加载，一句 2 秒左右）；没起来就退回一次性进程
        try {
          const r = await fetch(`${TTS_DAEMON}/tts`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ text, out: full, voice }),
            signal: AbortSignal.timeout(200000),
          });
          const j = await r.json();
          if (!j.ok) throw new Error(String(j.error || 'tts daemon failed'));
          return;
        } catch (e) {
          console.log(new Date().toISOString(), 'tts daemon 没响应，退回一次性进程:', String((e && e.message) || e).slice(0, 160));
        }
        await new Promise((resolve, reject) => {
          execFile(VOICE_PY, [VOICE_SCRIPT, '--text', text, '--out', full, '--voice', voice], { timeout: 300000, windowsHide: true }, (err, _stdout, stderr) => {
            if (err) reject(new Error(String(stderr || err.message).slice(-400)));
            else resolve();
          });
        });
      }));
      if (!fs.existsSync(full)) return json(res, 500, { ok: false, error: '合成失败' });
      const durationMs = await audioDurationMs(full);
      return json(res, 200, { ok: true, path: `/files/${name}`, durationMs, voice });
    } catch (e) {
      return json(res, 500, { ok: false, error: String((e && e.message) || e) });
    }
  }

  // 语音转文字：给一段已上传的语音文件，返回她"听到"的字
  if (u.pathname === '/asr' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const p = String(body.path || '').replace(/^\/files\//, '');
      const full = path.join(UP_DIR, path.basename(p));
      if (!p || !fs.existsSync(full)) return json(res, 400, { ok: false, error: '文件不存在' });
      const t0 = Date.now();
      const text = await asrFile(full);
      return json(res, 200, { ok: true, text, ms: Date.now() - t0 });
    } catch (e) {
      return json(res, 500, { ok: false, error: String((e && e.message) || e) });
    }
  }

  // 手机上报华为推送 token（拿不到 token 的机器就别调）
  if (u.pathname === '/push/register' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const token = String(body.token || '').trim();
      if (token.length < 20) return json(res, 400, { ok: false, error: 'bad token' });
      const list = loadPushTokens().filter((t) => t !== token);
      list.push(token);
      savePushTokens(list);
      return json(res, 200, { ok: true, count: list.length, configured: pushConfigured() });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (u.pathname === '/push/unregister' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const token = String(body.token || '').trim();
      savePushTokens(loadPushTokens().filter((t) => t !== token));
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (u.pathname === '/push/send' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const r = await sendPush(body.title || '大肥鱼', body.body || '测试推送', body.threadId || '');
      return json(res, 200, r);
    } catch (e) {
      return json(res, 500, { ok: false, error: String((e && e.message) || e) });
    }
  }

  if (u.pathname === '/push/status' && req.method === 'GET') {
    return json(res, 200, { ok: true, configured: pushConfigured(), tokens: loadPushTokens().length });
  }

  // 她说话：把回复推给手机
  if (u.pathname === '/say' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const text = String(body.text || '').trim();
      const image = typeof body.image === 'string' ? body.image : '';
      const sticker = isSticker(body.sticker) ? body.sticker : '';
      const audio = typeof body.audio === 'string' && body.audio.startsWith('/files/') ? body.audio : '';
      const audioMs = Number(body.audioMs) > 0 ? Math.round(Number(body.audioMs)) : 0;
      if (!text && !image && !sticker && !audio) return json(res, 400, { ok: false, error: 'empty' });
      const threadId = threadById(String(body.threadId || '')) ? body.threadId : threads[0].id;
      const m = {
        id: newId(),
        threadId,
        role: 'her',
        text,
        ...(image ? { image } : {}),
        ...(sticker ? { sticker } : {}),
        ...(audio ? { audio } : {}),
        ...(audio && audioMs ? { audioMs } : {}),
        ts: Date.now(),
      };
      // 去重：3 秒内同一句话重复推过来（她一条消息调了两次工具），只算一次
      const dup = messages.find(
        (x) => x.role === 'her' && x.threadId === threadId && x.text === text &&
          (x.audio || '') === audio && (x.image || '') === image && m.ts - x.ts < 3000,
      );
      if (dup) return json(res, 200, { ok: true, id: dup.id, deduped: true });
      append(m);
      broadcast(m);
      // 手机端不在前台（切后台/被杀/没连）时补一条系统通知；前台就不打扰
      if (!phoneForeground() && (text || image || sticker || audio)) {
        const t = threadById(threadId);
        const stickerName = sticker ? path.basename(sticker).replace(/\.[a-z0-9]+$/i, '') : '';
        const preview = text
          ? pushPreview(text)
          : image ? '[图片]'
          : sticker ? `[表情：${stickerName}]`
          : '[语音]';
        // 整条只有一张表情/图片时，带上右侧大图（需要公网可直连的 HTTPS 地址）
        const imgBase = pushImageBase();
        let imageUrl = '';
        if (imgBase) {
          if (sticker) imageUrl = `${imgBase}/stickers/${encodeURIComponent(path.basename(sticker))}`;
          else if (image && image.startsWith('/files/')) imageUrl = `${imgBase}${image}`;
        }
        void sendPush(`大肥鱼 · ${t ? t.name : '聊天'}`, preview, threadId, imageUrl);
      }
      return json(res, 200, { ok: true, id: m.id });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // 手机发来但还没被处理的（可按聊天区过滤）
  if (u.pathname === '/pending' && req.method === 'GET') {
    const tid = u.searchParams.get('thread');
    const list = messages.filter((m) => m.role === 'me' && !m.acked && !m.recalled && (!tid || m.threadId === tid));
    return json(res, 200, { ok: true, list });
  }

  if (u.pathname === '/ack' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const ids = new Set(Array.isArray(body.ids) ? body.ids : []);
      for (const m of messages) if (ids.has(m.id)) m.acked = true;
      rewrite();
      return json(res, 200, { ok: true, acked: ids.size });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  if (u.pathname === '/history' && req.method === 'GET') {
    const limit = Math.min(200, Number(u.searchParams.get('limit') || 50));
    const tid = u.searchParams.get('thread');
    const before = Number(u.searchParams.get('before') || 0);
    let scoped = tid ? messages.filter((m) => m.threadId === tid) : messages;
    // before：往更早翻页，只要比这个时间戳更早的，再取最后 limit 条
    if (before > 0) scoped = scoped.filter((m) => Number(m.ts || 0) < before);
    const list = scoped.slice(-limit);
    return json(res, 200, { ok: true, list, hasMore: scoped.length > list.length });
  }

  // 撤回事件：桥插件轮询，好让她这边也知道「对方撤了一条」
  if (u.pathname === '/recalls' && req.method === 'GET') {
    const since = Number(u.searchParams.get('since') || 0);
    const list = recallEvents.filter((r) => r.ts > since);
    return json(res, 200, { ok: true, list, now: Date.now() });
  }

  // 撤回：两小时内可撤，只打标记，不删记录（另一端会收到 recall 广播）
  if (u.pathname === '/recall' && req.method === 'POST') {
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const id = String(body.id || '');
      const m = messages.find((x) => x.id === id);
      if (!m) return json(res, 404, { ok: false, error: 'not found' });
      if (m.recalled) return json(res, 200, { ok: true, already: true });
      if (Date.now() - Number(m.ts || 0) > 2 * 60 * 60 * 1000) {
        return json(res, 400, { ok: false, error: 'expired' });
      }
      m.recalled = true;
      m.recalledAt = Date.now();
      rewrite();
      recallEvents.push({ id: m.id, threadId: m.threadId, ts: m.recalledAt, role: m.role });
      if (recallEvents.length > 200) recallEvents.splice(0, recallEvents.length - 200);
      broadcast({ type: 'recall', id: m.id, threadId: m.threadId });
      return json(res, 200, { ok: true });
    } catch (e) {
      return json(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  json(res, 404, { ok: false, error: 'not found' });
});

const wss = new WebSocketServer({ server, path: '/ws' });

// 已经处理过的客户端消息号（防重连补发时同一条入库两次）
const seenCids = new Map();
// 25 秒打一次 ping：半死的隧道连接能被及时掐掉，客户端才知道要重连
setInterval(() => {
  for (const ws of clients) {
    try { ws.ping(); } catch {}
  }
}, 25000);

/** 有没有「手机端且在前台」的连接（电脑侧的桥接连接不算） */
function phoneForeground() {
  for (const ws of clients) {
    if (ws.isPhone && ws.fg) return true;
  }
  return false;
}

/**
 * 推送预览：通知正文只支持纯文本，所以把 [e:文件名] 尽量换成人能看懂的样子。
 * 先按关键词映射成 emoji，映射不到就退化成 [名字]。
 */
const EMOJI_BY_KEYWORD = [
  ['大笑', '😄'], ['开心', '😄'], ['笑', '😄'], ['偷笑', '🤭'], ['捂脸', '🤦'],
  ['爱心', '❤️'], ['喜欢', '❤️'], ['妙', '👍'], ['赞', '👍'], ['鼓掌', '👏'],
  ['疑惑', '🤔'], ['问号', '❓'], ['生气', '😤'], ['怒', '😠'], ['哭', '😭'],
  ['委屈', '🥺'], ['可怜', '🥺'], ['困', '😪'], ['睡', '😴'], ['汗', '😅'],
  ['无语', '😑'], ['惊', '😱'], ['吓', '😱'], ['震惊', '😱'], ['狗', '🐶'],
  ['猫', '🐱'], ['鲸', '🐳'], ['兔', '🐰'], ['花', '🌸'], ['星星', '🤩'],
  ['抱', '🤗'], ['耶', '✌️'], ['比心', '🫶'], ['饭', '🍚'], ['吃', '🍚'],
  ['咖啡', '☕'], ['茶', '🍵'], ['心', '💗'], ['太阳', '☀️'], ['月亮', '🌙'],
];

function pushPreview(text) {
  if (!text) return '';
  const out = String(text).replace(/\[e:([^\]]+)\]/g, (all, file) => {
    const base = String(file).replace(/\.[a-z0-9]+$/i, '');
    for (const pair of EMOJI_BY_KEYWORD) {
      if (base.indexOf(pair[0]) >= 0) return pair[1];
    }
    return '[' + base + ']';
  });
  return out.slice(0, 60);
}

wss.on('connection', (ws, req) => {
  const u = new URL(req.url, 'http://x');
  if (u.searchParams.get('token') !== TOKEN) {
    ws.close(4001, 'unauthorized');
    return;
  }
  clients.add(ws);
  ws.isPhone = false;
  ws.fg = true;
  console.log(new Date().toISOString(), 'ws connect, clients =', clients.size);

  ws.on('message', async (raw) => {
    let obj;
    try {
      obj = JSON.parse(String(raw));
    } catch {
      return;
    }
    if (obj.type === 'hello') {
      ws.send(JSON.stringify({ type: 'hello', ok: true, serverTime: Date.now(), threads }));
      return;
    }
    if (obj.type === 'state') {
      ws.isPhone = true;
      ws.fg = obj.fg !== false;
      console.log(new Date().toISOString(), 'ws state fg=', ws.fg, 'clients =', clients.size);
      return;
    }
    if (obj.type === 'user') {
      ws.isPhone = true;
      ws.fg = true;
      const cid = typeof obj.cid === 'string' ? obj.cid.slice(0, 64) : '';
      console.log(new Date().toISOString(), 'user msg cid=', cid || '(none)', 'seen=', cid ? seenCids.has(cid) : false);
      if (cid && seenCids.has(cid)) {
        // 重连补发的同一条：只回执，不再入库/广播
        try { ws.send(JSON.stringify({ type: 'ack', id: seenCids.get(cid), threadId: String(obj.threadId || '') })); } catch {}
        return;
      }
      const text = String(obj.text || '').trim();
      const image = typeof obj.image === 'string' ? obj.image : '';
      const sticker = isSticker(obj.sticker) ? obj.sticker : '';
      const audio = typeof obj.audio === 'string' && obj.audio.startsWith('/files/') ? obj.audio : '';
      const audioMs = Number(obj.audioMs) > 0 ? Math.round(Number(obj.audioMs)) : 0;
      if (!text && !image && !sticker && !audio) return;
      const threadId = threadById(String(obj.threadId || '')) ? obj.threadId : threads[0].id;
      let quote;
      if (obj.quote && typeof obj.quote === 'object') {
        const qt = String(obj.quote.text || '').slice(0, 200);
        const qi = typeof obj.quote.image === 'string' ? obj.quote.image : '';
        if (qt || qi) quote = { text: qt, ...(qi ? { image: qi } : {}) };
      }
      const m = {
        id: newId(),
        threadId,
        role: 'me',
        text,
        ...(image ? { image } : {}),
        ...(sticker ? { sticker } : {}),
        ...(audio ? { audio } : {}),
        ...(audio && audioMs ? { audioMs } : {}),
        ...(quote ? { quote } : {}),
        ts: Date.now(),
      };
      // 语音消息：先把话转成文字，再入库/广播（她那边要能"读到"这句话；
      // 同步做也能保证 /pending 里不会出现一条没文字的语音）
      if (audio && !text) {
        const full = path.join(UP_DIR, path.basename(audio));
        try {
          const t = await asrFile(full);
          if (t) m.text = t;
        } catch (e) {
          console.log(new Date().toISOString(), 'asr failed:', String((e && e.message) || e).slice(0, 160));
        }
        m.asrDone = true;
      }
      append(m);
      broadcast(m);
      if (cid) {
        seenCids.set(cid, m.id);
        if (seenCids.size > 4000) {
          const first = seenCids.keys().next().value;
          seenCids.delete(first);
        }
      }
      // 回执给发送方，方便手机把本地临时消息替换成正式 id
      try {
        ws.send(JSON.stringify({ type: 'ack', id: m.id, threadId }));
      } catch {}
    }
  });

  ws.on('close', (code, reason) => {
    clients.delete(ws);
    console.log(new Date().toISOString(), 'ws close', code, String(reason || ''), 'clients =', clients.size);
  });
  ws.on('error', (e) => {
    clients.delete(ws);
    console.log(new Date().toISOString(), 'ws error', String((e && e.message) || e).slice(0, 120), 'clients =', clients.size);
  });
});

loadThreads();
loadHistory();
seedStickers();
server.listen(PORT, () => {
  console.log(
    `dafeiyu-im server on :${PORT} (ws /ws, ${threads.length} threads, ${stickerList.length} stickers, token ${TOKEN})`,
  );
});
