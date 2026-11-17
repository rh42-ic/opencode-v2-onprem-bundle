#!/usr/bin/env bun
/**
 * build.ts —— bundle 管线唯一入口（源码准备 → 二进制 → 运行时资产 → 打包）。
 * 用法: bun run scripts/build.ts [--ref <tag|branch|sha>] [--platform linux-x64|win32-x64]
 *                [--from-source] [--work <dir>]
 * 二进制默认取官方 release（SHA256SUMS 校验）；非 tag ref 或 --from-source 时从源码构建。
 * 网络语义：本脚本按需访问网络（下载/克隆/npm），不做任何出口环境预设 —— 出口属运行环境。
 */
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import path from "node:path"
import { deflateRawSync } from "node:zlib"

const REPO_ROOT = path.resolve(import.meta.dirname, "..")
const argv = process.argv.slice(2)
const argv1 = (name: string) => {
  const i = argv.indexOf(name)
  return i > -1 ? argv[i + 1] : undefined
}
const WORK = path.resolve(REPO_ROOT, argv1("--work") ?? "work")
const PLATFORM = argv1("--platform") ?? "linux-x64"
const FROM_SOURCE = argv.includes("--from-source")
const SRC_REPO_ENV = process.env.OPENCODE_REPO // 本地检出可覆盖；CI 不设 → 默认 upstream URL
const DL = path.resolve(REPO_ROOT, ".dl-cache")
const log = (...a: unknown[]) => console.error("[build]", ...a)

if (!["linux-x64", "win32-x64"].includes(PLATFORM)) throw new Error(`unsupported platform: ${PLATFORM}`)
mkdirSync(WORK, { recursive: true })

async function sh(cmd: string[], opts: { cwd?: string; env?: Record<string, string> } = {}) {
  const p = Bun.spawn(cmd, {
    cwd: opts.cwd,
    env: opts.env ? { ...process.env, ...opts.env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()])
  const code = await p.exited
  if (code !== 0) throw new Error(`${cmd.join(" ")}\nexit ${code}: ${err.trim().slice(-800)}`)
  return out
}
const mkdtemp = async () => (await sh(["mktemp", "-d"])).trim()
const sha256File = async (file: string) =>
  createHash("sha256").update(new Uint8Array(await Bun.file(file).arrayBuffer())).digest("hex")

// 最小 ZIP 写入器（deflate，固定时间戳 → 可复现）—— Windows 资源管理器可直接解压。
// 不依赖 zip/7z 命令，任何构建机可用。
const CRC_TABLE = (() => {
  const t = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c >>> 0
  }
  return t
})()
function crc32(buf: Uint8Array) {
  let c = 0xffffffff
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}
function zipDir(root: string, top: string, out: string) {
  const files: { name: string; data: Buffer; exec: boolean }[] = []
  const walk = (rel: string) => {
    for (const d of readdirSync(path.join(root, rel), { withFileTypes: true })) {
      const r = rel ? `${rel}/${d.name}` : d.name
      if (d.isDirectory()) walk(r)
      else if (d.isFile()) {
        const full = path.join(root, r)
        files.push({ name: r, data: readFileSync(full), exec: (statSync(full).mode & 0o111) !== 0 })
      }
    }
  }
  walk(top)
  const chunks: Buffer[] = []
  const central: Buffer[] = []
  let offset = 0
  for (const f of files) {
    const nameBuf = Buffer.from(f.name)
    const data = deflateRawSync(f.data)
    const crc = crc32(f.data)
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4) // version needed
    local.writeUInt16LE(0x0800, 6) // UTF-8 names
    local.writeUInt16LE(8, 8) // deflate
    local.writeUInt16LE(0, 10) // time
    local.writeUInt16LE(0x0021, 12) // date = 1980-01-01（确定性）
    local.writeUInt32LE(crc, 14)
    local.writeUInt32LE(data.length, 18)
    local.writeUInt32LE(f.data.length, 22)
    local.writeUInt16LE(nameBuf.length, 26)
    local.writeUInt16LE(0, 28)
    chunks.push(local, nameBuf, data)

    const cen = Buffer.alloc(46)
    cen.writeUInt32LE(0x02014b50, 0)
    cen.writeUInt16LE(0x031e, 4) // made by: unix
    cen.writeUInt16LE(20, 6)
    cen.writeUInt16LE(0x0800, 8)
    cen.writeUInt16LE(8, 10)
    cen.writeUInt16LE(0, 12)
    cen.writeUInt16LE(0x0021, 14)
    cen.writeUInt32LE(crc, 16)
    cen.writeUInt32LE(data.length, 20)
    cen.writeUInt32LE(f.data.length, 24)
    cen.writeUInt16LE(nameBuf.length, 28)
    cen.writeUInt32LE(((f.exec ? 0o100755 : 0o100644) << 16) >>> 0, 38)
    cen.writeUInt32LE(offset, 42)
    central.push(cen, nameBuf)
    offset += local.length + nameBuf.length + data.length
  }
  const cd = Buffer.concat(central)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054b50, 0)
  eocd.writeUInt16LE(files.length, 8)
  eocd.writeUInt16LE(files.length, 10)
  eocd.writeUInt32LE(cd.length, 12)
  eocd.writeUInt32LE(offset, 16)
  writeFileSync(out, Buffer.concat([...chunks, cd, eocd]))
}
async function findFile(dir: string, name: string) {
  for await (const rel of new Bun.Glob(`**/${name}`).scan({ cwd: dir, onlyFiles: true })) return path.join(dir, rel)
}
async function download(url: string, dest: string) {
  if (existsSync(dest)) return
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch(url, { redirect: "follow" })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const buf = Buffer.from(await res.arrayBuffer())
      if (!buf.byteLength) throw new Error("empty body")
      writeFileSync(dest + ".part", buf)
      renameSync(dest + ".part", dest)
      return
    } catch (e) {
      if (attempt === 3) throw new Error(`failed to fetch ${url}: ${e.message}`)
      await Bun.sleep(attempt * 2000)
    }
  }
}

