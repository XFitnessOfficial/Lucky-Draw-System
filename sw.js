/* Minimal service worker.
   Chrome will not offer "Install app" without one that handles fetch, so this
   exists purely for that. It caches nothing — a cached admin.html would keep
   serving an old build after a deploy, which on a scanner is far worse than
   having no offline mode.

   It also refuses to touch anything it does not have to: only same-origin GET
   requests are passed through. Cross-origin scripts, fonts and API calls are
   left entirely to the browser, so the worker can never be the reason a
   third-party file fails to load. */
self.addEventListener('install',  () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  let url;
  try { url = new URL(e.request.url); } catch (err) { return; }
  if (url.origin !== self.location.origin) return;
  e.respondWith(fetch(e.request));
});
