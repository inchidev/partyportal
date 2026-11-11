// A local stand-in for a portal on an L4 Server or on llll.gg (relay protocol v1, and v2 with --v2), to test portal
// mode without one.
//
//   node tools/portal-relay.mjs [--host-key hk --guest-key gk [--id test]] [--port 8787] [--ice servers.json]
//                               [--limit-bytes N] [--ttl SECONDS] [--version N] [--v2] [--page web/guest.html]
//
//   GET  /portal/<id>, /p/<id>  the guest page (web/guest.html, read from disk on every request)
//   WS   …/<id>/ws              the guest: first frame {"t":"auth","token":<guest key>} or close 4401;
//                               no host yet → {"t":"pp.wait"}, and the auth frame waits for the host
//   WS   …/<id>/host            the host's Mac: {"t":"host","key":<host key>,"v":1} → {"t":"pp.ready"} or close 4401
//                               (4426 for another protocol version); a newer host closes the older one with 4409;
//                               "ping" is answered "pong"; {"t":"pp.close"} closes the guest with 4403
//   POST …/<id>/end             ends the portal: the host is closed with 4404 and may not come back
//   POST /api/portals           like llll.gg: a new portal with fresh keys, answered as
//                               {portalId, url, guestUrl, hostLink, expiresAt}; url is http://127.0.0.1:<port>/p/<id>
//
//   --ice FILE         a JSON array of ICE servers sent in every pp.ready ({"t":"pp.ready","iceServers":[…]})
//   --limit-bytes N    like llll.gg's cost guard: past N relayed bytes (or one frame over 1 MiB) both sides are
//                      closed with 4429 and the portal ends
//   --ttl SECONDS      lifetime of portals made by POST /api/portals (default 12 h)
//   --version N        the relay protocol version this stand-in speaks (default 1; anything else tests 4426)
//   --v2               also speak relay protocol v2 (several viewers), with a FAKE SFU: a host saying "v":2 gets
//                      {"t":"pp.ready","v":2,"sfu":true,"p2p":true}; that tells the Mac there is no SFU here, so its
//                      bridge publishes once per admitted viewer ("g" in pp.sfu.publish) and this stand-in passes the
//                      bridge's offer to that viewer as pp.sfu.offer and the viewer's answer back as pp.sfu.answer.
//                      The media then goes peer to peer between the bridge and each guest page. Up to 16 guests;
//                      frames are wrapped (pp.from / pp.to / pp.all) as on an L4 Server; pp.sfu.layer is refused
//                      (no layers without an SFU). What this does NOT exercise: the SFU's own calls, simulcast
//                      layers, and the bridge's single publication — those are covered by L4's unit tests only.
//
// Node's own WebSocket is a client only, so the server side of the protocol (RFC 6455) is written out here.

import { createServer } from 'node:http'
import { createHash, randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const args = process.argv.slice(2)
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback }
const port = +opt('--port', 8787)
const page = opt('--page', join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'guest.html'))
const iceFile = opt('--ice', '')
const iceServers = iceFile ? JSON.parse(readFileSync(iceFile, 'utf8')) : null
const limitBytes = +opt('--limit-bytes', 0)
const ttl = +opt('--ttl', 12 * 3600)
const version = +opt('--version', 1)  // a Server that speaks another version answers the Mac's v:1 with 4426
const v2 = args.includes('--v2')
const MAX_VIEWERS = 16
const log = (...a) => console.error(new Date().toISOString().slice(11, 23), ...a)
const newKey = () => randomBytes(32).toString('base64url')

