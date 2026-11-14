import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import os from 'node:os'
import { spawn } from 'node:child_process'
import { defineTool } from '@deepseek-ai/dsh-tools'

const DEFAULTS = {
  serverUrl: 'http://127.0.0.1:8787',
  token: '',
  workspace: '',
  pollMs: 3000,
  historyLines: 12,
}

function authHeaders(token) {
  return token ? { authorization: `Bearer ${token}` } : {}
}

async function postJson(url, token, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...authHeaders(token) },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return res.json().catch(() => ({}))
}

async function setTyping(url, token, threadId, on) {
  try {
    await fetch(`${url}/typing`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ threadId, on }),
    });
  } catch (e) {
    // 打字状态是可选装饰，失败就算了
  }
}

async function getJson(url, token) {
  const res = await fetch(url, { headers: authHeaders(token) })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return res.json()
}

/**
 * 本地工程根：服务端 / 隧道脚本都在这儿。
 * 开源副本里不写死路径，默认指向 bridge 的上一级（即仓库根）。
 */
const IM_ROOT = process.env.DSH_IM_ROOT || path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
/** 访问 token：优先环境变量，其次 bridge/config.json（已被 .gitignore 忽略） */
function readBridgeConfig() {
  try {
    const p = path.join(path.dirname(new URL(import.meta.url).pathname), 'config.json')
    return JSON.parse(fs.readFileSync(p, 'utf8'))
  } catch {
    return {}
  }
}
const BRIDGE_FILE_CFG = readBridgeConfig()
const IM_TOKEN_FALLBACK = process.env.IM_TOKEN || BRIDGE_FILE_CFG.token || 'CHANGE_ME'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 只看端口有没有人听，不真正握手 */
function portOpen(port, timeout = 500) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port })
    const done = (v) => {
      sock.removeAllListeners()
      sock.destroy()
      resolve(v)
    }
    sock.setTimeout(timeout, () => done(false))
    sock.once('connect', () => done(true))
    sock.once('error', () => done(false))
  })
}

function spawnDetached(file, args, opts) {
  const p = spawn(file, args, { ...opts, detached: true, stdio: 'ignore', windowsHide: true })
  p.unref()
  return p
}

/**
 * 自愈：DSH 重启会把它拉起的子进程一起带走，服务端和隧道就断了。
 * 启动时和轮询失败时补拉一次，重启后不用再手动开服务。
 */
function makeEnsureBackend(cfg, log) {
  let busy = false
  let last = 0
  return async function ensureBackend(force = false) {
    const now = Date.now()
    if (busy || (!force && now - last < 15000)) return
    busy = true
    last = now
    try {
      if (!(await portOpen(Number(new URL(cfg.serverUrl).port || 80)))) {
        spawnDetached(process.execPath, ['index.mjs'], {
          cwd: path.join(IM_ROOT, 'server'),
          env: { ...process.env, IM_TOKEN: cfg.token || IM_TOKEN_FALLBACK, IM_PORT: '8787' },
        })
        log('self-heal: server 没在听，已拉起')
        await sleep(2500)
      }
      if (!(await portOpen(4040))) {
        const exe = path.join(IM_ROOT, 'tools', 'bin', 'ngrok.exe')
        if (fs.existsSync(exe)) {
          spawnDetached(exe, ['http', '8787'], { cwd: path.join(IM_ROOT, 'tools', 'bin') })
          log('self-heal: ngrok 没在跑，已拉起')
        }
      }
    } catch (e) {
      log('self-heal failed:', String(e?.message ?? e))
    } finally {
      busy = false
    }
  }
}

/** 工作区短标记：切工作区 = 换会话（cwd 定死，但聊天记录照旧显示） */
function wspTag(p) {
  let h = 0
  const s = String(p || '')
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return h.toString(16).slice(0, 4)
}

