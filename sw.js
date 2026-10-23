var CACHE = 'painel-v3';
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

/* ---- notificações (Web Push) ---- */
function swIdb(uid) {
  return new Promise(function (res, rej) {
    var r = indexedDB.open('painel-keys', 1);
    r.onupgradeneeded = function () { r.result.createObjectStore('k'); };
    r.onerror = function () { rej(r.error); };
    r.onsuccess = function () {
      try {
        var q = r.result.transaction('k', 'readonly').objectStore('k').get(uid);
        q.onsuccess = function () { res(q.result); };
        q.onerror = function () { rej(q.error); };
      } catch (e) { rej(e); }
    };
  });
}
function swB64(t) { var r = atob(t), u = new Uint8Array(r.length); for (var i = 0; i < r.length; i++) u[i] = r.charCodeAt(i); return u; }
async function swDecrypt(key, p) {
  var pt = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: swB64(p.iv) }, key, swB64(p.ct)));
  return new TextDecoder().decode(pt);
}
async function handlePush(e) {
  var d = {}, title = 'Painel da Vida', body = '', tag = '', url = './';
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = {}; }
  if (d.p && d.u) {
    try {
      var rec = await swIdb(d.u);
      var j = JSON.parse(await swDecrypt(rec.key, d.p));
      title = j.t || title; body = j.b || ''; tag = j.g || ''; url = j.x || './';
    } catch (err) { title = 'Lembrete'; body = 'Abra o Painel da Vida para ver.'; }
  } else { title = d.t || title; body = d.b || ''; tag = d.g || ''; url = d.x || './'; }
  var opts = { body: body, icon: 'icon-192.png', badge: 'icon-192.png', data: { url: url } };
  if (tag) { opts.tag = tag; opts.renotify = true; }
  await self.registration.showNotification(title, opts);
}
self.addEventListener('push', function (e) { e.waitUntil(handlePush(e)); });
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cs) {
    for (var i = 0; i < cs.length; i++) { if ('focus' in cs[i]) { try { cs[i].navigate && cs[i].navigate(url); } catch (err) {} return cs[i].focus(); } }
    return self.clients.openWindow(url);
  }));
});
