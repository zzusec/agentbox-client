import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export async function smoke(page) {
  page.setDefaultTimeout(15000);
  const root = fileURLToPath(new URL('../internal/web/static/', import.meta.url));
  const server = createServer(async (request, response) => {
    try {
      const relative = decodeURIComponent(request.url.split('?')[0]).replace(/^\/_v\/[^/]+/, '');
      const path = resolve(root, '.' + (relative === '/' ? '/index.html' : relative));
      if (!path.startsWith(root)) { response.writeHead(403).end(); return; }
      response.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' })[extname(path)] || 'application/octet-stream');
      response.end(await readFile(path));
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const base = `http://127.0.0.1:${server.address().port}`;
  const errors = [], writes = [], terminalURLs = [], filePaths = [];
  const claudeAccount = { id: 'fixture-account', type: 'claude', label: '开发账号', sessions: 2, cred_status: 'ok' };
  const codexAccount = { id: 'fixture-codex', type: 'codex', label: 'Codex 备用', sessions: 1, cred_status: 'ok' };
  // One account, one instance: this one already belongs to an instance.
  const takenAccount = { id: 'fixture-taken', type: 'claude', label: '已占用账号', sessions: 1, cred_status: 'ok', bound: true, bound_instance: '产品开发' };
  const residentialProxy = { id: 'fixture-proxy', name: '住宅出口', kind: 'residential' };
  const datacenterProxy = { id: 'fixture-dc', name: '机房出口', kind: 'datacenter' };
  const makeSession = (id, over) => ({
    id, user: 'fixture', agent: 'claude',
    account_id: claudeAccount.id, account_label: claudeAccount.label,
    claude_account_id: claudeAccount.id, codex_account_id: '',
    claude_account_label: claudeAccount.label, codex_account_label: '',
    proxy_id: residentialProxy.id, proxy_label: residentialProxy.name,
    default_agent: 'claude', default_model: 'fixture',
    workspace_path: `/srv/agentbox/data/users/fixture/sessions/${id}/workspace`,
    container_id: '', status: 'stopped', stop_reason: '',
    created_at: '2026-09-30T10:00:00Z', updated_at: '2026-09-30T10:00:00Z',
    ...over,
  });
  let sessions = [
    makeSession('fixture-space', { name: '产品开发', container_id: 'fixture-container-a', status: 'running' }),
    // 默认工具是 Codex、但同时绑定了 Claude：技能/MCP 页签必须按绑定账号判定而仍然可用。
    makeSession('fixture-second', { name: '内部工具', agent: 'codex', default_agent: 'codex', container_id: 'fixture-container-b', codex_account_id: codexAccount.id, codex_account_label: codexAccount.label }),
    makeSession('fixture-third', { name: '纯 Codex', agent: 'codex', default_agent: 'codex', claude_account_id: '', claude_account_label: '', codex_account_id: codexAccount.id, codex_account_label: codexAccount.label }),
  ];
  const project = (id, name, agent = '') => ({ id, name, agent, path: `/srv/agentbox/data/users/fixture/sessions/fixture-space/workspace/${name}`, created_at: '2026-09-30T10:00:00Z', updated_at: '2026-09-30T10:00:00Z' });
  const projects = {
    'fixture-space': [project('fixture-project', '订单服务 + API')],
    'fixture-second': [project('fixture-other', '运营后台')],
  };
  let failList = false, failCreate = false, holdList = false, releaseList;
  // 实例资源：第一帧故意给 window_ms=0（前端必须显示「测量中」而不是 0），
  // 之后给有效窗口；磁盘第一帧标 stale，验证「统计中」不会被当成 0。
  // 网络计数器逐帧增长；netRestart 置位后的那一帧把计数器打回去，模拟容器重启。
  let statsReads = 0;
  let failStats = false;
  let netRx = 4 * 1024 * 1024, netTx = 1024 * 1024, netRestart = false;
  const statsItems = now => sessions.map(session => ({
    session_id: session.id, name: session.name, agent: session.agent,
    running: session.status === 'running', proxy_bound: !!session.proxy_id,
    cpu_percent: session.status === 'running' ? 42 : 0,
    mem_usage: session.status === 'running' ? 512 * 1024 * 1024 : 0,
    mem_limit: 2 * 1024 * 1024 * 1024,
    pids: session.status === 'running' ? 7 : 0,
    disk_bytes: 3 * 1024 * 1024, disk_stale: statsReads <= 1,
    net_rx_bytes: netRx, net_tx_bytes: netTx,
    started_at: session.status === 'running' ? now - 60000 : 0,
  }));
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    if (window !== window.top || sessionStorage.getItem('agentbox_test_projects_seeded')) return;
    localStorage.setItem('agentbox_token', 'synthetic-project-token');
    sessionStorage.setItem('agentbox_test_projects_seeded', '1');
  });
  await page.routeWebSocket('**/api/sessions/*/term?*', socket => { terminalURLs.push(socket.url()); });
  await page.routeWebSocket('**/api/sessions/*/chat?*', () => {});
  await page.route('**/api/**', async route => {
    const request = route.request(), url = new URL(request.url()), path = url.pathname, method = request.method();
    if (method !== 'GET') writes.push({ path, method, body: request.postDataJSON() });
    let body = {};
    if (path === '/api/me') body = { user: 'fixture', role: 'user', timezone: 'UTC', models: { claude: [], codex: [] }, quota: { metered: false } };
    else if (path === '/api/accounts') body = [claudeAccount, codexAccount, takenAccount];
    // 普通用户可读的最小代理选项：只有 id/name/kind，没有地址或凭证。
    else if (path === '/api/instances/proxies') body = [residentialProxy, datacenterProxy];
    else if (path === '/api/instances/stats') {
      statsReads++;
      if (failStats) { await route.fulfill({ status: 503, json: { error: '合成采样失败' } }); return; }
      if (netRestart) { netRx = 1024; netTx = 512; netRestart = false; }
      else { netRx += 512 * 1024; netTx += 256 * 1024; }
      const now = Date.now();
      body = { now, window_ms: statsReads > 1 ? 5000 : 0, items: statsItems(now) };
    }
    else if (path === '/api/sessions') {
      if (method === 'POST') {
        const input = request.postDataJSON();
        body = makeSession('fixture-created', { ...input, name: input.name, status: 'stopped', container_id: '' });
        body.account_id = input.claude_account_id || input.codex_account_id;
        sessions.push(body); projects[body.id] = [];
      } else body = sessions;
    } else if (path.endsWith('/projects')) {
      const sessionID = path.split('/')[3];
      if (holdList) { holdList = false; await new Promise(done => { releaseList = done; }); }
      if ((failList && sessionID === 'fixture-second') || (failCreate && method === 'POST')) {
        await route.fulfill({ status: 409, json: { error: method === 'POST' ? '项目名称已存在' : '合成列表读取失败' } }); return;
      }
      if (method === 'POST') {
        body = project('fixture-new', request.postDataJSON().name, request.postDataJSON().agent || '');
        projects[sessionID].push(body);
      } else body = projects[sessionID] || [];
    } else if (path.includes('/projects/')) {
      // 项目设置（PATCH）：把 agent 落到夹具里，复读时才看得到效果。
      const sessionID = path.split('/')[3], projectID = path.split('/')[5];
      const input = request.postDataJSON();
      const row = (projects[sessionID] || []).find(item => item.id === projectID);
      if (row) { row.name = input.name; row.agent = input.agent || ''; }
      body = row || project(projectID, input.name, input.agent || '');
    } else if (path.endsWith('/files')) { filePaths.push(url.searchParams.get('path')); body = []; }
    else if (path.endsWith('/history')) body = { entries: [], thread: null, costs: {} };
    else if (path.endsWith('/models')) body = { models: [], default_reasoning: { support: 'unknown' } };
    else if (path === '/api/git/connections') body = [];
    else if (path === '/api/me/git/default') body = { connection_id: '' };
    else if (path === '/api/tunnel/status') body = { enabled: false };
    else if (path === '/api/usage/events') body = { rows: [], total: { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, cost_micro_usd: 0 } };
    await route.fulfill({ json: body });
  });
  const refresh = () => page.evaluate(async () => { const { refreshAll } = await import('/_v/{{BUILD}}/js/data.js'); await refreshAll(); });
  const choose = async (selectID, label) => {
    await page.locator(`#${selectID} + .select-trigger`).click();
    await page.locator('.select-panel:popover-open [role=option]').filter({ hasText: label }).click();
  };
  // 精确匹配：像「跟随实例默认（Claude Code）」这种选项会把宽松匹配也命中，
  // 点上就会因为 strict mode 报错。
  const chooseExact = async (selectID, label) => {
    await page.locator(`#${selectID} + .select-trigger`).click();
    await page.locator('.select-panel:popover-open [role=option]').filter({ hasText: new RegExp(`^${label}$`) }).click();
  };
  try {
    await page.setViewportSize({ width: 1440, height: 960 });
    await page.goto(base + '/#/');
    await page.waitForFunction(() => document.querySelectorAll('.project-tile').length === 2);
    assert.equal(await page.locator('.sidebar-instance').count(), 3);
    assert.equal(await page.locator('.sidebar-project').count(), 2);
    assert.equal(await page.locator('#btn-workspaces').innerText(), '实例管理');
    assert.equal(await page.locator('.side-nav[aria-label="工具"] #btn-usagelog').count(), 1);
    assert.equal(await page.locator('.side-nav[aria-label="系统管理"] #btn-settings').count(), 1);
    const firstInstance = page.locator('.sidebar-instance[data-session-id="fixture-space"]');
    assert.equal(await firstInstance.locator('[data-sidebar-project-id="fixture-project"]').count(), 1);
    await firstInstance.locator('summary').focus();
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => !document.querySelector('.sidebar-instance[data-session-id="fixture-space"]').open);
    await refresh();
    assert.equal(await firstInstance.evaluate(element => element.open), false, 'refresh preserves collapsed instance');
    await firstInstance.locator('summary').click();
    await page.waitForFunction(() => document.querySelector('.sidebar-instance[data-session-id="fixture-space"]').open);
    assert.equal(await page.locator('#empty-new').innerText(), '新建项目');
    // The sidebar no longer carries its own create button; the page header does.
    assert.equal(await page.locator('#btn-new').count(), 0, 'sidebar create button must stay removed');
    assert.equal(await page.locator('#btn-settings').isVisible(), false);
    assert.equal(await page.locator('#btn-projects').getAttribute('aria-current'), 'page');
    assert.deepEqual(writes, [], 'home must not mutate resources');
    // 顶栏是唯一一条：品牌、主题、账号各只出现一次，侧栏里不再有第二套。
    assert.equal(await page.locator('.topbar-brand').count(), 1);
    assert.equal(await page.locator('.side-head .topbar-brand, .sidebar .topbar-brand').count(), 0, 'brand must not be duplicated in the sidebar');
    assert.equal(await page.locator('#btn-menu').isVisible(), false, 'desktop has no drawer to open');
    assert.equal(await page.locator('.topbar .theme-options button').count(), 3);
    assert.equal(await page.locator('.sidebar .theme-options').count(), 0, 'theme must live in the topbar only');
    assert.equal(await page.locator('#btn-user-menu').count(), 1);
    await page.locator('#project-search').fill('订单');
    assert.equal(await page.locator('.project-tile').count(), 1);
    await page.locator('#project-search').fill('not-found');
    assert.equal(await page.locator('#project-empty-title').innerText(), '没有匹配的项目');
    await page.locator('#project-search').fill('');
    await choose('project-filter', '内部工具');
    assert.equal(await page.locator('.project-tile').count(), 1);
    assert.match(await page.locator('.project-tile').innerText(), /运营后台/);
    await choose('project-filter', '全部实例');
    // 项目卡显示它自己的开发工具；没设过就跟随实例默认。
    assert.match(await page.locator('[data-project-id="fixture-project"]').innerText(), /Claude Code（默认）/);
    await mkdir(resolve('output/playwright'), { recursive: true });
    await page.screenshot({ animations: 'disabled', path: resolve('output/playwright/projects-desktop-light.png') });

    await page.locator('#empty-new').click();
    await choose('project-workspace', '内部工具');
    await page.locator('#project-name').fill('.invalid');
    await page.locator('#project-ok').click();
    await page.locator('#project-error').waitFor({ state: 'visible' });
    assert.deepEqual(writes, []);
    // 服务器目录提示必须如实：给出真实绝对路径，并说明本机映射还没实现。
    await page.locator('#project-name').fill('新项目');
    const pathHint = await page.locator('#project-path-hint').innerText();
    assert.match(pathHint, /\/srv\/agentbox\/data\/users\/fixture\/sessions\/fixture-second\/workspace\/新项目/);
    assert.match(pathHint, /本机目录映射尚未实现/);
    assert.equal(await page.locator('#project-path-hint input').count(), 0, 'path must not be an editable input');
    failCreate = true;
    await page.locator('#project-ok').click();
    await page.waitForFunction(() => document.querySelector('#project-error').textContent === '项目名称已存在');
    assert.equal(await page.locator('#dlg-project').evaluate(dialog => dialog.open), true);
    failCreate = false;
    await page.locator('#project-ok').click();
    await page.locator('#dlg-project').waitFor({ state: 'hidden' });
    await page.waitForFunction(() => document.querySelectorAll('.project-tile').length === 3);
    assert.deepEqual(writes.map(write => write.path), ['/api/sessions/fixture-second/projects', '/api/sessions/fixture-second/projects']);
    // agent 是项目自己的工具选择，空 = 跟随实例默认。
    assert.deepEqual(writes.at(-1).body, { name: '新项目', agent: '' });

    // 项目设置：工具只列实例绑定过的，保存走 PATCH。
    await page.locator('[data-project-settings="fixture-project"]').click();
    await page.locator('#dlg-project').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#project-title').innerText(), '项目设置');
    assert.equal(await page.locator('#project-workspace-field').isVisible(), false, 'a project cannot change its instance');
    await chooseExact('project-agent', 'Claude Code');
    await page.locator('#project-ok').click();
    await page.locator('#dlg-project').waitFor({ state: 'hidden' });
    assert.equal(writes.at(-1).method, 'PATCH');
    assert.equal(writes.at(-1).path, '/api/sessions/fixture-space/projects/fixture-project');
    assert.deepEqual(writes.at(-1).body, { name: '订单服务 + API', agent: 'claude' });

    await page.locator('#btn-workspaces').click();
    await page.waitForURL('**/#/workspaces');
    assert.equal(await page.locator('#btn-workspaces').getAttribute('aria-current'), 'page');
    assert.equal(await page.locator('#btn-projects').getAttribute('aria-current'), null);
    assert.equal(await page.locator('.workspace-tile').count(), 3);
    assert.equal(await page.locator('#workspace-accounts').innerText(), '2', 'claude + codex bindings are counted separately');
    assert.equal(await page.locator('#workspace-total').innerText(), '3');
    assert.equal(await page.locator('#workspace-running').innerText(), '1');
    assert.equal(await page.locator('#workspace-stopped').innerText(), '2');
    assert.equal(await page.locator('#workspace-created').innerText(), '2');
    assert.equal(await page.locator('#workspace-pending').innerText(), '1');
    assert.equal(await page.locator('#workspace-proxy-missing').innerText(), '0');
    const firstTile = page.locator('.workspace-tile').first();
    assert.match(await firstTile.innerText(), /fixture-container-a/);
    assert.match(await firstTile.innerText(), /开发账号/, 'the bound claude account is listed');
    assert.match(await firstTile.innerText(), /住宅出口/, 'the instance proxy is listed');
    assert.match(await firstTile.innerText(), /\/srv\/agentbox\/data\/users\/fixture\/sessions\/fixture-space\/workspace/, 'the server workspace path is listed');
    // 第一帧 window_ms=0：CPU/网络必须显示「测量中」，磁盘必须是「统计中」，而不是 0。
    await firstTile.locator('dl.workspace-usage').waitFor();
    await page.waitForFunction(() => {
      const usage = document.querySelector('.workspace-tile dl.workspace-usage');
      return !!usage && usage.innerText.includes('统计中');
    });
    const usageText = await firstTile.locator('dl.workspace-usage').innerText();
    assert.match(usageText, /CPU\s+测量中/);
    assert.match(usageText, /磁盘\s+统计中/);
    assert.equal(await page.locator('#workspace-cpu').innerText(), '测量中');
    assert.equal(await page.locator('#workspace-disk').innerText(), '统计中');
    assert.equal(await page.locator('#workspace-memory').innerText(), '512 MB');
    assert.equal(await page.locator('#workspace-pids').innerText(), '7');
    assert.match(usageText, /运行时间\s+1 分钟/);
    await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base });
    await firstTile.getByRole('button', { name: '复制容器 ID' }).click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), 'fixture-container-a');
    await page.keyboard.press('Tab');
    await page.locator('.instance-help').focus();
    await page.locator('#tip:popover-open').waitFor();
    assert.match(await page.locator('#tip').innerText(), /CPU 按单核计量/);
    await page.locator('.instance-help').evaluate(element => element.blur());
    assert.doesNotMatch(await page.locator('.workspace-tile').nth(1).locator('dl.workspace-usage').innerText(), /CPU\s+\d/, 'stopped instance must not show a number');
    await page.locator('#toast.show').waitFor({ state: 'hidden' });
    await page.screenshot({ animations: 'disabled', path: resolve('output/playwright/workspaces-desktop-light.png') });

    // 离开实例视图必须停止轮询（否则没人看的页面会一直打服务端）。
    await page.goto(base + '/#/');
    await page.locator('.project-tile').first().waitFor();
    const readsWhileAway = statsReads;
    await page.waitForTimeout(5500);
    assert.equal(statsReads, readsWhileAway, 'resource polling must stop after leaving the instances view');
    // 回来立即重新采样一次，这次窗口有效，CPU 不再停在「测量中」。
    await page.goto(base + '/#/workspaces');
    await page.waitForFunction(() => document.querySelectorAll('#workspace-grid .workspace-tile').length === 3);
    await page.waitForFunction(() => {
      const usage = document.querySelector('.workspace-tile dl.workspace-usage');
      return !!usage && !usage.textContent.includes('测量中') && usage.textContent.includes('%');
    });
    await page.screenshot({ animations: 'disabled', path: resolve('output/playwright/workspaces-live-desktop-light.png') });

    assert.equal(await page.locator('#workspace-cpu').innerText(), '42.0%');
    assert.equal(await page.locator('#workspace-disk').innerText(), '9.0 MB');
    const usageBeforeFailure = await firstTile.locator('dl.workspace-usage').innerText();
    failStats = true;
    await page.locator('#workspace-refresh').click();
    await page.waitForFunction(() => document.querySelector('#workspace-sample-badge').textContent === '采样失败');
    assert.match(await page.locator('#workspace-sample-status').innerText(), /保留上次读数/);
    assert.equal(await firstTile.locator('dl.workspace-usage').innerText(), usageBeforeFailure);
    assert.equal(await page.locator('#workspace-refresh').isDisabled(), false);
    failStats = false;
    await page.locator('#workspace-refresh').click();
    await page.waitForFunction(() => document.querySelector('#workspace-sample-badge').textContent === '实时采样');

    // 容器重启后计数器回退：那一帧网络必须显示「测量中」，下一帧恢复速率。
    // 不能把负差压成 ↓ 0 B/s，也不能拿「真计数 − 失败帧的 0」冒充峰值。
    netRestart = true;
    await page.waitForFunction(() => {
      const usage = document.querySelector('.workspace-tile dl.workspace-usage');
      return !!usage && usage.textContent.includes('测量中') && !usage.textContent.includes('B/s');
    });
    await page.waitForFunction(() => {
      const usage = document.querySelector('.workspace-tile dl.workspace-usage');
      return !!usage && usage.textContent.includes('B/s');
    });

    await page.locator('#btn-new-workspace').click();
    // 必填代理：一个都不选就提交，必须被拦下且不发出请求。
    await page.locator('#new-name').fill('新增空间');
    const writesBeforeCreate = writes.length;
    await page.locator('#new-ok').click();
    await page.locator('#new-error').waitFor({ state: 'visible' });
    assert.match(await page.locator('#new-error').innerText(), /至少绑定一个账号/);
    assert.equal(writes.length, writesBeforeCreate, 'incomplete instance must not be submitted');
    // 已被其他实例占用的账号列出但不可选，并说明占用者。
    await page.locator('#new-account-claude + .select-trigger').click();
    const taken = page.locator('.select-panel:popover-open [role=option]').filter({ hasText: '已占用账号' });
    assert.equal(await taken.getAttribute('aria-disabled'), 'true', 'a bound account must not be selectable');
    assert.match(await taken.innerText(), /已绑定：产品开发/);
    await page.keyboard.press('Escape');
    // 只勾 Codex 账号：默认工具跟着变成 Codex；代理可选，默认「不绑定」。
    await choose('new-account-codex', 'Codex 备用');
    assert.match(await page.locator('#new-default-agent + .select-trigger').innerText(), /Codex CLI/);
    assert.match(await page.locator('#new-proxy + .select-trigger').innerText(), /不绑定/);
    // 机房代理不出现在新实例可选项里：新实例只能用住宅出口。
    await page.locator('#new-proxy + .select-trigger').click();
    assert.equal(await page.locator('.select-panel:popover-open [role=option]').filter({ hasText: '机房出口' }).count(), 0);
    await page.keyboard.press('Escape');
    await choose('new-account-claude', '开发账号');
    await choose('new-proxy', '住宅出口');
    await choose('new-default-agent', 'Claude Code');
    await page.locator('#new-ok').click();
    await page.locator('#dlg-new').waitFor({ state: 'hidden' });
    await page.waitForFunction(() => document.querySelectorAll('.workspace-tile').length === 4);
    assert.equal(writes.at(-1).path, '/api/sessions');
    assert.deepEqual(writes.at(-1).body, {
      name: '新增空间',
      claude_account_id: claudeAccount.id,
      codex_account_id: codexAccount.id,
      proxy_id: residentialProxy.id,
      default_agent: 'claude',
      git_connection_id: '',
    });
    assert.equal(new URL(page.url()).hash, '#/workspaces');
    assert.equal(terminalURLs.length, 0, 'configuration and creation must not open a terminal');

    await page.locator('#btn-projects').click();
    await page.locator('[data-sidebar-project-id="fixture-project"]').click();
    await page.waitForURL('**/#/projects/fixture-space/fixture-project/term');
    assert.equal(await page.locator('[data-sidebar-project-id="fixture-project"]').getAttribute('aria-current'), 'page');
    await page.waitForFunction(() => document.querySelector('#term-state').textContent.includes('已连接'));
    const terminalURL = new URL(terminalURLs.at(-1));
    assert.equal(terminalURL.searchParams.get('mode'), 'agent');
    assert.equal(terminalURL.searchParams.get('project'), '订单服务 + API');
    assert.equal(await page.locator('#wb-name').innerText(), '订单服务 + API');
    // 面包屑报出所属实例，标题只留当前项目。
    assert.equal(await page.locator('#topbar-title').innerText(), '订单服务 + API');
    assert.match(await page.locator('#topbar-crumbs').innerText(), /产品开发/);
    assert.equal(await page.locator('.tab[data-tab="chat"]').isVisible(), false);
    assert.equal(await page.locator('#btn-delete').isVisible(), false);
    await page.locator('.tab[data-tab="files"]').click();
    await page.waitForURL('**/#/projects/fixture-space/fixture-project/files');
    assert.equal(filePaths.at(-1), '订单服务 + API');
    await page.reload();
    await page.locator('#tab-files').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#wb-name').innerText(), '订单服务 + API');
    await page.goto(base + '/#/sessions/fixture-space/chat');
    await page.waitForURL('**/#/sessions/fixture-space/chat');
    assert.equal(await page.locator('.tab[data-tab="chat"]').isVisible(), true);
    assert.equal(await page.locator('#wb-name').innerText(), '产品开发');
    assert.match(await page.locator('#wb-meta').innerText(), /Claude Code：开发账号/);

    // 技能/MCP 页签按绑定账号判定：默认 Codex、同时绑定 Claude 的实例仍可用；
    // 纯 Codex 实例（没有 Claude 账号）才隐藏。
    await page.goto(base + '/#/sessions/fixture-second/chat');
    await page.waitForURL('**/#/sessions/fixture-second/chat');
    await page.waitForFunction(() => document.querySelector('#wb-name')?.textContent === '内部工具');
    await page.locator('#tab-btn-skills').waitFor({ state: 'visible' });
    await page.locator('#tab-btn-mcp').waitFor({ state: 'visible' });
    await page.goto(base + '/#/sessions/fixture-third/chat');
    await page.waitForURL('**/#/sessions/fixture-third/chat');
    await page.waitForFunction(() => document.querySelector('#wb-name')?.textContent === '纯 Codex');
    assert.equal(await page.locator('#tab-btn-skills').isVisible(), false);
    assert.equal(await page.locator('#tab-btn-mcp').isVisible(), false);

    await page.goto(base + '/#/projects/fixture-space/missing/term');
    await page.waitForURL('**/#/');
    await page.locator('#empty').waitFor({ state: 'visible' });
    let releaseRoute, captureRoute, resolveRoute;
    const capturedRoute = new Promise(done => { captureRoute = done; });
    const completedRoute = new Promise(done => { resolveRoute = done; });
    let delayOnce = true;
    const delayedRoute = async route => {
      if (!delayOnce) { await route.fallback(); return; }
      delayOnce = false;
      captureRoute();
      await new Promise(done => { releaseRoute = done; });
      await route.fulfill({ json: projects['fixture-space'] });
      resolveRoute();
    };
    await page.route('**/api/sessions/fixture-space/projects', delayedRoute);
    await page.evaluate(() => location.hash = '#/projects/fixture-space/fixture-project/term');
    await capturedRoute;
    await page.locator('#btn-projects').click();
    await page.waitForURL('**/#/');
    const terminalCount = terminalURLs.length;
    releaseRoute();
    await completedRoute;
    await page.evaluate(async () => {
      await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
    });
    assert.equal(new URL(page.url()).hash, '#/');
    assert.equal(terminalURLs.length, terminalCount, 'stale project route must not reopen its terminal');
    await page.unroute('**/api/sessions/fixture-space/projects', delayedRoute);
    failList = true;
    await refresh();
    await page.locator('#projects-load-error').waitFor({ state: 'visible' });
    assert.match(await page.locator('#project-total').innerText(), /\+$/);
    failList = false;
    await page.locator('#project-refresh').click();
    await page.locator('#projects-load-error').waitFor({ state: 'hidden' });
    await page.locator('#toast.show').waitFor({ state: 'hidden' });
    for (const width of [360, 390, 768, 1440]) {
      await page.setViewportSize({ width, height: 960 });
      for (const theme of ['light', 'dark']) {
        await page.evaluate(theme => {
          localStorage.setItem('agentbox_theme', theme);
          document.documentElement.dataset.theme = theme;
          document.documentElement.dataset.themeMode = theme;
        }, theme);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        assert.equal(await page.locator('#empty').evaluate(element => element.scrollWidth <= element.clientWidth), true);
        // 顶栏在每个宽度都必须在，且主题控件只有一套可见（宽屏三态组、窄屏单键）。
        assert.equal(await page.locator('.topbar').isVisible(), true);
        const themeGroupVisible = await page.locator('.topbar .theme-options').isVisible();
        const themeCycleVisible = await page.locator('.topbar [data-theme-cycle]').isVisible();
        assert.notEqual(themeGroupVisible, themeCycleVisible, 'exactly one theme control set must be visible');
        assert.equal(themeGroupVisible, width > 760, 'wide screens show the three-state group');
        assert.equal(await page.locator('#btn-user-menu').isVisible(), true);
        assert.equal(await page.locator('#btn-menu').isVisible(), width <= 760);
        if (width <= 760) {
          await page.locator('#btn-menu').click();
          assert.equal(await page.locator('#sidebar').getAttribute('inert'), null);
          assert.equal(await page.locator('#sidebar').evaluate(element => element.scrollWidth <= element.clientWidth), true);
          await page.screenshot({ animations: 'disabled', path: resolve(`output/playwright/sidebar-${width}-${theme}.png`) });
          await page.locator('#btn-sidebar-close').click();
        }
        await page.screenshot({ animations: 'disabled', path: resolve(`output/playwright/projects-${width}-${theme}.png`) });
        await page.goto(base + '/#/workspaces');
        await page.locator('#workspace-grid .workspace-tile').first().waitFor();
        assert.equal(await page.locator('#view-workspaces').evaluate(element => element.scrollWidth <= element.clientWidth), true);
        await page.screenshot({ animations: 'disabled', path: resolve(`output/playwright/workspaces-${width}-${theme}.png`) });
        await page.goto(base + '/#/');
        await page.locator('.project-tile').first().waitFor();
      }
    }
    await page.setViewportSize({ width: 1440, height: 960 });
    sessions = [sessions.find(session => session.id === 'fixture-space')];
    projects['fixture-space'] = [project('fixture-client', 'agentbox-client'), project('fixture-reminder', '叮叮提醒')];
    await refresh();
    await page.waitForFunction(() => document.querySelectorAll('.sidebar-project').length === 2);
    assert.equal(await page.locator('.sidebar-instance').count(), 1, 'two projects must not become two instances');
    assert.equal(await page.locator('#session-count').innerText(), '1');
    assert.equal(await page.locator('.sidebar-instance[data-session-id="fixture-space"] .sidebar-project').count(), 2);
    assert.equal(await page.locator('.side-nav[aria-label="系统管理"]').isVisible(), false, 'ordinary users must not see an empty admin group');
    await page.screenshot({ animations: 'disabled', path: resolve('output/playwright/sidebar-single-instance-light.png') });
    sessions = [];
    await refresh();
    await page.locator('#project-empty-configure').waitFor({ state: 'visible' });
    await page.locator('#empty-new').click();
    assert.equal(await page.locator('#project-ok').isDisabled(), true);
    await page.locator('#project-configure').click();
    await page.locator('#workspace-empty').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#workspace-sample-badge').innerText(), '暂无实例');
    assert.equal(await page.locator('#workspace-refresh').isDisabled(), true);
    assert.equal(await page.locator('#workspace-cpu').innerText(), '0.0%');
    assert.equal(await page.locator('#workspace-disk').innerText(), '0 B');
    await page.goto(base + '/#/');
    holdList = true;
    sessions = [makeSession('fixture-second', { name: '延迟列表' })];
    await refresh();
    await page.waitForFunction(() => document.querySelector('#project-workspace-total').textContent === '1');
    await page.locator('#btn-user-menu').click();
    assert.equal(await page.locator('#sidebar-user-name').innerText(), 'fixture');
    assert.equal(await page.locator('#btn-git-management').isVisible(), true);
    await page.locator('#btn-logout').click();
    releaseList?.();
    await page.locator('#login').waitFor({ state: 'visible' });
    await page.waitForLoadState('load');
    assert.equal(await page.evaluate(() => localStorage.getItem('agentbox_token')), null, 'logout must survive reload without fixture reauthentication');
    assert.equal(await page.locator('.project-tile').count(), 0, 'logout clears project data');
    const readsAfterLogout = statsReads;
    await page.waitForTimeout(600);
    assert.equal(statsReads, readsAfterLogout, 'logout must stop resource polling');
    assert.deepEqual(
      writes.filter(write => write.path !== '/api/logout' && write.path !== '/api/sessions' && !write.path.endsWith('/projects') && !write.path.includes('/projects/')),
      [], 'no account/proxy/container lifecycle writes',
    );
    assert.deepEqual(errors, []);
    console.log('Projects: dual-account instance creation with optional residential proxy, project tool selection/edit, single topbar theme+account, live instance resources (measuring/stale/stopped states), polling start/stop, scoped creation, validation/retry, filters, workspace configuration, ordinary-user access, project terminal URLs, file scope, deep links/stale routes, partial failures, four widths/both themes, empty states and logout cleanup passed');
  } finally {
    releaseList?.();
    await page.unroute('**/api/**'); server.closeAllConnections(); await new Promise(done => server.close(done));
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { chromium } = await import(process.env.AGENTBOX_PLAYWRIGHT_MODULE ? pathToFileURL(process.env.AGENTBOX_PLAYWRIGHT_MODULE).href : 'playwright');
  const browser = await chromium.launch({ headless: true, ...(process.env.AGENTBOX_BROWSER_CHANNEL ? { channel: process.env.AGENTBOX_BROWSER_CHANNEL } : {}) });
  try { await smoke(await browser.newPage()); } finally { await browser.close(); }
}
