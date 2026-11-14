import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const root = path.join(import.meta.dirname, '..');
const UP = path.join(root, 'server', 'data', 'uploads');
const MSG = path.join(root, 'server', 'data', 'messages.jsonl');

const files = fs.existsSync(UP) ? fs.readdirSync(UP) : [];
/** hash -> [names] */
const byHash = new Map();
let before = 0;
for (const f of files) {
  const full = path.join(UP, f);
  const st = fs.statSync(full);
  if (!st.isFile()) continue;
  before += st.size;
  const h = crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex').slice(0, 16);
  if (!byHash.has(h)) byHash.set(h, []);
  byHash.get(h).push(f);
}

/** oldName -> canonicalName */
const rename = new Map();
let saved = 0;
for (const [h, names] of byHash) {
  if (names.length < 2) continue;
  names.sort();
  const canonical = `${h}${path.extname(names[0])}`;
  // 保证 canonical 存在（若原文件名恰好不同，就落一份规范名）
  const canonicalFull = path.join(UP, canonical);
  if (!fs.existsSync(canonicalFull)) {
    fs.copyFileSync(path.join(UP, names[0]), canonicalFull);
  }
  for (const n of names) {
    if (n !== canonical) {
      const full = path.join(UP, n);
      const size = fs.statSync(full).size;
      fs.unlinkSync(full);
      saved += size;
      rename.set(n, canonical);
    }
  }
}

let rewritten = 0;
if (rename.size > 0 && fs.existsSync(MSG)) {
  const lines = fs.readFileSync(MSG, 'utf8').split('\n').filter(Boolean);
  const out = lines.map((line) => {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      return line;
    }
    let touched = false;
    if (obj.image) {
      const base = path.basename(String(obj.image));
      if (rename.has(base)) {
        obj.image = `/files/${rename.get(base)}`;
        touched = true;
      }
    }
    if (obj.quote && obj.quote.image) {
      const base = path.basename(String(obj.quote.image));
      if (rename.has(base)) {
        obj.quote.image = `/files/${rename.get(base)}`;
        touched = true;
      }
    }
    if (touched) rewritten += 1;
    return touched ? JSON.stringify(obj) : line;
  });
  fs.writeFileSync(MSG, out.join('\n') + '\n');
}

const after = fs.readdirSync(UP).reduce((n, f) => n + fs.statSync(path.join(UP, f)).size, 0);
console.log(JSON.stringify({
  files: files.length,
  uniqueHashes: byHash.size,
  removedFiles: rename.size,
  rewrittenMessages: rewritten,
  beforeBytes: before,
  afterBytes: after,
  savedBytes: before - after,
}, null, 2));