// ── 1. 源码准备：仓库（URL 自动 clone）→ ref 解析 → worktree ─────────────────
let REF = argv1("--ref")
const REPO = SRC_REPO_ENV ?? "https://github.com/anomalyco/opencode"
if (!REF) {
  const tags = await sh(["git", "ls-remote", "--tags", "--refs", "--sort=-v:refname", REPO, "v*"])
  REF = tags.split("\n")[0]?.split("refs/tags/")[1]
  if (!REF) throw new Error("no v* tag found")
}
const repoDir = /^https?:/.test(REPO) ? null : REPO
const srcRepo = repoDir ?? path.join(WORK, "opencode-src")
if (!repoDir) {
  if (!existsSync(srcRepo)) await sh(["git", "clone", "--filter=blob:none", "--no-checkout", REPO, srcRepo])
}
if (!(await sh(["git", "-C", srcRepo, "rev-parse", "--verify", "--quiet", `${REF}^{commit}`]).catch(() => ""))) {
  await sh(["git", "-C", srcRepo, "fetch", "origin", "--tags", "--prune", "--force"])
}
const COMMIT = (await sh(["git", "-C", srcRepo, "rev-parse", `${REF}^{commit}`])).trim()
const VERSION = JSON.parse(await sh(["git", "-C", srcRepo, "show", `${COMMIT}:packages/cli/package.json`])).version
if (!VERSION) throw new Error("cannot read version from packages/cli/package.json")
log(`ref=${REF} commit=${COMMIT.slice(0, 12)} version=${VERSION} platform=${PLATFORM}`)