// ---- a minimal WebSocket server connection ----
class Conn {
  constructor(socket, name) {
    this.socket = socket; this.name = name; this.buf = Buffer.alloc(0); this.frag = []; this.fragOp = 0; this.open = true
    this.onmessage = () => {}; this.onclose = () => {}
    socket.setNoDelay(true)
    socket.on('data', d => { this.buf = Buffer.concat([this.buf, d]); this.parse() })
    socket.on('end', () => { socket.destroy(); this.gone() })  // the HTTP server keeps upgraded sockets half-open
    socket.on('close', () => this.gone())
    socket.on('error', () => this.gone())
  }
  gone() { if (!this.open) return; this.open = false; this.onclose(this.code || 1006) }
  parse() {
    while (this.buf.length >= 2) {
      const b0 = this.buf[0], b1 = this.buf[1], fin = !!(b0 & 0x80), op = b0 & 0x0f, masked = !!(b1 & 0x80)
      let len = b1 & 0x7f, off = 2
      if (len === 126) { if (this.buf.length < 4) return; len = this.buf.readUInt16BE(2); off = 4 }
      else if (len === 127) { if (this.buf.length < 10) return; len = Number(this.buf.readBigUInt64BE(2)); off = 10 }
      if (!masked || len > 16 * 1024 * 1024) return this.close(1002)
      if (this.buf.length < off + 4 + len) return
      const mask = this.buf.subarray(off, off + 4), data = Buffer.from(this.buf.subarray(off + 4, off + 4 + len))
      for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3]
      this.buf = this.buf.subarray(off + 4 + len)
      if (op === 0x8) { this.code = data.length >= 2 ? data.readUInt16BE(0) : 1005; this.frame(0x8, data.subarray(0, 2)); this.socket.end(); return this.gone() }
      if (op === 0x9) { this.frame(0xa, data); continue }
      if (op === 0xa) continue
      if (op === 0x0) { this.frag.push(data); if (!fin) continue; this.deliver(this.fragOp, Buffer.concat(this.frag)); this.frag = []; continue }
      if (!fin) { this.fragOp = op; this.frag = [data]; continue }
      this.deliver(op, data)
    }
  }
  deliver(op, data) { this.onmessage(op === 0x1 ? data.toString('utf8') : data, op === 0x1) }
  frame(op, payload) {
    if (this.socket.destroyed) return
    const n = payload.length
    const head = n < 126 ? Buffer.from([0x80 | op, n]) : n < 65536 ? Buffer.from([0x80 | op, 126, n >> 8, n & 0xff]) : Buffer.alloc(10)
    if (n >= 65536) { head[0] = 0x80 | op; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2) }
    this.socket.write(Buffer.concat([head, payload]))
  }
  send(data, isText) { if (this.open) this.frame(isText ? 0x1 : 0x2, isText ? Buffer.from(data, 'utf8') : data) }
  sendJSON(obj) { this.send(JSON.stringify(obj), true) }
  close(code = 1000) {
    if (!this.open) return
    const p = Buffer.alloc(2); p.writeUInt16BE(code)
    this.frame(0x8, p)
    this.code = code
    setTimeout(() => this.socket.destroy(), 300)
    this.gone()
  }
}

// ---- a portal: one host, one guest ----
const portals = new Map()  // id → Portal

class Portal {
  constructor(id, hostKey, guestKey, expiresAt = null) {
    Object.assign(this, { id, hostKey, guestKey, expiresAt, host: null, guest: null, guestAuth: null, ended: false, relayed: 0 })
    // v2: the host connection's version, the version of the last host (for guests that come while none is here),
    // and every guest by name.
    Object.assign(this, { hostV: 1, lastV: 1, viewers: new Map(), seq: 0 })
    if (expiresAt) setTimeout(() => this.end(4404), Math.max(0, expiresAt - Date.now()))
  }
  log(...a) { log(`[${this.id}]`, ...a) }
  end(code) {
    this.ended = true
    if (this.guest) this.guest.close(code)
    for (const v of this.viewers.values()) v.c.close(code)
    if (this.host) this.host.close(code)
  }
  // llll.gg's cost guard, when --limit-bytes is given.
  count(n) {
    if (!limitBytes) return true
    this.relayed += n
    if (n <= 1024 * 1024 && this.relayed <= limitBytes) return true
    this.log('relay limit reached')
    this.end(4429)
    return false
  }
  guestToHost() {
    if (!this.host || !this.guest) return
    this.host.sendJSON({ t: 'pp.guest', open: true })
    this.host.send(this.guestAuth, true)
  }

