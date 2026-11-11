// A local stand-in for a portal on an L4 Server (relay protocol v1), to test portal mode without one.
//
//   node tools/portal-relay.mjs --host-key hk --guest-key gk [--port 8787] [--id test] [--page web/guest.html]
//
//   GET  /portal/<id>          the guest page (web/guest.html, read from disk on every request)
//   WS   /portal/<id>/ws       the guest: first frame {"t":"auth","token":<guest key>} or close 4401;
//                              no host yet → {"t":"pp.wait"}, and the auth frame waits for the host
//   WS   /portal/<id>/host     the host's Mac: {"t":"host","key":<host key>,"v":1} → {"t":"pp.ready"} or close 4401;
//                              a newer host closes the older one with 4409; "ping" is answered "pong"
//   POST /portal/<id>/end      ends the portal: the host is closed with 4404 and may not come back
//
// Node's own WebSocket is a client only, so the server side of the protocol (RFC 6455) is written out here.

import { createServer } from 'node:http'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const args = process.argv.slice(2)
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback }
const port = +opt('--port', 8787)
const id = opt('--id', 'test')
const hostKey = opt('--host-key', '')
const guestKey = opt('--guest-key', '')
const page = opt('--page', join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'guest.html'))
if (!hostKey || !guestKey) { console.error('usage: node tools/portal-relay.mjs --host-key K --guest-key T [--port 8787] [--id test]'); process.exit(2) }

const base = `/portal/${id}`
const log = (...a) => console.error(new Date().toISOString().slice(11, 23), ...a)

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

// ---- the portal: one host, one guest ----
let host = null     // Conn, once it sent a good hello
let guest = null    // Conn, once it authenticated
let guestAuth = null  // the guest's auth frame, kept for a host that comes later
let ended = false

function guestToHost() {
  if (!host || !guest) return
  host.sendJSON({ t: 'pp.guest', open: true })
  host.send(guestAuth, true)
}

function onHost(c) {
  let hello = false
  const timer = setTimeout(() => { if (!hello) c.close(4400) }, 10000)
  c.onmessage = (data, text) => {
    if (!hello) {
      let m = null
      try { m = JSON.parse(data) } catch {}
      if (!text || !m || m.t !== 'host' || m.key !== hostKey || m.v !== 1) { log('host: bad hello'); return c.close(4401) }
      if (ended) return c.close(4404)
      hello = true
      clearTimeout(timer)
      if (host) { log('host: replaced by a newer one'); host.close(4409) }
      host = c
      c.sendJSON({ t: 'pp.ready' })
      log('host: ready')
      guestToHost()
      return
    }
    if (text && data === 'ping') return c.send('pong', true)
    // The host's own words for the portal: pp.close closes the guest's socket here (after the bye that went first).
    if (text && /"t"\s*:\s*"pp\./.test(data)) {
      let m = null
      try { m = JSON.parse(data) } catch {}
      if (m?.t === 'pp.close' && guest) { const g = guest; guest = null; guestAuth = null; g.close(4403); host.sendJSON({ t: 'pp.guest', open: false }) }
      return
    }
    if (c === host && guest) guest.send(data, text)  // everything else goes to the guest, verbatim; dropped without one
  }
  c.onclose = code => {
    clearTimeout(timer)
    if (host !== c) return
    host = null
    log('host: gone', code)
    if (guest) guest.sendJSON({ t: 'pp.wait' })
  }
}

function onGuest(c) {
  let authed = false
  c.onmessage = (data, text) => {
    if (!authed) {
      let m = null
      try { m = JSON.parse(data) } catch {}
      if (!text || !m || m.t !== 'auth' || m.token !== guestKey) { log('guest: bad auth'); return c.close(4401) }
      authed = true
      if (guest) {  // one guest at a time: the newer one wins
        guest.sendJSON({ type: 'bye', final: true, reason: 'This link was opened somewhere else.' })
        const old = guest
        guest = null
        old.close(4000)
        if (host) host.sendJSON({ t: 'pp.guest', open: false })
      }
      guest = c
      guestAuth = data
      log('guest: in', host ? '' : '(no host yet: waiting)')
      if (host) guestToHost(); else c.sendJSON({ t: 'pp.wait' })
      return
    }
    if (c !== guest || !host) return
    // The portal's own words start with "pp.": a guest may not speak them.
    if (text && /"t"\s*:\s*"pp\./.test(data)) return
    host.send(data, text)
  }
  c.onclose = () => {
    if (guest !== c) return
    guest = null
    guestAuth = null
    log('guest: gone')
    if (host) host.sendJSON({ t: 'pp.guest', open: false })
  }
}

const server = createServer((req, res) => {
  const path = req.url.split('?')[0]
  if (req.method === 'GET' && (path === base || path === base + '/')) {
    try {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
      return res.end(readFileSync(page))
    } catch (e) { res.writeHead(500); return res.end(String(e)) }
  }
  if (req.method === 'POST' && path === base + '/end') {
    ended = true
    if (host) host.close(4404)
    res.writeHead(200); return res.end('ended\n')
  }
  res.writeHead(404); res.end('not found\n')
})

server.on('upgrade', (req, socket) => {
  const path = req.url.split('?')[0]
  const key = req.headers['sec-websocket-key']
  const kind = path === base + '/host' ? 'host' : path === base + '/ws' ? 'guest' : null
  if (!key || !kind) { socket.end('HTTP/1.1 404 Not Found\r\n\r\n'); return }
  const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`)
  const c = new Conn(socket, kind)
  kind === 'host' ? onHost(c) : onGuest(c)
})

server.listen(port, '127.0.0.1', () => log(`portal stand-in: http://127.0.0.1:${port}${base}  (host socket ${base}/host)`))
