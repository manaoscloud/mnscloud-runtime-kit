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

  // Install ("Install app" button of the client). Chromium browsers offer a prompt the app can
  // open itself; iOS/iPadOS Safari only installs from Share > Add to Home Screen, so the app shows
  // those steps instead.
  var installPrompt = null;
  var installListeners = [];
  function notifyInstall() {
    var state = installState();
    installListeners.forEach(function (listener) {
      try { listener(state); } catch (error) { console.warn('[mnscloud-pwa] install listener', error); }
    });
  }
  window.addEventListener('beforeinstallprompt', function (event) {
    event.preventDefault();
    installPrompt = event;
    notifyInstall();
  });
  window.addEventListener('appinstalled', function () {
    installPrompt = null;
    notifyInstall();
  });

  function isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches ||
      window.matchMedia('(display-mode: window-controls-overlay)').matches ||
      window.navigator.standalone === true;
  }

  function isAppleMobile() {
    var ua = window.navigator.userAgent;
    return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && window.navigator.maxTouchPoints > 1);
  }

  // installed | available (prompt ready) | ios (manual steps) | unavailable
  function installState() {
    if (isStandalone()) return 'installed';
    if (installPrompt) return 'available';
    if (isAppleMobile()) return 'ios';
    return 'unavailable';
  }

  // Opens the browser install prompt; resolves accepted | dismissed | unavailable.
  function promptInstall() {
    if (!installPrompt) return Promise.resolve('unavailable');
    var pending = installPrompt;
    installPrompt = null;
    pending.prompt();
    return pending.userChoice
      .then(function (choice) { return choice.outcome; })
      .catch(function () { return 'dismissed'; })
      .then(function (outcome) { notifyInstall(); return outcome; });
  }

  function onInstallChange(listener) {
    if (typeof listener === 'function') installListeners.push(listener);
  }

  // Web Push. Permission is asked only from a user action of the app; subscriptions are returned
  // as the PushSubscription JSON string the app sends to its API.
  function pushSupported() {
    return 'PushManager' in window && 'Notification' in window;
  }

  // unsupported | default | granted | denied (iOS needs the app installed on the home screen).
  function pushPermission() {
    return pushSupported() ? Notification.permission : 'unsupported';
  }

  function decodeKey(base64Url) {
    var normalized = String(base64Url).replace(/-/g, '+').replace(/_/g, '/');
    var raw = window.atob(normalized + '='.repeat((4 - normalized.length % 4) % 4));
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  function sameKey(subscription, key) {
    var current = subscription.options && subscription.options.applicationServerKey;
    if (!current) return false;
    var bytes = new Uint8Array(current);
    if (bytes.length !== key.length) return false;
    for (var i = 0; i < key.length; i++) if (bytes[i] !== key[i]) return false;
    return true;
  }

  function serialize(subscription) {
    return subscription ? JSON.stringify(subscription.toJSON()) : null;
  }

  // Resolves the subscription JSON, or null when unsupported or not allowed.
  function subscribePush(publicKey) {
    if (!pushSupported()) return Promise.resolve(null);
    return Notification.requestPermission().then(function (permission) {
      if (permission !== 'granted') return null;
      return ready.then(function (registration) {
        if (!registration) return null;
        var key = decodeKey(publicKey);
        return registration.pushManager.getSubscription().then(function (existing) {
          if (existing && sameKey(existing, key)) return existing;
          var cleared = existing ? existing.unsubscribe().catch(function () { return false; }) : Promise.resolve(true);
          return cleared.then(function () {
            return registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
          });
        });
      });
    }).then(serialize).catch(function (error) {
      console.warn('[mnscloud-pwa] push subscription failed', error);
      return null;
    });
  }

  // The current subscription JSON of this browser, or null.
  function currentPush() {
    if (!pushSupported()) return Promise.resolve(null);
    return ready.then(function (registration) {
      return registration ? registration.pushManager.getSubscription() : null;
    }).then(serialize).catch(function () { return null; });
  }

  // Unsubscribes this browser; resolves the endpoint that was removed, or null.
  function unsubscribePush() {
    if (!pushSupported()) return Promise.resolve(null);
    return ready.then(function (registration) {
      return registration ? registration.pushManager.getSubscription() : null;
    }).then(function (subscription) {
      if (!subscription) return null;
      var endpoint = subscription.endpoint;
      return subscription.unsubscribe().then(function () { return endpoint; });
    }).catch(function () { return null; });
  }

  var notificationListeners = [];
  if (navigator.serviceWorker) {
    navigator.serviceWorker.addEventListener('message', function (event) {
      var data = event.data || {};
      if (data.type !== 'MNSCLOUD_PWA_NOTIFICATION_CLICK') return;
      notificationListeners.forEach(function (listener) {
        try { listener(String(data.url || '')); } catch (error) { console.warn('[mnscloud-pwa] notification listener', error); }
      });
    });
  }

  // listener(url) runs when the user clicks a notification of this app while it is open.
  function onNotificationClick(listener) {
    if (typeof listener === 'function') notificationListeners.push(listener);
  }

  window.mnscloudPwa = {
    version: 1,
    ready: ready,
    applyUpdate: applyUpdate,
    persistStorage: persistStorage,
    installState: installState,
    promptInstall: promptInstall,
    onInstallChange: onInstallChange,
    pushPermission: pushPermission,
    subscribePush: subscribePush,
    currentPush: currentPush,
    unsubscribePush: unsubscribePush,
    onNotificationClick: onNotificationClick
  };
})();
