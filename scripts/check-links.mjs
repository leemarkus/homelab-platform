#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

// Offline Markdown link check: local files and heading anchors only.
// Usage: node scripts/check-links.mjs [dir]   (default: repository root)
const forbidden = name => name === '.secrets' || name.startsWith('.env');
const ignored = new Set(['.git', 'node_modules', '.terraform']);
function safePath(file) {
  const full = path.resolve(file);
  let current = path.parse(full).root;
  for (const part of full.slice(current.length).split(path.sep).filter(Boolean)) {
    if (forbidden(part)) throw new Error(`Forbidden path: ${file}`);
    current = path.join(current, part);
    try {
      if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`Refusing symlink: ${current}`);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return full;
}
function walk(root) {
  root = safePath(root);
  if (!fs.existsSync(root)) return [];
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (forbidden(entry.name) || ignored.has(entry.name)) continue;
    const file = path.join(root, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Refusing symlink: ${file}`);
    if (entry.isDirectory()) files.push(...walk(file));
    else if (entry.isFile()) files.push(file);
  }
  return files;
}

const root = safePath(process.argv[2] ?? '.');
let checked = 0; let failures = 0;
for (const file of walk(root).filter(f => f.endsWith('.md'))) {
  const source = fs.readFileSync(file, 'utf8').replace(/^```[^\n]*\n[\s\S]*?^```\s*$/gm, '');
  const targets = [
    ...[...source.matchAll(/!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+["'][^\n]*["'])?\s*\)/g)].map(m => m[1]),
    ...[...source.matchAll(/^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)/gm)].map(m => m[1]),
    ...[...source.matchAll(/(?:href|src)=["']([^"']+)["']/g)].map(m => m[1]),
  ];
  for (let target of targets) {
    target = target.replace(/^<|>$/g, '');
    if (/^[a-z][a-z0-9+.-]*:|^\/\//i.test(target)) continue; // No network checks.
    const [rawPath, fragment] = target.split('#');
    let dest;
    try { dest = safePath(path.resolve(path.dirname(file), decodeURIComponent(rawPath.split('?')[0] || path.basename(file)))); }
    catch (error) { console.error(`FAIL ${file}: ${target}: ${error.message}`); failures++; continue; }
    checked++;
    if (!fs.existsSync(dest)) { console.error(`FAIL ${file}: missing ${target}`); failures++; continue; }
    if (fragment && dest.endsWith('.md')) {
      const text = fs.readFileSync(dest, 'utf8'); const ids = new Set(); const seen = new Map();
      for (const match of text.matchAll(/^#{1,6}\s+(.+)$/gm)) {
        const base = match[1].toLowerCase().replace(/<[^>]*>/g, '').replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/\s/g, '-');
        const count = seen.get(base) ?? 0; seen.set(base, count + 1); ids.add(count ? `${base}-${count}` : base);
      }
      for (const match of text.matchAll(/(?:id|name)=["']([^"']+)["']/g)) ids.add(match[1]);
      if (!ids.has(decodeURIComponent(fragment))) { console.error(`FAIL ${file}: missing anchor ${target}`); failures++; }
    }
  }
}
console.log(`Markdown links: ${checked} local targets checked, ${failures} failures (external URLs not fetched)`);
process.exitCode = failures ? 1 : 0;
