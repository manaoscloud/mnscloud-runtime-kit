/* mnscloud-pwa-register v1: appended by mnscloud-runtime-kit scripts/flutter-pwa.py. */
(function () {
  'use strict';
  if (!('serviceWorker' in navigator) || !window.isSecureContext) return;

  // Paths resolve against <base href>, so the same bundle works at / and under /<app>/.
  var ready = navigator.serviceWorker
    .register('sw.js', { scope: './', updateViaCache: 'none' })
    .catch(function (error) {
      console.warn('[mnscloud-pwa] service worker registration failed', error);
      return null;
    });

  function reload() {
    window.location.reload();
  }

  // Called by the app's new-version notice ("Update now"): activates the waiting revision and
  // reloads once it controls the page. Never called automatically.
  function applyUpdate() {
    return ready.then(function (registration) {
      if (!registration) return reload();
      return registration.update().catch(function () {}).then(function () {
        var worker = registration.waiting || registration.installing;
        if (!worker) return reload();
        return new Promise(function (resolve) {
          var finished = false;
          function finish() {
            if (finished) return;
            finished = true;
            reload();
            resolve();
          }
          function activate() {
            worker.postMessage({ type: 'MNSCLOUD_PWA_SKIP_WAITING' });
          }
          navigator.serviceWorker.addEventListener('controllerchange', finish);
          window.setTimeout(finish, 15000);
          if (worker.state === 'installed') {
            activate();
          } else {
            worker.addEventListener('statechange', function () {
              if (worker.state === 'installed') activate();
              if (worker.state === 'redundant') finish();
            });
          }
        });
      });
    });
  }

  // Asks the browser to keep this origin's storage (offline data) under storage pressure.
  function persistStorage() {
    if (!navigator.storage || !navigator.storage.persist) return Promise.resolve(false);
    return navigator.storage.persist().catch(function () { return false; });
  }

  window.mnscloudPwa = { version: 1, ready: ready, applyUpdate: applyUpdate, persistStorage: persistStorage };
})();
