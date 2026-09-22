/* SwapSpot service worker.
   Its only job is push. There is deliberately no offline caching: the app is
   one HTML file that changes often, and a cache here would serve testers a
   stale build long after a fix shipped. */

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// Present so browsers that still require a fetch handler treat the app as
// installable. It intentionally does nothing, so every request goes to the
// network exactly as it would without a service worker.
self.addEventListener('fetch', () => {});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (e) {
    payload = { title: 'SwapSpot', body: event.data ? event.data.text() : '' };
  }
  const title = payload.title || 'SwapSpot';
  const options = {
    body: payload.body || '',
    icon: 'media/icon-192.png',
    badge: 'media/icon-192.png',
    // collapses repeats of the same swap rather than stacking them
    tag: payload.tag || 'swapspot',
    data: { url: payload.url || './' },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || './';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      // focus an open tab if there is one, rather than opening a second copy
      for (const client of list) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