const SRC = path.join(WORK, "src")
rmSync(SRC, { recursive: true, force: true })
await sh(["git", "-C", srcRepo, "worktree", "remove", "--force", SRC]).catch(() => {})
await sh(["git", "-C", srcRepo, "worktree", "prune"])
await sh(["git", "-C", srcRepo, "worktree", "add", "--detach", SRC, COMMIT])


// ── 2. 二进制：官方 release（默认）或源码构建 ────────────────────────────────
const IS_TAG = REF === `v${VERSION}`
const BINARY_SOURCE = FROM_SOURCE || !IS_TAG ? "source" : "official-release"
const EXE = PLATFORM === "win32-x64" ? "opencode.exe" : "opencode"
const BINARY = path.join(WORK, "binary", EXE)
mkdirSync(path.join(WORK, "binary"), { recursive: true })

if (BINARY_SOURCE === "official-release") {
  const asset = PLATFORM === "win32-x64" ? "opencode-windows-x64.zip" : "opencode-linux-x64.tar.gz"
  const base = `https://github.com/anomalyco/opencode/releases/download/${REF}`
  const cache = path.join(DL, `official-${REF}`)
  mkdirSync(cache, { recursive: true })
  await download(`${base}/${asset}`, path.join(cache, asset))
  await download(`${base}/SHA256SUMS`, path.join(cache, "SHA256SUMS"))
  const expect = (await Bun.file(path.join(cache, "SHA256SUMS")).text())
    .split("\n")
    .find((l) => l.trimEnd().endsWith(`  ${asset}`))
    ?.split(" ")[0]
  if (!expect) throw new Error(`SHA256SUMS: no entry for ${asset}`)
  if ((await sha256File(path.join(cache, asset))) !== expect) throw new Error(`official asset sha256 mismatch: ${asset}`)
  const tmp = await mkdtemp()
  if (PLATFORM === "win32-x64") await sh(["unzip", "-q", "-o", path.join(cache, asset), "-d", tmp])
  else await sh(["tar", "-xzf", path.join(cache, asset), "-C", tmp])
  const binSrc = await findFile(tmp, EXE)
  if (!binSrc) throw new Error(`${EXE} not found in ${asset}`)
  if ((await Bun.file(binSrc).stat()).size < 50_000_000) throw new Error(`official binary too small`)
  await sh(["cp", binSrc, BINARY])
  rmSync(tmp, { recursive: true, force: true })
  log(`official binary ok (${(await sha256File(BINARY)).slice(0, 16)}...)`)
} else {
  const pin = /bun@([\d.]+)/.exec(JSON.parse(await Bun.file(path.join(SRC, "package.json")).text()).packageManager ?? "")?.[1]
  const actual = (await sh(["bun", "--version"])).trim()
  if (pin && pin !== actual) throw new Error(`bun ${actual} != source pin ${pin}`)
  log(`bun install (${SRC}) ...`)
  await sh(["bun", "install"], { cwd: SRC })
  const cli = path.join(SRC, "packages/cli")
  if (PLATFORM === "win32-x64") {
    log("cross-compiling win32-x64（运行时验证不可行，发布标注 unverified）...")
    await sh(["bun", "run", "script/build.ts"], { cwd: cli, env: { OPENCODE_VERSION: VERSION, OPENCODE_TARGET: "windows-x64" } })
  } else {
    log("building linux-x64 ...")
    await sh(["bun", "run", "script/build.ts", "--single"], { cwd: cli, env: { OPENCODE_VERSION: VERSION } })
  }
  const built = path.join(
    cli,
    "dist",
    PLATFORM === "win32-x64" ? "cli-windows-x64/bin/opencode.exe" : "cli-linux-x64/bin/opencode",
  )
  if (!existsSync(built)) throw new Error(`binary not found at ${built}`)
  await sh(["cp", built, BINARY])
}
if (PLATFORM === "linux-x64") log(`version: ${(await sh([BINARY, "--version"])).trim()}`)

// ── 3. 运行时资产 ────────────────────────────────────────────────────────────
const ASSETS = path.join(WORK, "assets")
rmSync(ASSETS, { recursive: true, force: true })

