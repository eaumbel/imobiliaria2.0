// Imobiliária 2.0 · Gestão comercial — service worker.
// Só cuida das notificações push (não guarda páginas em cache).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = {texto: e.data ? e.data.text() : ''}; }
  const titulo = d.titulo || 'Imobiliária 2.0';
  e.waitUntil((async () => {
    await self.registration.showNotification(titulo, {
      body: d.texto || '',
      icon: 'icone-192.png',
      badge: 'icone-192.png',
      tag: d.tag || undefined,
      renotify: !!d.tag,
      data: {card: d.card || '', nt: d.nt || ''}
    });
    try { if (self.navigator.setAppBadge && typeof d.naoLidas === 'number') d.naoLidas > 0 ? await self.navigator.setAppBadge(d.naoLidas) : await self.navigator.clearAppBadge(); } catch (err) {}
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const d = e.notification.data || {};
  const q = new URLSearchParams(); if (d.card) q.set('card', d.card); if (d.nt) q.set('nt', d.nt);
  const url = self.registration.scope + (q.toString() ? '?' + q : '');
  e.waitUntil((async () => {
    const abertas = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    const aba = abertas.find(c => c.url.startsWith(self.registration.scope));
    if (aba) {
      // o sistema já está aberto: leva para o card (ou abre o sininho) sem recarregar
      aba.postMessage({tipo: 'abrir', card: d.card || '', nt: d.nt || ''});
      try { await aba.focus(); } catch (err) {}
      return;
    }
    await self.clients.openWindow(url);
  })());
});
