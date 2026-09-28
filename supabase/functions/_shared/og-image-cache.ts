// og-image-cache — skine `og:image` iz link previewa doprinosa i spremi ga u
// javni bucket `pinka-og-cache` (Supabase storage → Cloudflare R2). Zid crta
// samo ovu kopiju: tuđi host tako nikad ne vidi IP posjetitelja zida, a sliku
// dohvaćamo JEDNOM po doprinosu, ne po prikazu.
//
// Ova funkcija radi na Coolify hostu (ne u Cloudflare Workeru kao og-preview),
// pa je SSRF stvarna površina: iz containera su dosežni interni servisi
// (kong, imgproxy, db…). Obrana:
//   - samo https, samo port 443, bez korisnika/lozinke u URL-u
//   - host ne smije biti IP literal, localhost ni jednodijelno ime
//   - host se razriješi preko DoH (Cloudflare) i SVE A/AAAA adrese moraju biti
//     javne — interni docker DNS (`imgproxy`) tako i ne prođe
//   - redirecti ručno, najviše 3, svaki hop prolazi istu provjeru
//   - samo image/{jpeg,png,webp,gif,avif} (SVG nikad), najviše 2 MB, 4 s
// Preostali rizik: DNS rebinding između DoH provjere i fetcha. Uz https-only
// napadač bi za interni cilj trebao i valjan TLS certifikat za svoj host na
// internom servisu, što interni (http) servisi nemaju.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const OG_CACHE_BUCKET = "pinka-og-cache";
// NE `STORAGE_PUBLIC_URL`: to ime Coolify već postavlja u edge container i
// vrijednost mu je `http://api.domovina.ai` — tako su prvi URL-ovi ispali na
// http (28.9.2026.). Zid na https stranici treba https.
const PUBLIC_BASE = Deno.env.get("PINKA_OG_PUBLIC_BASE") ?? "https://api.domovina.ai";
const MAX_BYTES = 2 * 1024 * 1024;
const TIMEOUT_MS = 4000;
const MAX_REDIRECTS = 3;
const RENDER_WIDTH = 600;

const EXT_BY_TYPE: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/gif": "gif",
  "image/avif": "avif",
};

export type StoredOgImage = { url: string; width: number | null; height: number | null };

/// Skini sliku i spremi je u `pinka-og-cache` (ključ = sha256 izvornog URL-a,
/// pa ista slika iz previewa u obrascu i iz webhooka nakon plaćanja završi u
/// ISTOM objektu). Vraća javni render URL + dimenzije, ili null.
export async function storeOgImage(
  admin: SupabaseClient,
  imageUrl: string | null | undefined,
): Promise<StoredOgImage | null> {
  if (!imageUrl) return null;
  const img = await fetchPublicImage(imageUrl);
  if (!img) return null;

  const path = `${await sha256Hex(imageUrl)}.${EXT_BY_TYPE[img.type]}`;
  const { error: upErr } = await admin.storage
    .from(OG_CACHE_BUCKET)
    .upload(path, img.bytes, { contentType: img.type, upsert: true, cacheControl: "31536000" });
  if (upErr) {
    console.warn(`[og-image-cache] upload failed ${path}: ${upErr.message}`);
    return null;
  }
  // imgproxy render: resize na širinu kartice i recompress; izvornik ostaje u
  // bucketu kao izvor istine (drugačija širina = samo drugi query).
  const url = `${PUBLIC_BASE}/storage/v1/render/image/public/${OG_CACHE_BUCKET}/${path}` +
    `?width=${RENDER_WIDTH}&quality=80`;
  // Dimenzije idu uz URL: zid mora znati omjer PRIJE učitavanja slike (visina
  // pločice, portret lijevo / landscape ispod). null = nepoznato (AVIF…).
  const dims = imageSize(img.bytes);
  return { url, width: dims?.width ?? null, height: dims?.height ?? null };
}

/// Skini, spremi i dopiši `image_cached` (+ dimenzije) u `link_preview`
/// doprinosa. Vraća javni URL ili null (bilo koji kvar = kartica ostaje
/// tekstualna, kao i prije).
export async function cacheLinkPreviewImage(
  admin: SupabaseClient,
  contributionId: string,
  imageUrl: string | null | undefined,
): Promise<string | null> {
  const stored = await storeOgImage(admin, imageUrl);
  if (!stored) return null;
  const { error } = await admin.schema("pinka_finance").rpc("set_contribution_link_preview_image", {
    p_contribution_id: contributionId,
    p_image_cached: stored.url,
    p_width: stored.width,
    p_height: stored.height,
  });
  if (error) {
    console.warn(`[og-image-cache] rpc failed ${contributionId}: ${error.message}`);
    return null;
  }
  return stored.url;
}