export default {
  name: 'dsh-im-bridge',
  inject: ['sessionController', 'tools'],
  apply(ctx, config = {}) {
    const cfg = { ...DEFAULTS, ...config }
    const dshHome = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
    const logFile = path.join(dshHome, 'im-bridge.log')

    function log(...args) {
      const line =
        new Date().toISOString() +
        ' ' +
        args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')
      console.log('[im-bridge]', line)
      try {
        fs.appendFileSync(logFile, line + '\n')
      } catch {}
    }

    /** @type {Map<string, {id:string,name:string,workspace:string}>} */
    let threadMap = new Map()
    const ensureBackend = makeEnsureBackend(cfg, log)
    setTimeout(() => {
      void ensureBackend(true)
    }, 800)

    const readySessions = new Map() // sessionId -> threadId
    const polling = new Set()
    const sentIds = new Set()
    /** 上次问到的撤回事件时间；只报这之后新发生的 */
    let lastRecallTs = Date.now()

    async function refreshThreads() {
      try {
        const r = await getJson(`${cfg.serverUrl}/threads`, cfg.token)
        const list = Array.isArray(r?.list) ? r.list : []
        const next = new Map()
        for (const t of list) if (t && t.id) next.set(String(t.id), t)
        threadMap = next
      } catch (e) {
        log('threads failed:', String(e?.message ?? e))
      }
    }

    const sessionIdOf = (thread) => `im-${thread.id}-${wspTag(thread.workspace)}`

    /** 从会话 id 反推聊天区（im_send 用） */
    function threadOfSession(sessionId) {
      const s = String(sessionId || '')
      if (!s.startsWith('im-')) return null
      const rest = s.slice(3)
      const cut = rest.lastIndexOf('-')
      const id = cut > 0 ? rest.slice(0, cut) : rest
      return threadMap.get(id) ?? { id, name: id, workspace: cfg.workspace }
    }

    async function ensureSession(thread) {
      const sessionId = sessionIdOf(thread)
      if (readySessions.has(sessionId)) return sessionId
      try {
        await ctx.sessionController.create({ sessionId, cwd: thread.workspace || cfg.workspace || undefined })
      } catch (e) {
        // 已存在时沿用
      }
      readySessions.set(sessionId, thread.id)
      log('session ready:', sessionId, 'cwd=', thread.workspace)
      return sessionId
    }

    async function recentLines(threadId) {
      try {
        const r = await getJson(`${cfg.serverUrl}/history?limit=${cfg.historyLines + 1}&thread=${encodeURIComponent(threadId)}`, cfg.token)
        const list = Array.isArray(r?.list) ? r.list : []
        // 去掉最后一条（就是即将投递的这条）
        return list
          .slice(0, -1)
          .map((m) =>
            m.role === 'me'
              ? `他：${m.text || (m.sticker ? `[表情 ${m.sticker}]` : '[图片]')}`
              : `你：${m.text || (m.sticker ? `[表情 ${m.sticker}]` : '[图片]')}`,
          )
          .join('\n')
      } catch {
        return ''
      }
    }

    async function deliver(m) {
      await refreshThreads()
      const thread = threadMap.get(String(m.threadId)) ?? {
        id: String(m.threadId || 'main'),
        name: '主聊天',
        workspace: cfg.workspace,
      }
      const sessionId = await ensureSession(thread)
      const ctxText = await recentLines(thread.id)
      const lines = [`你在手机 IM（聊天区「${thread.name}」）上收到主人发来的消息。`]
      if (ctxText) lines.push('', '（最近几句，供你接着聊）', ctxText)
      if (m.quote) {
        const q = m.quote
        const qtext = q.text ? q.text : '[图片]'
        lines.push(`（他引用了之前的一条消息：${qtext}）`)
        if (q.image) {
          lines.push(`引用里的那张图：${cfg.serverUrl}${q.image}`)
          lines.push('（引用的图地址给你了，需要看内容就用看图工具读它，别说看不到。）')
        }
      }
      if (m.sticker) {
        lines.push(`他发来一个表情包：${m.sticker}`)
        lines.push(
          '（想回一个就 im_send 传 sticker=文件名，清单以 GET /stickers 实时返回为准）',
        )
      }
      const inlineHits = (m.text || '').match(/\[e:([^\]]+)\]/g) || []
      if (inlineHits.length > 0) {
        const names = inlineHits.map((x) => x.slice(3, -1)).join('、')
        lines.push(`（他这条文字里夹了小表情：${names}）`)
        lines.push(
          '（你也可以这样：im_send 的 text 里直接写 [e:文件名]，会变成跟字一样高的小表情，跟在句子中间；清单见 index.md「小表情」那节，别编名字。）',
        )
      }
      if (m.image) {
        lines.push(`他发来一张图片：${cfg.serverUrl}${m.image}`)
        lines.push('（图片内容你看不到；可以让他说一句这是啥，或者照常接话。）')
      }
      if (m.audio) {
        lines.push(
          m.text
            ? `他发来一条语音，自动转成的文字是：「${m.text}」`
            : '他发来一条语音（没有转出文字，可能太短或太吵）。',
        )
        lines.push('（他是用嘴说的，你也用嘴回：im_send 照常写 text，再加 voice: true，就会合成语音发过去。）')
      } else if (m.text) {
        lines.push('', `主人：${m.text}`)
      }
      lines.push('', '用 im_send 工具回复（短一点，像聊天），不要用其他渠道的发送工具。')
      const ac = new AbortController()
      setTyping(cfg.serverUrl, cfg.token, thread.id, true)
      const typingTimer = setTimeout(() => setTyping(cfg.serverUrl, cfg.token, thread.id, false), 180000)
      try {
        await ctx.sessionController.prompt(
        {
          sessionId,
          mode: 'queue',
          requestId: 'im-' + m.id,
          content: [{ type: 'text', text: lines.join('\n') }],
        },
          ac.signal,
        )
      } finally {
        clearTimeout(typingTimer)
        setTyping(cfg.serverUrl, cfg.token, thread.id, false)
      }
    }

    /** 对方撤回了一条：单独投一条提醒，别让她把撤掉的话还当成对方说过的 */
    async function deliverRecall(r) {
      await refreshThreads()
      const thread = threadMap.get(String(r.threadId)) ?? {
        id: String(r.threadId || 'main'),
        name: '主聊天',
        workspace: cfg.workspace,
      }
      const sessionId = await ensureSession(thread)
      const who = r.role === 'me' ? '他' : '你'
      const text = [
        `手机 IM（聊天区「${thread.name}」）上，${who}撤回了一条消息。`,
        '',
        '（撤回就当没说过：别把被撤的那句当成他还说的话接着聊，也别去追问内容。要回别的就用 im_send。）',
      ].join('\n')
      await ctx.sessionController.prompt({
        sessionId,
        mode: 'queue',
        requestId: 'im-r-' + r.id,
        content: [{ type: 'text', text }],
      })
    }

    async function tick() {
      if (polling.has('all')) return
      polling.add('all')
      try {
        await refreshThreads()
        const r = await getJson(`${cfg.serverUrl}/pending`, cfg.token)
        const list = Array.isArray(r?.list) ? r.list : []
        const fresh = list.filter(
          (m) =>
            m &&
            (m.text || m.image || m.sticker || m.audio) &&
            !sentIds.has(m.id) &&
            // 语音还在等转写：先等等，别先送一条"没转出字"，等文字回来再一起给他
            !(m.audio && !m.text && !m.asrDone),
        )
        for (const m of fresh) {
          sentIds.add(m.id)
          try {
            await deliver(m)
            await postJson(`${cfg.serverUrl}/ack`, cfg.token, { ids: [m.id] })
            log('delivered:', (m.text || m.sticker || '[图片]').slice(0, 40))
          } catch (e) {
            sentIds.delete(m.id)
            log('deliver failed:', String(e?.message ?? e))
          }
        }
        try {
          const rr = await getJson(`${cfg.serverUrl}/recalls?since=${lastRecallTs}`, cfg.token)
          const evs = Array.isArray(rr?.list) ? rr.list : []
          if (typeof rr?.now === 'number') lastRecallTs = rr.now
          for (const r of evs) {
            try {
              await deliverRecall(r)
              log('recall delivered:', r.id, r.threadId)
            } catch (e) {
              log('recall deliver failed:', String(e?.message ?? e))
            }
          }
        } catch (e) {
          log('recalls poll failed:', String(e?.message ?? e))
        }
      } catch (e) {
        log('poll failed:', String(e?.message ?? e))
        void ensureBackend()
      } finally {
        polling.delete('all')
      }
    }

    let stickerCache = { at: 0, list: [] }
    async function stickerEntries(force) {
      const now = Date.now()
      if (!force && stickerCache.list.length && now - stickerCache.at < 60000) return stickerCache.list
      try {
        const r = await getJson(`${cfg.serverUrl}/stickers`, cfg.token)
        if (r && Array.isArray(r.list)) stickerCache = { at: now, list: r.list }
      } catch (e) {
        log('stickers load failed:', String((e && e.message) || e).slice(0, 120))
      }
      return stickerCache.list
    }

    function resolveSticker(list, raw) {
      const want = String(raw || '').trim().replace(/^.*[\\/]/, '')
      if (!want) return null
      const base = want.replace(/\.[^.]+$/, '')
      const hit =
        list.find((s) => s.file === want) ||
        list.find((s) => s.name === base) ||
        list.find((s) => s.name === want)
      if (hit) return hit
      const near = list
        .filter((s) => s.name.includes(base) || base.includes(s.name))
        .slice(0, 6)
        .map((s) => (s.cat === 'inline' ? `${s.file}(小表情)` : s.file))
      return { missing: true, near }
    }

    let disposeTool
    try {
      disposeTool = ctx.tools.register(
      defineTool({
        name: 'im_send',
        description:
          '向手机 IM 发送一条消息（大肥鱼手机客户端）。默认发回你当前所在的聊天区；每条消息单独调用一次。',
        parameters: {
          text: {
            type: 'string',
            description:
              '要发送的文字内容；只发表情包时可以留空。可以在文字里写 [e:文件名] 夹小表情，比如「今天好累[e:爱心.png]」。',
          },
          sticker: {
            type: 'string',
            description:
              '表情包文件名（整张发）。名字以服务端实时图库为准，随时增减；cat 为 inline 的会被自动转成句内小表情。想在句子里夹小表情，也可以直接在 text 里写 [e:文件名]。',
          },
          thread_id: {
            type: 'string',
            description: '目标聊天区 id；省略时发回当前会话所在的聊天区',
          },
          voice: {
            type: 'boolean',
            description:
              'true 时把 text 合成她的语音（胡桃音色）一起发过去，像发了一条语音消息。他发语音时才用。',
          },
        },
        isConcurrencySafe: () => true,
        output: {
          schema: { type: 'object', additionalProperties: true, properties: { ok: { type: 'boolean' }, threadId: { type: 'string' } } },
          render(args, result) {
            const who = result?.threadId ? result.threadId : '手机'
            return [{ type: 'text', text: `已发到 ${who}` }]
          },
        },
        execute: async (args, exec) => {
          const text = String(args?.text ?? '').trim()
          let sticker = String(args?.sticker ?? '').trim()
          const wantVoice = args?.voice === true
          if (!text && !sticker) throw new Error('text 和 sticker 至少给一个')
          let emote = ''
          if (sticker) {
            const list = await stickerEntries()
            const hit = resolveSticker(list, sticker)
            if (hit && hit.missing) {
              const hint = hit.near.length ? `；名字像的有：${hit.near.join('、')}` : ''
              throw new Error(`图库里没有「${sticker}」${hint}`)
            }
            if (hit) {
              if (hit.cat === 'inline') emote = hit.file
              else sticker = hit.file
            }
          }
          const bodyText = [text, emote ? `[e:${emote}]` : ''].filter(Boolean).join(' ')
          let threadId = String(args?.thread_id ?? '').trim()
          if (!threadId) {
            const t = threadOfSession(exec?.agent?.session?.id)
            if (t) threadId = t.id
          }
          if (!threadId) throw new Error('无法确定聊天区：请传 thread_id')
          let audio = ''
          let audioMs = 0
          if (wantVoice && text) {
            try {
              const t0 = await postJson(`${cfg.serverUrl}/tts`, cfg.token, { text })
              if (t0?.ok && t0.path) {
                audio = String(t0.path)
                audioMs = Number(t0.durationMs) || 0
              }
            } catch (e) {
              log('tts failed, 退回纯文字:', String((e && e.message) || e).slice(0, 120))
            }
          }
          await postJson(`${cfg.serverUrl}/say`, cfg.token, {
            text: bodyText,
            threadId,
            ...(sticker ? { sticker } : {}),
            ...(audio ? { audio, audioMs } : {}),
          })
          log('sent to phone:', threadId, (bodyText || (sticker ? `[表情 ${sticker}]` : '')).slice(0, 40), audio ? '(语音)' : '')
          return { ok: true, threadId, voice: !!audio }
        },
      }),
      )
    } catch (e) {
      log('tool register failed: ' + String((e && e.message) || e))
    }

    const timer = setInterval(tick, Math.max(1000, Number(cfg.pollMs) || 3000))
    setTimeout(tick, 1200)
    refreshThreads().then(() => log(`started, server=${cfg.serverUrl}, threads=${threadMap.size}`))

    ctx.on('dispose', () => {
      clearInterval(timer)
      disposeTool?.()
    })
  },
}