// 3a. ripgrep —— 版本/sha256 取自源码常量（自动跟随 upstream）
const rgFile = PLATFORM === "win32-x64" ? "rg.exe" : "rg"
const binaryTs = await Bun.file(path.join(SRC, "packages/core/src/ripgrep/binary.ts")).text()
const RG_VERSION = /VERSION = "([^"]+)"/.exec(binaryTs)?.[1]
if (!RG_VERSION) throw new Error("ripgrep VERSION not found in binary.ts")
const rgRow = new RegExp(
  `"${PLATFORM === "win32-x64" ? "x64-win32" : "x64-linux"}"\\s*:\\s*\\{[^}]*?platform:\\s*"([^"]+)"[^}]*?extension:\\s*"([^"]+)"[^}]*?sha256:\\s*"([0-9a-f]{64})"`,
  "s",
).exec(binaryTs)
if (!rgRow) throw new Error("ripgrep platform row not found")
const [, rgTriple, rgExt, rgSha] = rgRow
const rgUrl = `https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/ripgrep-${RG_VERSION}-${rgTriple}.${rgExt}`
const rgCache = path.join(DL, path.basename(rgUrl))
mkdirSync(DL, { recursive: true })
await download(rgUrl, rgCache)
if ((await sha256File(rgCache)) !== rgSha) throw new Error(`ripgrep sha256 mismatch (expected ${rgSha})`)
const tmpRg = await mkdtemp()
rgExt === "zip" ? await sh(["unzip", "-q", "-o", rgCache, "-d", tmpRg]) : await sh(["tar", "-xzf", rgCache, "-C", tmpRg])
const rgSrc = await findFile(tmpRg, rgFile)
if (!rgSrc) throw new Error(`rg not found in ${path.basename(rgUrl)}`)
mkdirSync(path.join(ASSETS, "bin"), { recursive: true })
await sh(["cp", rgSrc, path.join(ASSETS, "bin", rgFile)])
rmSync(tmpRg, { recursive: true, force: true })
log(`ripgrep ${RG_VERSION} ok (${rgTriple})`)

// 3b. tree-sitter —— 直接 import upstream parsers-config，opentui hashUrl 精确复刻
function hashUrl(url: string) {
  let hash = 0
  for (let i = 0; i < url.length; i++) {
    hash = (hash << 5) - hash + url.charCodeAt(i)
    hash = hash & hash
  }
  return Math.abs(hash).toString(16)
}
const parsersMod = (await import(path.join(SRC, "packages/tui/src/parsers-config.ts"))).default
const parsers = parsersMod.parsers.flatMap((p: { filetype: string; wasm?: unknown; queries?: Record<string, unknown> }) => {
  const wasm = typeof p.wasm === "string" && p.wasm.startsWith("http") ? p.wasm : undefined
  const queries = Object.values(p.queries ?? {}).flatMap((v) =>
    Array.isArray(v) ? v.filter((u): u is string => typeof u === "string" && u.startsWith("http")) : [],
  )
  if (!wasm && !queries.length) return []
  return [{ filetype: p.filetype, wasm, queries }]
})
const tsCache = path.join(DL, "tree-sitter")
const langDir = path.join(ASSETS, "tree-sitter", "languages")
const queryDir = path.join(ASSETS, "tree-sitter", "queries")
mkdirSync(tsCache, { recursive: true })
mkdirSync(langDir, { recursive: true })
mkdirSync(queryDir, { recursive: true })
const jobs = parsers.flatMap((p: { filetype: string; wasm?: string; queries: string[] }) => [
  ...(p.wasm ? [{ url: p.wasm, dest: path.join(langDir, path.basename(p.wasm)) }] : []),
  ...p.queries.map((u) => ({ url: u, dest: path.join(queryDir, `${p.filetype}-${hashUrl(u)}.scm`) })),
])
const tsKey = (url: string) => path.join(tsCache, createHash("sha256").update(url).digest("hex"))
let done = 0
const failures: string[] = []
const queue = [...jobs]
await Promise.all(
  Array.from({ length: 8 }, async () => {
    while (queue.length) {
      const job = queue.shift()!
      try {
        await download(job.url, tsKey(job.url))
        await sh(["cp", tsKey(job.url), job.dest])
        if (++done % 10 === 0 || done === jobs.length) log(`tree-sitter ${done}/${jobs.length}`)
      } catch (e) {
        failures.push(String(e.message))
      }
    }
  }),
)
if (failures.length) throw new Error(`tree-sitter failed (${failures.length}/${jobs.length}):\n  ${failures.slice(0, 5).join("\n  ")}`)
for (const job of jobs) if ((await Bun.file(job.dest).stat()).size === 0) throw new Error(`empty asset: ${job.dest}`)
log(`tree-sitter ok: ${parsers.length} filetypes, ${jobs.filter((j) => j.dest.endsWith(".wasm")).length} wasm, ${jobs.filter((j) => j.dest.endsWith(".scm")).length} queries`)