async function fetchPublicImage(raw: string): Promise<{ bytes: Uint8Array; type: string } | null> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      if (!(await isPublicHttpsUrl(url))) return null;
      const res = await fetch(url, {
        redirect: "manual",
        signal: ctrl.signal,
        headers: { accept: "image/avif,image/webp,image/png,image/jpeg,image/gif" },
      });
      if (res.status >= 300 && res.status < 400) {
        const loc = res.headers.get("location");
        await res.body?.cancel();
        if (!loc) return null;
        url = new URL(loc, url);
        continue;
      }
      if (!res.ok || !res.body) return null;
      const type = (res.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
      if (!EXT_BY_TYPE[type]) {
        await res.body.cancel();
        return null;
      }
      const declared = Number(res.headers.get("content-length") ?? "0");
      if (declared > MAX_BYTES) {
        await res.body.cancel();
        return null;
      }
      const bytes = await readCapped(res.body, MAX_BYTES);
      if (!bytes || bytes.length === 0) return null;
      return { bytes, type };
    }
    return null;
  } catch (e) {
    console.warn(`[og-image-cache] fetch failed ${raw}: ${e}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/// null kad tijelo prijeđe limit (odrezana slika je gora od nikakve).
async function readCapped(body: ReadableStream<Uint8Array>, max: number): Promise<Uint8Array | null> {
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}

export async function isPublicHttpsUrl(url: URL): Promise<boolean> {
  if (url.protocol !== "https:") return false;
  if (url.port && url.port !== "443") return false;
  if (url.username || url.password) return false;
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host.includes(".")) return false; // `localhost`, docker imena (`imgproxy`)
  if (host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) return false;
  if (/^[\d.]+$/.test(host) || host.startsWith("[") || host.includes(":")) return false; // IP literal
  const ips = [...(await resolveDoh(host, "A")), ...(await resolveDoh(host, "AAAA"))];
  return ips.length > 0 && ips.every(isPublicIp);
}

async function resolveDoh(host: string, type: "A" | "AAAA"): Promise<string[]> {
  const res = await fetch(
    `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=${type}`,
    { headers: { accept: "application/dns-json" } },
  );
  if (!res.ok) return [];
  const body = (await res.json()) as { Answer?: { type: number; data: string }[] };
  const want = type === "A" ? 1 : 28;
  return (body.Answer ?? []).filter((a) => a.type === want).map((a) => a.data);
}

export function isPublicIp(ip: string): boolean {
  if (ip.includes(":")) {
    const v6 = ip.toLowerCase();
    if (v6 === "::1" || v6 === "::") return false;
    if (v6.startsWith("fc") || v6.startsWith("fd")) return false; // ULA
    if (/^fe[89ab]/.test(v6)) return false; // link-local
    if (v6.startsWith("::ffff:")) return isPublicIp(v6.slice(7)); // v4-mapped
    if (v6.startsWith("64:ff9b:")) return false; // NAT64
    return true;
  }
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = p;
  if (a === 0 || a === 10 || a === 127) return false;
  if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT (i Tailscale)
  if (a === 169 && b === 254) return false; // link-local / cloud metadata
  if (a === 172 && b >= 16 && b <= 31) return false; // docker bridge
  if (a === 192 && b === 168) return false;
  if (a === 192 && b === 0) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  if (a >= 224) return false; // multicast / reserved
  return true;
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Širina × visina iz zaglavlja PNG / JPEG / GIF / WebP, bez dekodiranja.
export function imageSize(b: Uint8Array): { width: number; height: number } | null {
  const u16be = (o: number) => (b[o] << 8) | b[o + 1];
  const u16le = (o: number) => b[o] | (b[o + 1] << 8);
  const u24le = (o: number) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
  const u32be = (o: number) => ((b[o] << 24) >>> 0) + ((b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
  const ok = (w: number, h: number) => (w > 0 && h > 0 ? { width: w, height: h } : null);
  if (b.length < 30) return null;
  // PNG: IHDR je uvijek prvi chunk
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return ok(u32be(16), u32be(20));
  // GIF87a / GIF89a
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return ok(u16le(6), u16le(8));
  // WebP (RIFF....WEBP): VP8 / VP8L / VP8X
  if (b[0] === 0x52 && b[1] === 0x49 && b[8] === 0x57 && b[9] === 0x45) {
    const fourcc = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (fourcc === "VP8 ") return ok(u16le(26) & 0x3fff, u16le(28) & 0x3fff);
    if (fourcc === "VP8L") {
      const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return ok((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
    }
    if (fourcc === "VP8X") return ok(u24le(24) + 1, u24le(27) + 1);
    return null;
  }
  // JPEG: prvi SOFn marker (preskače APPn/DQT/DHT…)
  if (b[0] === 0xff && b[1] === 0xd8) {
    let o = 2;
    while (o + 9 < b.length) {
      if (b[o] !== 0xff) return null;
      const m = b[o + 1];
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) {
        o += 2;
        continue;
      }
      const len = u16be(o + 2);
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
        return ok(u16be(o + 7), u16be(o + 5));
      }
      o += 2 + len;
    }
  }
  return null;
}
