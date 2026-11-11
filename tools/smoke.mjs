// Protocol smoke test without a browser: node tools/smoke.mjs [guest-port | wss://host] [token]
// Checks that a wrong token gets no video, and that the right one gets a config and a keyframe.
const where = process.argv[2] || '7374'
const base = /^wss?:/.test(where) ? where.replace(/\/$/, '') : `ws://127.0.0.1:${where}`
const token = process.argv[3] || ''

function attempt(tok, label) {
  return new Promise(resolve => {
    const ws = new WebSocket(`${base}/ws`)
    ws.binaryType = 'arraybuffer'
    const seen = { label, texts: [], binary: 0, key: false, config: null, closed: null }
    const done = () => { try { ws.close() } catch {} ; resolve(seen) }
    const timer = setTimeout(done, 2500)
    ws.onopen = () => ws.send(JSON.stringify({ t: 'auth', token: tok }))
    ws.onmessage = e => {
      if (typeof e.data === 'string') {
        const m = JSON.parse(e.data)
        seen.texts.push(m.type)
        if (m.type === 'video') seen.config = `${m.codec} ${m.width}x${m.height}`
      } else {
        seen.binary++
        const v = new DataView(e.data)
        if (v.getUint8(0) === 1 && (v.getUint8(1) & 1)) seen.key = true
      }
    }
    ws.onclose = e => { seen.closed = e.code; clearTimeout(timer); resolve(seen) }
  })
}

const bad = await attempt('wrong-' + token, 'wrong token')
const none = await new Promise(resolve => {
  const ws = new WebSocket(`${base}/ws`)
  let binary = 0
  ws.binaryType = 'arraybuffer'
  ws.onmessage = e => { if (typeof e.data !== 'string') binary++ }
  ws.onopen = () => ws.send(JSON.stringify({ t: 'm', x: 0.5, y: 0.5 }))
  ws.onclose = e => resolve({ label: 'no auth', binary, closed: e.code })
  setTimeout(() => { try { ws.close() } catch {} }, 7000)
})
const good = token ? await attempt(token, 'right token') : null

let ok = bad.binary === 0 && bad.closed === 4003 && none.binary === 0
console.log(bad, none)
if (good) {
  console.log(good)
  ok = ok && good.binary > 0 && good.key && !!good.config
}
console.log(ok ? 'OK' : 'FAIL')
process.exit(ok ? 0 : 1)
