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
  const account = { id: 'fixture-account', type: 'claude', label: '开发账号', sessions: 2, cred_status: 'ok', proxy_id: 'fixture-proxy' };
  let sessions = [
    { id: 'fixture-space', name: '产品开发', agent: 'claude', account_id: account.id, account_label: account.label, container_id: 'fixture-container-a', status: 'running', default_model: 'fixture' },
    { id: 'fixture-second', name: '内部工具', agent: 'claude', account_id: account.id, account_label: account.label, container_id: 'fixture-container-b', status: 'stopped', default_model: 'fixture' },
  ];
  const project = (id, name) => ({ id, name, path: '/workspace/' + name, created_at: '2026-09-30T10:00:00Z', updated_at: '2026-09-30T10:00:00Z' });
  const projects = {
    'fixture-space': [project('fixture-project', '订单服务 + API')],
    'fixture-second': [project('fixture-other', '运营后台')],
  };
  let failList = false, failCreate = false, holdList = false, releaseList;
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
    else if (path === '/api/accounts') body = [account];
    else if (path === '/api/sessions') {
      if (method === 'POST') {
        const input = request.postDataJSON();
        body = { ...sessions[0], ...input, id: 'fixture-created', container_id: '', status: 'stopped' };
        sessions.push(body); projects[body.id] = [];
      } else body = sessions;
    } else if (path.endsWith('/projects')) {
      const sessionID = path.split('/')[3];
      if (holdList) { holdList = false; await new Promise(done => { releaseList = done; }); }
      if ((failList && sessionID === 'fixture-second') || (failCreate && method === 'POST')) {
        await route.fulfill({ status: 409, json: { error: method === 'POST' ? '项目名称已存在' : '合成列表读取失败' } }); return;
      }
      if (method === 'POST') {
        body = project('fixture-new', request.postDataJSON().name);
        projects[sessionID].push(body);
      } else body = projects[sessionID] || [];
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
  try {
    await page.setViewportSize({ width: 1440, height: 960 });
    await page.goto(base + '/#/');
    await page.waitForFunction(() => document.querySelectorAll('.project-tile').length === 2);
    assert.equal(await page.locator('#empty-new').innerText(), '新建项目');
    assert.equal(await page.locator('#btn-new').innerText(), '新建项目');
    assert.equal(await page.locator('#btn-settings').isVisible(), false);
    assert.equal(await page.locator('#btn-projects').getAttribute('aria-current'), 'page');
    assert.deepEqual(writes, [], 'home must not mutate resources');
    await page.locator('#project-search').fill('订单');
    assert.equal(await page.locator('.project-tile').count(), 1);
    await page.locator('#project-search').fill('not-found');
    assert.equal(await page.locator('#project-empty-title').innerText(), '没有匹配的项目');
    await page.locator('#project-search').fill('');
    await choose('project-filter', '内部工具');
    assert.equal(await page.locator('.project-tile').count(), 1);
    assert.match(await page.locator('.project-tile').innerText(), /运营后台/);
    await choose('project-filter', '全部工作空间');
    await mkdir(resolve('output/playwright'), { recursive: true });
    await page.screenshot({ animations: 'disabled', path: resolve('output/playwright/projects-desktop-light.png') });

    await page.locator('#empty-new').click();
    await choose('project-workspace', '内部工具');
    await page.locator('#project-name').fill('.invalid');
    await page.locator('#project-ok').click();
    await page.locator('#project-error').waitFor({ state: 'visible' });
    assert.deepEqual(writes, []);
    await page.locator('#project-name').fill('新项目');
    failCreate = true;
    await page.locator('#project-ok').click();
    await page.waitForFunction(() => document.querySelector('#project-error').textContent === '项目名称已存在');
    assert.equal(await page.locator('#dlg-project').evaluate(dialog => dialog.open), true);
    failCreate = false;
    await page.locator('#project-ok').click();
    await page.locator('#dlg-project').waitFor({ state: 'hidden' });
    await page.waitForFunction(() => document.querySelectorAll('.project-tile').length === 3);
    assert.deepEqual(writes.map(write => write.path), ['/api/sessions/fixture-second/projects', '/api/sessions/fixture-second/projects']);
    assert.deepEqual(writes.at(-1).body, { name: '新项目' });

    await page.locator('#btn-workspaces').click();
    await page.waitForURL('**/#/workspaces');
    assert.equal(await page.locator('#btn-workspaces').getAttribute('aria-current'), 'page');
    assert.equal(await page.locator('#btn-projects').getAttribute('aria-current'), null);
    assert.equal(await page.locator('.workspace-tile').count(), 2);
    assert.equal(await page.locator('#workspace-accounts').innerText(), '1', 'account reuse is unchanged');
    assert.match(await page.locator('.workspace-tile').first().innerText(), /fixture-container-a/);
    await page.locator('#toast.show').waitFor({ state: 'hidden' });
    await page.screenshot({ animations: 'disabled', path: resolve('output/playwright/workspaces-desktop-light.png') });
    await page.reload();
    await page.locator('#view-workspaces').waitFor({ state: 'visible' });
    await page.locator('#btn-new-workspace').click();
    await page.locator('#new-name').fill('新增空间');
    await page.locator('#new-ok').click();
    await page.locator('#dlg-new').waitFor({ state: 'hidden' });
    await page.waitForFunction(() => document.querySelectorAll('.workspace-tile').length === 3);
    assert.equal(writes.at(-1).path, '/api/sessions');
    assert.equal(writes.at(-1).body.account_id, account.id);
    assert.equal(new URL(page.url()).hash, '#/workspaces');
    assert.equal(terminalURLs.length, 0, 'configuration and creation must not open a terminal');

    await page.locator('#btn-projects').click();
    await page.locator('[data-project-id="fixture-project"]').click();
    await page.waitForURL('**/#/projects/fixture-space/fixture-project/term');
    await page.waitForFunction(() => document.querySelector('#term-state').textContent.includes('已连接'));
    const terminalURL = new URL(terminalURLs.at(-1));
    assert.equal(terminalURL.searchParams.get('mode'), 'agent');
    assert.equal(terminalURL.searchParams.get('project'), '订单服务 + API');
    assert.equal(await page.locator('#wb-name').innerText(), '订单服务 + API');
    assert.equal(await page.locator('.tab[data-tab="chat"]').isVisible(), false);
    assert.equal(await page.locator('#btn-delete').isVisible(), false);
    await page.locator('.tab[data-tab="files"]').click();
    await page.waitForURL('**/#/projects/fixture-space/fixture-project/files');
    assert.equal(filePaths.at(-1), '订单服务 + API');
    await page.reload();
    await page.locator('#tab-files').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#wb-name').innerText(), '订单服务 + API');
    await page.locator('[data-session-id="fixture-space"]').click();
    await page.waitForURL('**/#/sessions/fixture-space/chat');
    assert.equal(await page.locator('.tab[data-tab="chat"]').isVisible(), true);
    assert.equal(await page.locator('#wb-name').innerText(), '产品开发');

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
    sessions = [];
    await refresh();
    await page.locator('#project-empty-configure').waitFor({ state: 'visible' });
    await page.locator('#empty-new').click();
    assert.equal(await page.locator('#project-ok').isDisabled(), true);
    await page.locator('#project-configure').click();
    await page.locator('#workspace-empty').waitFor({ state: 'visible' });
    await page.goto(base + '/#/');
    holdList = true;
    sessions = [{ id: 'fixture-second', name: '延迟列表', agent: 'claude', account_id: account.id, status: 'stopped' }];
    await refresh();
    await page.waitForFunction(() => document.querySelector('#project-workspace-total').textContent === '1');
    await page.locator('#btn-user-menu').click();
    await page.locator('#btn-logout').click();
    releaseList?.();
    await page.locator('#login').waitFor({ state: 'visible' });
    await page.waitForLoadState('load');
    assert.equal(await page.evaluate(() => localStorage.getItem('agentbox_token')), null, 'logout must survive reload without fixture reauthentication');
    assert.equal(await page.locator('.project-tile').count(), 0, 'logout clears project data');
    assert.deepEqual(writes.filter(write => write.path !== '/api/logout' && write.path !== '/api/sessions' && !write.path.endsWith('/projects')), [], 'no account/proxy/container lifecycle writes');
    assert.deepEqual(errors, []);
    console.log('Projects: scoped creation, validation/retry, filters, workspace configuration, ordinary-user access, project terminal URLs, file scope, deep links/stale routes, partial failures, four widths/both themes, empty states and logout cleanup passed');
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
