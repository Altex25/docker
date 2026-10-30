#!/usr/bin/env bash
set -euo pipefail

RATE=${RATE:-100}
DURATION=${DURATION:-60}
URL=${URL:-http://127.0.0.1/?health}
HOST_HEADER=${HOST_HEADER:-geststock.localhost}
TIMEOUT_MS=${TIMEOUT_MS:-2000}
NODE_IMAGE=node:22.23.4-alpine3.23@sha256:6abbcf5dd6b231da109bcde1181db1d92bf78015ae1a9514d9807c1f857869db

exec docker run --rm --init --network host --name "measure-downtime-$$" \
  -e RATE="$RATE" -e DURATION="$DURATION" -e URL="$URL" -e HOST_HEADER="$HOST_HEADER" -e TIMEOUT_MS="$TIMEOUT_MS" \
  "$NODE_IMAGE" node -e '
const http = require("node:http");
const { RATE, DURATION, URL: url, HOST_HEADER: host, TIMEOUT_MS } = process.env;
const rate = Number(RATE), duration = Number(DURATION), timeout = Number(TIMEOUT_MS);
const agent = new http.Agent({ keepAlive: true, maxSockets: 64 });
const target = new URL(url);
const perSecond = [];
const reasons = {};
const latencies = [];
let sent = 0, done = 0;
const t0 = performance.now();

const bucket = (s) => (perSecond[s] ??= { sent: 0, ok: 0, ko: 0 });
function record(s, ok, reason, ms) {
  done++;
  const b = bucket(s);
  if (ok) { b.ok++; latencies.push(ms); } else { b.ko++; reasons[reason] = (reasons[reason] || 0) + 1; }
}
function fire(s) {
  const start = performance.now();
  bucket(s).sent++;
  let settled = false;
  const finish = (ok, reason) => { if (!settled) { settled = true; record(s, ok, reason, performance.now() - start); } };
  const req = http.get({ host: target.hostname, port: target.port || 80, path: target.pathname + target.search, headers: { host }, agent, timeout }, (res) => {
    res.resume();
    res.on("end", () => finish(res.statusCode === 200, "HTTP " + res.statusCode));
  });
  req.on("timeout", () => { finish(false, "timeout " + timeout + "ms"); req.destroy(); });
  req.on("error", (e) => finish(false, e.code || e.message));
}

let printed = 0;
function report(upTo) {
  for (; printed < upTo; printed++) {
    const b = perSecond[printed] || { sent: 0, ok: 0, ko: 0 };
    console.log(`t=${String(printed).padStart(3)}s  envoyées=${b.sent}  ok=${b.ok}  échecs=${b.ko}${b.ko ? "  <<<" : ""}`);
  }
}
const tick = setInterval(() => {
  const elapsed = (performance.now() - t0) / 1000;
  if (elapsed >= duration) {
    clearInterval(tick);
    const wait = setInterval(() => {
      if (done >= sent || (performance.now() - t0) / 1000 > duration + timeout / 1000 + 1) { clearInterval(wait); summary(); }
    }, 50);
    return;
  }
  const due = Math.floor(elapsed * rate);
  while (sent < due) { sent++; fire(Math.floor(elapsed)); }
  report(Math.floor(elapsed) - 2);
}, 2);

function summary() {
  report(perSecond.length);
  const ko = perSecond.reduce((n, b) => n + (b ? b.ko : 0), 0);
  const failingSeconds = perSecond.filter((b) => b && b.ko).length;
  latencies.sort((a, b) => a - b);
  const pct = (p) => latencies.length ? latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * p))].toFixed(1) : "-";
  console.log(`== ${sent} requêtes en ${duration}s vers ${url} (Host: ${host}), ${rate} req/s`);
  console.log(`== ÉCHECS : ${ko} (${(100 * ko / sent).toFixed(2)} %) sur ${failingSeconds} seconde(s)`);
  for (const [r, n] of Object.entries(reasons)) console.log(`     ${r} : ${n}`);
  console.log(`== latence des succès : p50=${pct(0.5)} ms  p99=${pct(0.99)} ms  max=${latencies.length ? latencies[latencies.length - 1].toFixed(1) : "-"} ms`);
  console.log("RESUME " + JSON.stringify({ sent, failures: ko, failingSeconds, reasons, p99: Number(pct(0.99)) }));
  process.exit(0);
}
'
