// Nexmem Web 端 E2E 配置（X-05）。
// 使用本机已安装的 Chrome（channel: chrome），不额外下载浏览器。
const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 240000,
  expect: { timeout: 25000 },
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],
  use: {
    ...devices['Desktop Chrome'],
    // 默认使用 Playwright 自带 Chromium（CI 无需预装 Chrome）；本机可设
    // PW_CHANNEL=chrome 复用已安装的 Chrome（Windows 本地实测即如此）。
    ...(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {}),
    headless: true,
    viewport: { width: 430, height: 900 },
    // Playwright 1.65 在 Windows 下关闭上下文时偶发 trace 网络副本 copyfile ENOENT，
    // 会污染用例结果；保留失败截图，关闭 trace 录制。
    trace: 'off',
    screenshot: 'only-on-failure',
    video: 'off',
  },
});
