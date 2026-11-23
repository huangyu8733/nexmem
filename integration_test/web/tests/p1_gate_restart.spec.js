// P1 阶段门禁（本地可复现部分）：杀进程重启后消息完整。
// 流程：两端互发文本 → taskkill 强制杀接收端进程 → 复用同一数据目录重启
// → 校验账号/设备身份不变、历史逐条完整且不重复 → 重启后仍可继续收发。
const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const { Stack, conversationIdOf } = require('../support/stack');

let stack;

test.describe.configure({ mode: 'serial' });

// 端到端含两次进程重启与重试补发，放宽单用例时限。
test.setTimeout(600000);

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// occurrences 统计指定正文在消息列表中的出现次数，用于判定「不丢不重」。
function occurrences(items, text) {
  return (items || []).filter((item) => item.text === text).length;
}

test.beforeAll(async () => {
  const runDir = path.join(__dirname, '..', '.run', `gate-${Date.now()}`);
  fs.mkdirSync(runDir, { recursive: true });
  stack = new Stack(runDir);
  try {
    await stack.start();
    // 预热：确认单聊链路可达，避免首次 DHT 寻址超时影响杀进程用例的时序。
    const deadline = Date.now() + 90000;
    let lastError = '';
    while (Date.now() < deadline) {
      try {
        await stack.call(stack.ports.webA, stack.tokens.a, 'dm.sendText', {
          peer: stack.accountB.account_id,
          text: 'P1门禁预热',
        });
        await stack.waitMessage(
          stack.ports.webB,
          stack.tokens.b,
          stack.accountB.account_id,
          stack.accountA.account_id,
          'P1门禁预热',
          10000,
        );
        break;
      } catch (err) {
        lastError = err.message;
        await wait(3000);
      }
    }
    if (Date.now() >= deadline) {
      throw new Error(`双端单聊预热失败：${lastError}`);
    }
  } catch (err) {
    await stack.stop();
    throw err;
  }
});

test.afterAll(async () => {
  if (stack) {
    await stack.stop();
  }
});

test('杀进程重启后消息完整、身份不变且可继续收发', async () => {
  const conv = conversationIdOf(stack.accountA.account_id, stack.accountB.account_id);
  const marker = `P1门禁重启-${Date.now()}`;
  const texts = Array.from({ length: 5 }, (_, i) => `${marker}-${i}`);

  // 1) 重启前：A → B 发送 5 条并确认全部到达。
  for (const text of texts) {
    await stack.call(stack.ports.webA, stack.tokens.a, 'dm.sendText', {
      peer: stack.accountB.account_id,
      text,
    });
    await stack.waitMessage(
      stack.ports.webB,
      stack.tokens.b,
      stack.accountB.account_id,
      stack.accountA.account_id,
      text,
      45000,
    );
  }
  const before = await stack.call(stack.ports.webB, stack.tokens.b, 'msg.list', {
    conversation_id: conv,
    limit: 200,
  });
  for (const text of texts) {
    expect(occurrences(before.items, text)).toBe(1);
  }
  const beforeTotal = (before.items || []).length;

  // 2) 强制杀进程（taskkill /f）后复用同一数据目录重启接收端。
  const restarted = await stack.restartWebNode('b');
  expect(restarted.account_id).toBe(stack.accountB.account_id);
  expect(restarted.device_id).toBe(stack.accountB.device_id);

  // 3) 重启后：历史逐条完整且不重复。
  const after = await stack.call(stack.ports.webB, stack.tokens.b, 'msg.list', {
    conversation_id: conv,
    limit: 200,
  });
  for (const text of texts) {
    expect(occurrences(after.items, text)).toBe(1);
  }
  expect((after.items || []).length).toBe(beforeTotal);

  // 4) 重启后仍可继续收发：直连未立刻恢复时由离线队列补发，给足重试窗口。
  const resumed = `${marker}-after`;
  const sent = await stack.call(stack.ports.webA, stack.tokens.a, 'dm.sendText', {
    peer: stack.accountB.account_id,
    text: resumed,
  });
  await stack.waitMessage(
    stack.ports.webB,
    stack.tokens.b,
    stack.accountB.account_id,
    stack.accountA.account_id,
    resumed,
    120000,
  );
  const resumedHistory = await stack.call(stack.ports.webB, stack.tokens.b, 'msg.list', {
    conversation_id: conv,
    limit: 200,
  });
  expect(occurrences(resumedHistory.items, resumed)).toBe(1);
  console.log(`P1_GATE_RESUMED_MSG=${JSON.stringify(sent)}`);

  // 5) 发送端杀进程重启后，自身出站历史同样完整且身份不变。
  const senderRestarted = await stack.restartWebNode('a');
  expect(senderRestarted.account_id).toBe(stack.accountA.account_id);
  expect(senderRestarted.device_id).toBe(stack.accountA.device_id);
  const senderHistory = await stack.call(stack.ports.webA, stack.tokens.a, 'msg.list', {
    conversation_id: conv,
    limit: 200,
  });
  for (const text of [...texts, resumed]) {
    const sent = (senderHistory.items || []).filter(
      (item) => item.text === text && item.direction === 'out',
    );
    expect(sent).toHaveLength(1);
  }

  console.log(
    `P1_GATE_RESTART=PASS messages=${texts.length} before=${beforeTotal} after=${(after.items || []).length}`,
  );
});
