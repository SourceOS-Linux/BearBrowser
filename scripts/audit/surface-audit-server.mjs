#!/usr/bin/env node
/* BearBrowser attack-surface audit harness.
 *
 * Serves an audit page over loopback and receives the probe report back, so the
 * probes run in REAL CONTENT SCOPE (what a website actually sees) — not the
 * privileged chrome scope the Browser Console shows.
 *
 *   node scripts/audit/surface-audit-server.mjs            # serve + wait
 * then point BearBrowser at http://127.0.0.1:8099/
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.AUDIT_PORT || 8099);
const OUT = process.env.AUDIT_OUT || path.join(DIR, "surface-report.json");

const server = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/report") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      fs.writeFileSync(OUT, body);
      res.writeHead(204).end();
      console.log(`report written: ${OUT} (${body.length} bytes)`);
      setTimeout(() => process.exit(0), 200);
    });
    return;
  }
  const html = fs.readFileSync(path.join(DIR, "surface-audit.html"));
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(html);
});
server.listen(PORT, "127.0.0.1", () =>
  console.log(`audit harness on http://127.0.0.1:${PORT}/ — waiting for report…`)
);
setTimeout(() => { console.error("timeout: no report received"); process.exit(2); }, 90000);