// 3c. npm 插件 vendoring —— 键规则精确复现 packages/util/src/npm.ts
//   registry spec：裸包名 → @latest；显式 spec 原样。key = <name>@<spec>
//   git spec：slug 先取 spec.split("#")[0]（npm.ts gitSlug 第一步）→ 去 .git → 末段 → sanitize；
//             key = git-<slug>-<sha256(完整spec)[:12]>
function splitSpec(spec: string) {
  if (spec.includes("@git+") || spec.startsWith("git+")) {
    const slugBase = spec.split("#")[0]
    const slug =
      slugBase
        .replace(/\.git$/i, "")
        .split(/[/:\\]/)
        .at(-1)
        ?.replace(/[^a-zA-Z0-9._-]+/g, "-")
        .replace(/^-+|-+$/g, "") || "repository"
    return { name: slug, key: `git-${slug}-${new Bun.CryptoHasher("sha256").update(spec).digest("hex").slice(0, 12)}` }
  }
  const m = spec.match(/^(@[^/]+\/[^@\s]+|[^@\s]+)(?:@(.+))?$/)
  if (!m) throw new Error(`bad spec: ${spec}`)
  return { name: m[1], key: `${m[1]}@${m[2] ?? "latest"}` }
}
async function npm(args: string[], opts: { cwd?: string } = {}) {
  const p = Bun.spawn(["npm", ...args], {
    cwd: opts.cwd,
    env: { ...process.env, NO_PROXY: "127.0.0.1,localhost,::1" },
    stdout: "pipe",
    stderr: "pipe",
  })
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()])
  const code = await p.exited
  if (code !== 0) throw new Error(`npm ${args.join(" ")} failed (${code}): ${err.trim().slice(0, 500)}`)
  return out
}
const manifest = JSON.parse(await Bun.file(path.join(REPO_ROOT, "manifest.json")).text())
const npmResults: { name: string; slug?: string; spec: string; key: string; version: string }[] = []
for (const p of manifest.plugins ?? []) {
  const { name, key } = splitSpec(p.spec)
  log(`npm vendoring ${key} ...`)
  if (!Bun.which("npm")) throw new Error("npm CLI not found (need node/npm to resolve dependency trees)")
  const tmp = await mkdtemp()
  let version: string
  if (key.startsWith("git-")) {
    // npm 11 默认禁 git 依赖（EALLOWGIT）——直接 clone；包内依赖就地安装
    const m = p.spec.match(/^(?:[^@\s]+@)?git\+(.+?)(?:#(.+))?$/)
    if (!m) throw new Error(`bad git spec: ${p.spec}`)
    const ref = p.git_ref ?? m[2]
    if (ref && /^[a-f0-9]{40}$/i.test(ref)) {
      await sh(["git", "clone", "--quiet", m[1], path.join(tmp, "pkg")])
      await sh(["git", "-C", path.join(tmp, "pkg"), "fetch", "--quiet", "--depth", "1", "origin", ref])
      await sh(["git", "-C", path.join(tmp, "pkg"), "checkout", "--quiet", "--detach", "FETCH_HEAD"])
    } else {
      await sh(ref ? ["git", "clone", "--quiet", "--depth", "1", "--branch", ref, m[1], path.join(tmp, "pkg")] : ["git", "clone", "--quiet", "--depth", "1", m[1], path.join(tmp, "pkg")])
    }
    const pkgMeta = JSON.parse(await Bun.file(path.join(tmp, "pkg", "package.json")).text())
    version = pkgMeta.version
    rmSync(path.join(tmp, "pkg", ".git"), { recursive: true, force: true })
    rmSync(path.join(tmp, "pkg", "tests"), { recursive: true, force: true })
    rmSync(path.join(tmp, "pkg", ".github"), { recursive: true, force: true })
    if (pkgMeta.dependencies && Object.keys(pkgMeta.dependencies).length)
      await npm(["install", "--ignore-scripts", "--no-audit", "--no-fund", "--omit=dev", "--loglevel=error"], { cwd: path.join(tmp, "pkg") })
    const dest = path.join(ASSETS, "npm", key, "node_modules")
    mkdirSync(dest, { recursive: true })
    await sh(["cp", "-a", path.join(tmp, "pkg"), path.join(dest, pkgMeta.name)]) // node_modules 内目录名 = 真实包名（installedName 读 package.json），键才是 slug
    npmResults.push({ name: pkgMeta.name, slug: name, spec: p.spec, key, version })
  } else {
    const rawSpec = key.slice(name.length + 1)
    const verOut = await npm(["view", `${name}@${rawSpec}`, "version", "--json"])
    const parsed = JSON.parse(verOut.trim())
    version = Array.isArray(parsed) ? parsed[parsed.length - 1] : parsed
    if (typeof version !== "string") throw new Error(`unexpected npm view output for ${key}`)
    writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ name: "vendor-tmp", private: true, dependencies: { [name]: version } }, null, 2))
    await npm(["install", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"], { cwd: tmp })
    const pkgDir = path.join(tmp, "node_modules", name)
    if (!existsSync(pkgDir)) throw new Error(`expected ${pkgDir} after install`)
    const dest = path.join(ASSETS, "npm", key, "node_modules")
    mkdirSync(path.dirname(dest), { recursive: true }) // 只建父目录：cp -a src dest 在 dest 已存在时会嵌套成 dest/node_modules
    await sh(["cp", "-a", path.join(tmp, "node_modules"), dest])
    npmResults.push({ name, spec: p.spec, key, version: JSON.parse(await Bun.file(path.join(pkgDir, "package.json")).text()).version })
  }
  rmSync(tmp, { recursive: true, force: true })
  log(`npm ok: ${key} @ ${version}`)
}

// 3d. 配置 JSON schema —— 独立 schema/ 目录；递归抓取外部 $ref 并本地化（$id 同步改本地文件名，
//    否则相对 $ref 会按远程 base URI 解析）
const schemaDir = path.join(ASSETS, "schema")
mkdirSync(schemaDir, { recursive: true })
const SCHEMA_ENTRY = "https://opencode.ai/config.json"
const schemaSeen = new Map<string, string>() // 远程 base URL -> 本地文件名
const schemaQueue: string[] = []
const schemaSlug = (url: string) => {
  const s = url.replace(/^https?:\/\//, "").replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "")
  return s.endsWith(".json") ? s : `${s}.json`
}
const schemaEnsure = (url: string) => {
  if (!schemaSeen.has(url)) {
    schemaSeen.set(url, schemaSeen.size === 0 ? "config.json" : schemaSlug(url))
    schemaQueue.push(url)
  }
  return schemaSeen.get(url)!
}
schemaEnsure(SCHEMA_ENTRY)
while (schemaQueue.length) {
  const url = schemaQueue.shift()!
  const file = schemaSeen.get(url)!
  const dest = path.join(schemaDir, file)
  await download(url, dest)
  const doc = await Bun.file(dest).json()
  const rewrite = (node: unknown): void => {
    if (Array.isArray(node)) return node.forEach(rewrite)
    if (!node || typeof node !== "object") return
    const obj = node as Record<string, unknown>
    if (typeof obj.$ref === "string") {
      const hash = obj.$ref.indexOf("#")
      const base = hash > -1 ? obj.$ref.slice(0, hash) : obj.$ref
      const frag = hash > -1 ? obj.$ref.slice(hash) : ""
      if (/^https?:/.test(base)) obj.$ref = schemaEnsure(base) + frag
    }
    for (const v of Object.values(obj)) rewrite(v)
  }
  rewrite(doc)
  if (typeof doc.$id === "string" && /^https?:/.test(doc.$id)) doc.$id = file
  await Bun.write(dest, JSON.stringify(doc, null, 2) + "\n")
  log(`config schema: ${url} -> schema/${file}`)
}
// omo-slim 插件配置 schema（包内自带，无外部 $ref）：随 schema/ 一起供编辑器本地校验
const slim = npmResults.find((r) => r.name === "oh-my-opencode-slim")
const slimSchema = slim ? path.join(ASSETS, "npm", slim.key, "node_modules", "oh-my-opencode-slim", "oh-my-opencode-slim.schema.json") : ""
const hasSlimSchema = slimSchema ? await Bun.file(slimSchema).exists() : false
if (slim && hasSlimSchema) {
  await sh(["cp", slimSchema, path.join(schemaDir, "oh-my-opencode-slim.json")])
  log("config schema: oh-my-opencode-slim -> schema/oh-my-opencode-slim.json")
}
const schemaFiles = [...schemaSeen.entries()].map(([url, file]) => ({ url, file, sha256: "" }))
if (slim && hasSlimSchema) schemaFiles.push({ url: `npm:oh-my-opencode-slim@${slim.version}`, file: "oh-my-opencode-slim.json", sha256: "" })
for (const f of schemaFiles) f.sha256 = await sha256File(path.join(schemaDir, f.file))

const assetsJson = {
  ripgrep_version: RG_VERSION,
  schema: { entry: "schema/config.json", files: schemaFiles },
  tree_sitter: { filetypes: parsers.length, wasm: jobs.filter((j) => j.dest.endsWith(".wasm")).length, queries: jobs.filter((j) => j.dest.endsWith(".scm")).length },
  npm: npmResults,
}
await Bun.write(path.join(WORK, "assets.json"), JSON.stringify(assetsJson, null, 2) + "\n")

// 守卫：manifest 声明的插件必须全部 vendored 落地，否则离线必坏
for (const p of manifest.plugins ?? []) {
  const r = npmResults.find((r) => r.spec === p.spec)
  if (!r || !existsSync(path.join(ASSETS, "npm", r.key, "node_modules", r.name, "package.json")))
    throw new Error(`plugin not vendored: ${p.spec}`)
}

// ── 4. 打包 ─────────────────────────────────────────────────────────────────
const NAME = `opencode-${VERSION}-onprem-${PLATFORM}`
const BUNDLE = path.join(WORK, "bundle", NAME)
rmSync(BUNDLE, { recursive: true, force: true })
mkdirSync(path.join(BUNDLE, "bin"), { recursive: true })
mkdirSync(path.join(BUNDLE, "assets"), { recursive: true }) // cp -a 不建中间目录
mkdirSync(path.join(BUNDLE, "config"), { recursive: true })
await sh(["cp", BINARY, path.join(BUNDLE, "bin", EXE)])
await sh(["cp", path.join(ASSETS, "bin", rgFile), path.join(BUNDLE, "bin", rgFile)])
await sh(["chmod", "755", path.join(BUNDLE, "bin", EXE), path.join(BUNDLE, "bin", rgFile)])
await sh(["cp", "-a", path.join(ASSETS, "tree-sitter"), path.join(BUNDLE, "assets/tree-sitter")])
if (existsSync(path.join(ASSETS, "npm"))) {
  await sh(["cp", "-a", path.join(ASSETS, "npm"), path.join(BUNDLE, "assets/npm")])
}
// config 模板：注入 vendored 插件清单（占位符 → JSON 数组）
const tpl = await Bun.file(path.join(REPO_ROOT, "config/opencode.airgap.json")).text()
const inject = (manifest.plugins ?? []).map((p: { spec: string }) => JSON.stringify(p.spec)).join(", ")
if (!tpl.includes("/*__PLUGINS__*/")) throw new Error("config template missing /*__PLUGINS__*/ placeholder")
writeFileSync(path.join(BUNDLE, "config/opencode.airgap.json"), tpl.replace("/*__PLUGINS__*/", inject))
await sh(["cp", path.join(REPO_ROOT, "config/target-readme.md"), path.join(BUNDLE, "README.md")])
await sh(["cp", "-a", schemaDir, path.join(BUNDLE, "schema")])
await sh(["cp", path.join(REPO_ROOT, "config/env.sh"), path.join(BUNDLE, "env.sh")])
await sh(["cp", path.join(REPO_ROOT, "scripts/install.sh"), path.join(BUNDLE, "install.sh")])
await sh(["chmod", "755", path.join(BUNDLE, "install.sh")])

const bundleManifest = {
  name: manifest.name,
  upstream: manifest.upstream,
  plugins: manifest.plugins ?? [],
  plugins_unverified: manifest.plugins_unverified ?? [],
  ref: REF,
  version: VERSION,
  commit: COMMIT,
  platform: PLATFORM,
  binary_source: BINARY_SOURCE,
  bun: process.versions.bun,
  built_at: new Date().toISOString(),
  binary_sha256: await sha256File(path.join(BUNDLE, "bin", EXE)),
  ripgrep_sha256: await sha256File(path.join(BUNDLE, "bin", rgFile)),
  assets: assetsJson,
}
await Bun.write(path.join(BUNDLE, "MANIFEST.json"), JSON.stringify(bundleManifest, null, 2) + "\n")

const OUT_DIR = path.join(REPO_ROOT, "out")
mkdirSync(OUT_DIR, { recursive: true })
// win32-x64 用 zip（Windows 解压 tar.gz 困难）；linux-x64 用 tar.gz
const EXT = PLATFORM === "win32-x64" ? "zip" : "tar.gz"
const ARCHIVE = path.join(OUT_DIR, `opencode-v${VERSION}-onprem-bundle-${PLATFORM}.${EXT}`)
rmSync(ARCHIVE, { force: true })
if (EXT === "zip") zipDir(path.join(WORK, "bundle"), NAME, ARCHIVE)
else await sh(["tar", "-czf", ARCHIVE, "-C", path.join(WORK, "bundle"), NAME])
await Bun.write(`${ARCHIVE}.sha256`, `${await sha256File(ARCHIVE)}  ${path.basename(ARCHIVE)}\n`)

writeFileSync(
  path.join(WORK, "build.env"),
  `REF=${REF}\nCOMMIT=${COMMIT}\nVERSION=${VERSION}\nPLATFORM=${PLATFORM}\nBINARY_SOURCE=${BINARY_SOURCE}\nTARBALL=${ARCHIVE}\n`,
)
log(`bundle: ${BUNDLE}`)
log(`archive: ${ARCHIVE} (${((await Bun.file(ARCHIVE).stat()).size / 1e6).toFixed(0)}MB)`)
console.log(`TARBALL=${ARCHIVE}`)
