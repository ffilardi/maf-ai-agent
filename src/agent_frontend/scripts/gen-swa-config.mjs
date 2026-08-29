// Generates public/staticwebapp.config.json (routing + security headers) before `vite build` copies public/ into dist/.
//
// The CSP has to name the backend origin — the SPA calls it with fetch (`connect-src`) and frames its attachment
// previews (`frame-src`) — and that origin only exists after `azd provision`. It arrives the same way the bundle's
// own copy does, through VITE_AGENT_BACKEND_URL, so this file is generated rather than checked in. Read it with
// Vite's own loader so the .env cascade (including the .env.production.local the azd prebuild hook writes) resolves
// identically to what the bundle bakes in.
import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEnv } from 'vite';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const mode = process.env.NODE_ENV === 'development' ? 'development' : 'production';

const backendUrl = loadEnv(mode, root, 'VITE_').VITE_AGENT_BACKEND_URL ?? '';
let backendOrigin = '';
if (backendUrl) {
  try {
    backendOrigin = new URL(backendUrl).origin;
  } catch {
    console.warn(`[swa-config] VITE_AGENT_BACKEND_URL is not a valid URL ("${backendUrl}"); omitting it from the CSP.`);
  }
} else {
  console.warn('[swa-config] VITE_AGENT_BACKEND_URL is unset; the CSP will allow same-origin only.');
}

const backend = backendOrigin ? ` ${backendOrigin}` : '';

const csp = [
  "default-src 'self'",
  "script-src 'self'",
  // Tailwind and the component styles emit inline <style>/style="" — required until that changes.
  "style-src 'self' 'unsafe-inline'",
  // data:/blob: cover Vite-inlined assets and any object URL the attachment viewer creates.
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  `connect-src 'self'${backend}`,
  // 'self' is the srcdoc HTML preview; the backend origin is the native <iframe> PDF/image path in AttachmentViewer.
  `frame-src 'self'${backend}`,
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "object-src 'none'",
].join('; ');

const config = {
  navigationFallback: {
    rewrite: '/index.html',
    exclude: ['/assets/*', '*.{css,js,ico,png,svg,woff,woff2}'],
  },
  globalHeaders: {
    'content-security-policy': csp,
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'strict-origin-when-cross-origin',
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
    'strict-transport-security': 'max-age=31536000; includeSubDomains',
  },
};

const target = resolve(root, 'public/staticwebapp.config.json');
writeFileSync(target, `${JSON.stringify(config, null, 2)}\n`);
console.log(`[swa-config] wrote ${target}${backendOrigin ? ` (backend origin: ${backendOrigin})` : ''}`);
