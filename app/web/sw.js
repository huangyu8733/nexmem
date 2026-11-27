// Nexmem Web 唤醒通知 Service Worker。
//
// 服务端只推送空的「有新消息」信号（VAPID 空载荷，不携带正文/发送者/会话），
// 这里显示一条通用通知；点击后把 open 消息 postMessage 给页面，
// 由 Flutter 侧解析 conversationId 并打开对应会话。
// 未配置 VAPID 时本文件不会被订阅，但仍可注册，不产生任何通知。

self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function (event) {
  var payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (e) {
    payload = {};
  }
  var conversationId = payload.conversationId || '';
  event.waitUntil(
    self.registration.showNotification('Nexmem', {
      body: '你有一条新消息，点击查看详情',
      tag: 'nexmem-' + conversationId,
      data: { conversationId: conversationId },
    }),
  );
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var conversationId =
    (event.notification.data && event.notification.data.conversationId) || '';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then(function (clients) {
        for (var i = 0; i < clients.length; i++) {
          clients[i].postMessage({
            type: 'open',
            conversationId: conversationId,
          });
          return clients[i].focus();
        }
        if (self.clients.openWindow) {
          return self.clients.openWindow('/');
        }
      }),
  );
});