  onHost(c) {
    let hello = false
    const timer = setTimeout(() => { if (!hello) c.close(4400) }, 10000)
    c.onmessage = (data, text) => {
      if (!hello) {
        let m = null
        try { m = JSON.parse(data) } catch {}
        if (!text || !m || m.t !== 'host') { this.log('host: bad hello'); return c.close(4400) }
        const speaksV2 = v2 && m.v === 2
        if (m.v !== version && !speaksV2) return c.close(4426)
        if (m.key !== this.hostKey) { this.log('host: bad key'); return c.close(4401) }
        if (this.ended) return c.close(4404)
        hello = true
        clearTimeout(timer)
        if (this.host) { this.log('host: replaced by a newer one'); this.host.close(4409) }
        this.host = c
        this.hostV = this.lastV = speaksV2 ? 2 : 1
        const ready = speaksV2 ? { t: 'pp.ready', v: 2, sfu: true, p2p: true } : { t: 'pp.ready' }
        c.sendJSON(iceServers ? { ...ready, iceServers } : ready)
        this.log('host: ready', speaksV2 ? '(v2, fake SFU: peer to peer per viewer)' : '', iceServers ? `(${iceServers.length} ICE servers)` : '')
        if (speaksV2) {
          for (const [g, v] of this.viewers) { v.admitted = false; this.introduce(g, v) }
          return
        }
        // v1 keeps one guest: the newest of those a v2 host left waiting.
        const waiting = [...this.viewers.values()]
        this.viewers.clear()
        const newest = waiting.pop()
        for (const v of waiting) { v.c.sendJSON({ type: 'bye', final: true, reason: 'This link was opened somewhere else.' }); v.c.close(4409) }
        if (newest && !this.guest) { this.guest = newest.c; this.guestAuth = newest.auth; this.adoptV1(newest.c) }
        this.guestToHost()
        return
      }
      if (this.hostV === 2 && c === this.host) return this.fromHostV2(c, data, text)
      if (text && data === 'ping') return c.send('pong', true)
      // The host's own words for the portal: pp.close closes the guest's socket here (after the bye that went first).
      if (text && /"t"\s*:\s*"pp\./.test(data)) {
        let m = null
        try { m = JSON.parse(data) } catch {}
        if (m?.t === 'pp.close' && this.guest) { const g = this.guest; this.guest = null; this.guestAuth = null; g.close(4403); c.sendJSON({ t: 'pp.guest', open: false }) }
        return
      }
      if (c === this.host && this.guest && this.count(data.length)) this.guest.send(data, text)  // verbatim; dropped without a guest
    }
    c.onclose = code => {
      clearTimeout(timer)
      if (this.host !== c) return
      this.host = null
      this.log('host: gone', code)
      if (this.guest) this.guest.sendJSON({ t: 'pp.wait' })
      for (const v of this.viewers.values()) { v.admitted = false; v.c.sendJSON({ t: 'pp.wait' }) }
    }
  }

