var CACHE = 'painel-2026-10-29.173200';
var SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png'];
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); })); }).then(function () { return self.clients.claim(); }));
});
/* rede primeiro, sempre revalidando (pega atualizações na hora); sem internet, usa o que foi guardado */
self.addEventListener('fetch', function (e) {
  if (e.request.method !== 'GET') return;
  var same = new URL(e.request.url).origin === self.location.origin;
  e.respondWith((same ? fetch(e.request.url, { cache: 'no-cache' }) : fetch(e.request)).then(function (res) {
    var copy = res.clone();
    caches.open(CACHE).then(function (c) { c.put(e.request, copy); }).catch(function () {});
    return res;
  }).catch(function () { return caches.match(e.request, { ignoreSearch: true }).then(function (r) { return r || caches.match('index.html'); }); }));
});

