// Cache para que la app funcione sin internet. Subir VERSION al cambiar archivos.
const VERSION = 'comandera-v9';
const FILES = ['./', 'index.html', 'style.css', 'app.js', 'api.js', 'config.js', 'printer.js', 'manifest.webmanifest', 'icon.svg'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// Primero busca la versión nueva en internet (así los arreglos llegan enseguida a las cajas);
// si no hay señal o tarda más de 4 segundos, usa la copia guardada.
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(caches.open(VERSION).then(async cache => {
    const fresh = fetch(e.request, { cache: 'no-cache' }).then(r => {
      if (r.ok) cache.put(e.request, r.clone());
      return r;
    });
    const timeout = new Promise((_, reject) => setTimeout(reject, 4000));
    try {
      return await Promise.race([fresh, timeout]);
    } catch {
      return (await cache.match(e.request)) || fresh;
    }
  }));
});