  // ---- v2 ----
  introduce(g, v) {
    this.host.sendJSON({ t: 'pp.guest', open: true, g })
    this.host.sendJSON({ t: 'pp.from', g, f: JSON.parse(v.auth) })
  }
  fromHostV2(c, data, text) {
    if (!text) return  // no picture through a v2 portal
    let m = null
    try { m = JSON.parse(data) } catch {}
    if (!m || typeof m !== 'object') return
    const v = typeof m.g === 'string' ? this.viewers.get(m.g) : null
    const f = m.f && typeof m.f === 'object' ? JSON.stringify(m.f) : null
    if (m.t === 'pp.to') { if (v && f && this.count(f.length)) v.c.send(f, true) }
    else if (m.t === 'pp.all') { if (f) for (const each of this.viewers.values()) if (this.count(f.length)) each.c.send(f, true) }
    else if (m.t === 'pp.close') { if (v) { this.viewers.delete(m.g); v.c.close(4403); c.sendJSON({ t: 'pp.guest', open: false, g: m.g }) } }
    else if (m.t === 'pp.admit') { if (v) { v.admitted = true; this.log(`viewer ${m.g}: admitted by the host`) } }
    else if (m.t === 'pp.sfu.publish') {
      // The fake SFU: the bridge's offer for one viewer goes to that viewer as the SFU's offer would.
      if (!m.g) return c.sendJSON({ t: 'pp.sfu.error', why: 'p2p_publishes_per_viewer' })
      if (!v || !v.admitted || typeof m.sdp !== 'string') return c.sendJSON({ t: 'pp.sfu.error', g: m.g, why: 'no_such_viewer' })
      v.c.sendJSON({ t: 'pp.sfu.offer', sdp: m.sdp, fresh: true, tracks: m.tracks || [], ...(iceServers ? { iceServers } : {}) })
      this.log(`viewer ${m.g}: offer passed on (${(m.tracks || []).map(t => t.trackName).join(', ')})`)
    }
  }
  onGuestV2(c, data) {
    if (this.viewers.size >= MAX_VIEWERS) {
      c.sendJSON({ type: 'bye', final: true, reason: `This Portal already has ${MAX_VIEWERS} viewers. Try again when someone leaves.` })
      return c.close(4503)
    }
    const g = `v${++this.seq}-${randomBytes(3).toString('hex')}`
    const v = { c, auth: data, admitted: false }
    this.viewers.set(g, v)
    this.log(`viewer ${g}: in (${this.viewers.size})`, this.host ? '' : '(no host yet: waiting)')
    if (this.host) this.introduce(g, v); else c.sendJSON({ t: 'pp.wait' })
    c.onmessage = (data, text) => {
      if (this.viewers.get(g) !== v || !this.host || this.hostV !== 2 || !text) return
      let m = null
      try { m = JSON.parse(data) } catch {}
      if (!m || typeof m !== 'object') return
      if (typeof m.t === 'string' && m.t.startsWith('pp.')) {
        if (m.t === 'pp.sfu.answer' && typeof m.sdp === 'string') this.host.sendJSON({ t: 'pp.sfu.answer', g, sdp: m.sdp })
        else if (m.t === 'pp.sfu.layer') c.sendJSON({ t: 'pp.sfu.layer', rid: m.rid, ok: false })
        return
      }
      if (this.count(data.length)) this.host.sendJSON({ t: 'pp.from', g, f: m })
    }
    c.onclose = () => {
      if (this.viewers.get(g) !== v) return
      this.viewers.delete(g)
      this.log(`viewer ${g}: gone`)
      if (this.host && this.hostV === 2) this.host.sendJSON({ t: 'pp.guest', open: false, g })
    }
  }
  // A guest that came under a v2 host and is kept by a v1 one: its frames go verbatim from now on.
  adoptV1(c) {
    c.onmessage = (data, text) => {
      if (c !== this.guest || !this.host) return
      if (text && /"t"\s*:\s*"pp\./.test(data)) return
      if (this.count(data.length)) this.host.send(data, text)
    }
    c.onclose = () => {
      if (this.guest !== c) return
      this.guest = null
      this.guestAuth = null
      if (this.host) this.host.sendJSON({ t: 'pp.guest', open: false })
    }
  }

  onGuest(c) {
    let authed = false
    c.onmessage = (data, text) => {
      if (!authed) {
        let m = null
        try { m = JSON.parse(data) } catch {}
        if (!text || !m || m.t !== 'auth' || m.token !== this.guestKey) { this.log('guest: bad auth'); return c.close(4401) }
        if (this.ended) return c.close(4404)
        authed = true
        if ((this.host ? this.hostV : this.lastV) === 2) return this.onGuestV2(c, data)
        if (this.guest) {  // one guest at a time: the newer one wins
          this.guest.sendJSON({ type: 'bye', final: true, reason: 'This link was opened somewhere else.' })
          const old = this.guest
          this.guest = null
          old.close(4409)
          if (this.host) this.host.sendJSON({ t: 'pp.guest', open: false })
        }
        this.guest = c
        this.guestAuth = data
        this.log('guest: in', this.host ? '' : '(no host yet: waiting)')
        if (this.host) this.guestToHost(); else c.sendJSON({ t: 'pp.wait' })
        return
      }
      if (c !== this.guest || !this.host) return
      // The portal's own words start with "pp.": a guest may not speak them.
      if (text && /"t"\s*:\s*"pp\./.test(data)) return
      if (this.count(data.length)) this.host.send(data, text)
    }
    c.onclose = () => {
      if (this.guest !== c) return
      this.guest = null
      this.guestAuth = null
      this.log('guest: gone')
      if (this.host) this.host.sendJSON({ t: 'pp.guest', open: false })
    }
  }
}

if (args.includes('--host-key') || args.includes('--guest-key')) {
  const id = opt('--id', 'test'), hostKey = opt('--host-key', ''), guestKey = opt('--guest-key', '')
  if (!hostKey || !guestKey) { console.error('usage: node tools/portal-relay.mjs [--host-key K --guest-key T [--id test]] [--port 8787] [--ice FILE]'); process.exit(2) }
  portals.set(id, new Portal(id, hostKey, guestKey))
}

// /portal/<id>… or /p/<id>… → [portal, rest]
function route(path) {
  const m = path.match(/^\/(?:portal|p)\/([A-Za-z0-9_-]{1,64})(\/.*)?$/)
  const p = m && portals.get(m[1])
  return p ? [p, (m[2] || '').replace(/\/$/, '')] : [null, null]
}

const server = createServer((req, res) => {
  const path = req.url.split('?')[0]
  if (req.method === 'POST' && path === '/api/portals') {
    const id = randomBytes(9).toString('base64url'), hostKey = newKey(), guestKey = newKey(), expiresAt = Date.now() + ttl * 1000
    portals.set(id, new Portal(id, hostKey, guestKey, expiresAt))
    const url = `http://127.0.0.1:${port}/p/${id}`
    log(`[${id}] made by POST /api/portals`)
    res.writeHead(201, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    return res.end(JSON.stringify({ portalId: id, url, guestUrl: `${url}#t=${guestKey}`,
      hostLink: `partyportal://portal?url=${encodeURIComponent(url)}&key=${hostKey}&t=${guestKey}`, expiresAt: new Date(expiresAt).toISOString() }))
  }
  const [p, rest] = route(path)
  if (p && req.method === 'GET' && rest === '' && !p.ended) {
    try {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
      return res.end(readFileSync(page))
    } catch (e) { res.writeHead(500); return res.end(String(e)) }
  }
  if (p && req.method === 'POST' && rest === '/end') {
    p.end(4404)
    res.writeHead(200); return res.end('ended\n')
  }
  res.writeHead(404); res.end('not found\n')
})

server.on('upgrade', (req, socket) => {
  const [p, rest] = route(req.url.split('?')[0])
  const key = req.headers['sec-websocket-key']
  const kind = rest === '/host' ? 'host' : rest === '/ws' ? 'guest' : null
  if (!key || !p || !kind) { socket.end('HTTP/1.1 404 Not Found\r\n\r\n'); return }
  const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`)
  const c = new Conn(socket, kind)
  kind === 'host' ? p.onHost(c) : p.onGuest(c)
})

server.listen(port, '127.0.0.1', () => log(`portal stand-in on http://127.0.0.1:${port}: ${[...portals.keys()].map(id => `/portal/${id}`).join(', ') || 'no fixed portal'}; POST /api/portals makes more`))
