import { S, bus } from "./state.js";
import type { InstanceStat, InstanceStats, Project, Session } from "./types.js";
import { api } from "./api.js";
import { $, btnBusy, btnDone, toast } from "./util.js";
import { setSelectValue } from "./select.js";
import { openSession } from "./sessions.js";
import { boundAccounts, instanceTools } from "./data.js";
import { Poller } from "./shared/poller.js";
import { showView, setSidebarProjects } from "./shell.js";
import { svgIcon } from "./chat-render.js";
import { agentName } from "./brand.js";
import { buttonLabel, actionButton } from "./icons.js";

/** 实例资源轮询间隔。服务端的 CPU 是两次采样的差值，5 秒既够看出趋势，也不至于
 * 让「打开实例页」变成持续的后台负担。 */
const STATS_INTERVAL = 5000;

/** 字节的紧凑显示。0 与「还没算出来」是两回事，后者由调用方先分流。 */
function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  if (bytes < 1024) return bytes + " B";
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return (value >= 10 ? value.toFixed(0) : value.toFixed(1)) + " " + units[unit];
}

function formatRate(bytesPerSecond: number): string {
  if (!Number.isFinite(bytesPerSecond) || bytesPerSecond < 0) return "—";
  return formatBytes(bytesPerSecond) + "/s";
}

export function initProjects() {
  const lifetime = new AbortController();
  const options = { signal: lifetime.signal };
  const dialog = $<HTMLDialogElement>("dlg-project");
  let request: AbortController | null = null;
  let rows: { session: Session; projects: Project[]; error: string }[] = [];
  let busy = false;
  let loaded = false;

  /* 实例资源：只有列表视图可见时才轮询。上一帧的字节数留在这里做差，速率由前端
   * 自己算 —— 服务端只给累计值和方法，不替调用方决定窗口。 */
  const stats = new Map<string, InstanceStat>();
  let statsWindow = 0;
  let statsReceivedAt = 0;
  let statsServerNow = 0;
  let statsError = false;
  let statsActive = false;
  const previousNet = new Map<string, { rx: number; tx: number; at: number }>();
  const statsPoller = new Poller();

  /* 编辑模式：同一个弹窗复用，mode 决定标题、提交动词与请求方法。 */
  let editing: { session: Session; project: Project } | null = null;

  function text(tag: string, className: string, value: string) {
    const element = document.createElement(tag);
    element.className = className;
    element.textContent = value;
    return element;
  }

  function button(label: string, action: () => void, primary = false) {
    const element = document.createElement("button");
    element.type = "button";
    element.className = "btn" + (primary ? " btn-primary" : "");
    buttonLabel(element, label, primary ? "plus" : "folder");
    element.addEventListener("click", action);
    return element;
  }

  function fillWorkspaces(select: HTMLSelectElement, all: boolean, preferred = select.value) {
    select.replaceChildren();
    if (all) select.append(new Option("全部实例", ""));
    for (const session of S.sessions) select.append(new Option(session.name, session.id));
    if (!S.sessions.length && !all) select.append(new Option("请先创建实例", ""));
    setSelectValue(select, [...select.options].some(option => option.value === preferred) ? preferred : select.options[0]?.value || "");
  }

  /** 开发工具下拉：只列实例真正绑定过的工具，外加一条「跟随实例默认」。
   * 绑不上的工具直接不出现，用户不会先选中再被服务端打回。 */
  function fillProjectAgent(select: HTMLSelectElement, session: Session | undefined, preferred: string) {
    select.replaceChildren();
    select.append(new Option("跟随实例默认" + (session ? `（${agentName(session.default_agent || session.agent)}）` : ""), ""));
    for (const tool of session ? instanceTools(session) : []) select.append(new Option(agentName(tool), tool));
    if (!session || !instanceTools(session).length) {
      select.append(Object.assign(new Option("实例未绑定账号", ""), { disabled: true }));
      select.disabled = true;
    } else {
      select.disabled = false;
    }
    setSelectValue(select, [...select.options].some(option => option.value === preferred) ? preferred : "");
  }

  /** 服务器目录只读展示：网页不能选择用户本机目录，本地映射也还没实现，
   * 所以这里只把真实路径写清楚，不给一个点了没用的输入框。 */
  function renderProjectPathHint() {
    const sessionID = $<HTMLSelectElement>("project-workspace").value;
    const session = S.sessions.find(item => item.id === sessionID);
    const name = $<HTMLInputElement>("project-name").value.trim();
    const hint = $("project-path-hint");
    if (!session) {
      hint.textContent = "服务器目录：先选择实例。";
      return;
    }
    const root = session.workspace_path || "（实例工作区）";
    const target = name && !/[\/\\\u0000]/.test(name) ? root + "/" + name : root + "/<项目名>";
    hint.textContent =
      `服务器目录：${target}（容器内同一路径，服务器绝对路径）。` +
      `本机目录映射尚未实现：网页不能选择你电脑上的目录，abox-sync 按项目名同步到本地。`;
  }

  function openCreate(sessionID = "") {
    editing = null;
    $("project-title").textContent = "新建项目";
    buttonLabel($("project-ok"), "创建项目", "plus");
    $("project-workspace-field").classList.remove("hidden");
    fillWorkspaces($<HTMLSelectElement>("project-workspace"), false, sessionID);
    $<HTMLFormElement>("project-form").reset();
    setSelectValue($<HTMLSelectElement>("project-workspace"), sessionID || S.sessions[0]?.id || "");
    fillProjectAgent($<HTMLSelectElement>("project-agent"), S.sessions.find(item => item.id === $<HTMLSelectElement>("project-workspace").value), "");
    renderProjectPathHint();
    $("project-error").classList.add("hidden");
    $("project-no-workspace").classList.toggle("hidden", !!S.sessions.length);
    $<HTMLButtonElement>("project-ok").disabled = !S.sessions.length;
    dialog.showModal();
  }

  function openEdit(session: Session, project: Project) {
    editing = { session, project };
    $("project-title").textContent = "项目设置";
    buttonLabel($("project-ok"), "保存", "save");
    // 项目不能换实例：路径就是实例工作区下的目录名。
    $("project-workspace-field").classList.add("hidden");
    fillWorkspaces($<HTMLSelectElement>("project-workspace"), false, session.id);
    $<HTMLFormElement>("project-form").reset();
    setSelectValue($<HTMLSelectElement>("project-workspace"), session.id);
    $<HTMLInputElement>("project-name").value = project.name;
    fillProjectAgent($<HTMLSelectElement>("project-agent"), session, project.agent || "");
    renderProjectPathHint();
    $("project-error").classList.add("hidden");
    $("project-no-workspace").classList.add("hidden");
    $<HTMLButtonElement>("project-ok").disabled = false;
    dialog.showModal();
  }

  /* ---- 实例卡片 ---- */

  /** 一条资源读数。running=false 显示「已停止」；有采样但窗口还不足时显示
   * 「测量中」；磁盘与网络各自有各自的「还没算出来」。绝不把未知画成 0。 */
  function metric(dl: HTMLElement, label: string, value: string) {
    dl.append(text("dt", "", label), text("dd", "", value));
  }

  function uptime(stat: InstanceStat | undefined): string {
    if (!stat?.running) return "已停止";
    if (!stat.started_at || statsServerNow < stat.started_at) return "测量中";
    const minutes = Math.floor((statsServerNow - stat.started_at) / 60000);
    if (minutes < 1) return "不足 1 分钟";
    if (minutes < 60) return `${minutes} 分钟`;
    if (minutes < 1440) return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分钟`;
    return `${Math.floor(minutes / 1440)} 天 ${Math.floor(minutes % 1440 / 60)} 小时`;
  }

  function renderInstanceSummary() {
    const currentStats = S.sessions.map(session => stats.get(session.id));
    const running = S.sessions.filter(session => stats.get(session.id)?.running ?? session.status === "running");
    const runningStats = running.map(session => stats.get(session.id));
    const sampled = runningStats.every(stat => stat && stat.sample_ok !== false);
    const cpuReady = sampled && (!running.length || statsWindow > 0) && runningStats.every(stat => stat?.cpu_ready !== false);
    const sum = (field: "cpu_percent" | "mem_usage" | "pids" | "disk_bytes", values = runningStats) => values.reduce((total, stat) => total + (stat?.[field] || 0), 0);
    $("workspace-running").textContent = String(running.length);
    $("workspace-stopped").textContent = String(S.sessions.length - running.length);
    $("workspace-cpu").textContent = cpuReady ? `${sum("cpu_percent").toFixed(1)}%` : "测量中";
    $("workspace-memory").textContent = sampled ? formatBytes(sum("mem_usage")) : "测量中";
    $("workspace-pids").textContent = sampled ? String(sum("pids")) : "测量中";
    $("workspace-disk").textContent = currentStats.every(stat => stat && !stat.disk_stale) ? formatBytes(sum("disk_bytes", currentStats)) : "统计中";
    const created = S.sessions.filter(session => session.container_id).length;
    $("workspace-created").textContent = String(created);
    $("workspace-pending").textContent = String(S.sessions.length - created);
    $("workspace-proxy-missing").textContent = String(S.sessions.filter(session => stats.get(session.id)?.proxy_bound === false || !session.proxy_id).length);
    const badge = $("workspace-sample-badge");
    badge.className = "console-status" + (statsReceivedAt && !statsError && sampled ? " running" : "");
    badge.textContent = !S.sessions.length ? "暂无实例" : statsError ? "采样失败" : statsReceivedAt ? sampled ? "实时采样" : "部分待采样" : "等待采样";
    $("workspace-sample-status").textContent = !S.sessions.length ? "创建实例后显示实时资源。" : statsError ? "资源采样失败，保留上次读数；5 秒后自动重试。" : statsReceivedAt ? `采样于 ${new Date(statsServerNow).toLocaleTimeString()} · 每 5 秒刷新，仅显示你的实例。` : "正在读取容器资源；CPU 与网络速率需要两次采样。";
    if (!S.sessions.length) $<HTMLButtonElement>("workspace-refresh").disabled = true;
  }

  function resourceRows(session: Session): [string, string][] {
    const stat = stats.get(session.id);
    const running = stat ? stat.running : session.status === "running";
    if (!stat || !running) {
      const reason = running ? "测量中" : "已停止";
      return [["CPU", reason], ["内存", reason], ["磁盘", "—"], ["网络", reason]];
    }
    const cpu = statsWindow > 0 && stat.cpu_ready !== false ? `${stat.cpu_percent.toFixed(0)}%` : "测量中";
    const memory = stat.sample_ok === false ? "测量中" : `${formatBytes(stat.mem_usage)} / ${formatBytes(stat.mem_limit)}`;
    const disk = stat.disk_stale ? "统计中" : formatBytes(stat.disk_bytes);
    const previous = previousNet.get(session.id);
    let network = "测量中";
    if (previous) {
      const elapsed = (statsReceivedAt - previous.at) / 1000;
      // 超过 60 秒的间隔不是速率是噪声（中间多半离开过页面）：只把它当成新基准。
      // 计数器回退（容器重启、中间夹了失败帧）同样不算速率：宁可再测一帧，
      // 也不把未知画成 ↓ 0 B/s 或拿「真值 − 0」冒充超大流量。
      if (elapsed > 0 && elapsed <= 60 && stat.net_rx_bytes >= previous.rx && stat.net_tx_bytes >= previous.tx) {
        network = "↓ " + formatRate((stat.net_rx_bytes - previous.rx) / elapsed) +
          " ↑ " + formatRate((stat.net_tx_bytes - previous.tx) / elapsed);
      }
    }
    return [["CPU", cpu], ["内存", memory], ["磁盘", disk], ["网络", network], ["容器进程", stat.sample_ok === false ? "测量中" : String(stat.pids)], ["运行时间", uptime(stat)]];
  }

  function renderWorkspaces() {
    const list = $("workspace-grid");
    list.replaceChildren();
    $("workspace-total").textContent = String(S.sessions.length);
    renderInstanceSummary();
    const accountIDs = new Set<string>();
    for (const session of S.sessions) for (const account of boundAccounts(session)) accountIDs.add(account.id);
    $("workspace-accounts").textContent = String(accountIDs.size);
    $("workspace-empty").classList.toggle("hidden", !!S.sessions.length);
    for (const session of S.sessions) {
      const card = document.createElement("article");
      card.className = "workspace-tile";
      card.dataset.sessionId = session.id;
      const heading = document.createElement("div");
      heading.className = "tile-heading";
      const icon = document.createElement("span");
      icon.className = "console-icon";
      icon.append(svgIcon("box", 20));
      const running = stats.get(session.id)?.running ?? session.status === "running";
      heading.append(icon, text("h3", "tile-title", session.name), text("span", "console-status" + (running ? " running" : ""), running ? "运行中" : "已停止"));

      const details = document.createElement("dl");
      details.className = "workspace-details";
      const accounts = boundAccounts(session);
      const accountOf = (tool: "claude" | "codex") => accounts.find(account => account.tool === tool)?.label || "未绑定";
      const proxy = session.proxy_label || session.proxy_id || "未绑定代理";
      for (const [label, value] of [
        [agentName("claude") + " 账号", accountOf("claude")],
        [agentName("codex") + " 账号", accountOf("codex")],
        ["出口代理", proxy],
        ["服务器目录", session.workspace_path || "—"],
        ["容器", session.container_id || "尚未创建"],
      ] as [string, string][]) {
        details.append(text("dt", "", label), text("dd", "", value));
      }

      const resources = document.createElement("dl");
      resources.className = "workspace-usage";
      const values = resourceRows(session);
      for (const [label, value] of values) metric(resources, label, value);

      const actions = document.createElement("div");
      actions.className = "tile-actions";
      actions.append(button("打开工作台", () => { void openSession(session); }), button("新建项目", () => openCreate(session.id), true));
      const identity = text("p", "instance-identity", session.container_id ? `Docker · ${session.container_id}` : "Docker · 首次启动时创建容器");
      if (session.container_id) {
        const containerID = session.container_id;
        const copy = actionButton(document.createElement("button"), "", "copy", "复制容器 ID");
        copy.type = "button";
        copy.classList.add("instance-copy");
        copy.addEventListener("click", () => {
          void navigator.clipboard.writeText(containerID).then(() => toast("容器 ID 已复制"), () => toast("复制失败，请手动选择容器 ID"));
        });
        identity.append(copy);
      }
      card.append(heading, identity, resources, details, actions);
      list.append(card);
    }
  }

  /* ---- 实例资源轮询 ---- */

  async function pollStats(signal: AbortSignal) {
    if (S.view !== "workspaces") return;
    const token = S.token;
    const refreshButton = $<HTMLButtonElement>("workspace-refresh");
    refreshButton.disabled = true;
    let payload: InstanceStats;
    try {
      payload = await api<InstanceStats>("/instances/stats", { signal });
      if (!payload || !Array.isArray(payload.items) || !Number.isFinite(payload.now)) throw new Error("无效的资源采样");
    } catch {
      if (!signal.aborted && token === S.token && S.view === "workspaces") {
        statsError = true;
        renderInstanceSummary();
      }
      return;
    } finally {
      if (!signal.aborted && token === S.token) refreshButton.disabled = false;
    }
    // 跨账号/跨视图的过期响应一律丢掉：否则退出登录再登录会看到上一个人的数字。
    if (signal.aborted || token !== S.token || S.view !== "workspaces") return;
    statsError = false;
    const receivedAt = Date.now();
    // 用上一帧的读数算速率，然后把这一帧留作下一帧的基准。
    // 采样失败的帧（sample_ok=false，计数器是零值）不能当基线，否则下一帧
    // 会拿「真计数 − 0」算出一次假峰值。
    previousNet.clear();
    for (const item of stats.values()) {
      if (item.sample_ok !== false && Number.isFinite(item.net_rx_bytes) && Number.isFinite(item.net_tx_bytes)) {
        previousNet.set(item.session_id, { rx: item.net_rx_bytes, tx: item.net_tx_bytes, at: statsReceivedAt });
      }
    }
    stats.clear();
    for (const item of payload.items) stats.set(item.session_id, item);
    statsWindow = payload.window_ms || 0;
    statsReceivedAt = receivedAt;
    statsServerNow = payload.now;
    renderWorkspaces();
  }

  function syncStatsPolling() {
    const wanted = S.view === "workspaces" && S.sessions.length > 0;
    // 别的刷新（每 8 秒的 refreshAll）也会走到这里；重复 start 会把正在进行的那
    // 一次请求掐掉，反而把轮询周期越拖越长，所以只在状态真的翻转时才动。
    if (wanted === statsActive) return;
    statsActive = wanted;
    // 离开实例视图、退出登录后立刻停：没有人在看就不该继续打服务端。
    if (wanted) statsPoller.start(STATS_INTERVAL, signal => pollStats(signal));
    else statsPoller.stop();
  }

  /* ---- 项目列表 ---- */

  function renderProjects() {
    const list = $("project-grid");
    const filter = $<HTMLSelectElement>("project-filter").value;
    const query = $<HTMLInputElement>("project-search").value.trim().toLocaleLowerCase();
    const failed = rows.filter(row => row.error);
    const total = rows.reduce((count, row) => count + row.projects.length, 0);
    $("project-total").textContent = loaded ? String(total) + (failed.length ? "+" : "") : "—";
    $("project-workspace-total").textContent = String(S.sessions.length);
    $("project-running-total").textContent = String(S.sessions.filter(session => session.status === "running").length);
    $("projects-load-error").textContent = failed.map(row => `${row.session.name}：${row.error}`).join("；");
    $("projects-load-error").classList.toggle("hidden", !failed.length);
    const focus = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>("[data-project-id]")?.dataset.projectId;
    list.replaceChildren();
    let visible = 0;
    for (const row of rows) {
      if (filter && filter !== row.session.id) continue;
      for (const project of row.projects) {
        if (query && !`${project.name} ${row.session.name}`.toLocaleLowerCase().includes(query)) continue;
        visible++;
        // 卡片主体是「打开终端」，设置按钮必须做成兄弟节点：button 套 button
        // 是非法结构，聚焦和点击都会被浏览器重新分配。
        const wrap = document.createElement("div");
        wrap.className = "project-tile-wrap";
        const card = document.createElement("button");
        card.type = "button";
        card.className = "project-tile";
        card.dataset.projectId = project.id;
        card.setAttribute("aria-label", `打开项目 ${project.name}（${row.session.name}）的 Agent 终端`);
        const icon = document.createElement("span");
        icon.className = "console-icon";
        icon.append(svgIcon("folder", 20));
        const body = document.createElement("span");
        body.className = "project-tile-body";
        body.append(text("span", "tile-title", project.name), text("span", "tile-meta", row.session.name), text("span", "project-path", project.path));
        const footer = document.createElement("span");
        footer.className = "project-tile-footer";
        // 项目自己的工具优先；没设过就跟随实例默认。
        const tool = project.agent || row.session.default_agent || row.session.agent;
        footer.append(text("span", "", agentName(tool) + (project.agent ? "" : "（默认）")), text("span", "project-open-label", "打开终端"));
        card.append(icon, body, footer);
        card.addEventListener("click", () => { void openSession(row.session, "term", project); });
        const settings = document.createElement("button");
        settings.type = "button";
        settings.className = "project-tile-settings";
        settings.dataset.projectSettings = project.id;
        buttonLabel(settings, "", "settings");
        settings.setAttribute("aria-label", `项目设置：${project.name}`);
        settings.addEventListener("click", event => {
          event.stopPropagation();
          openEdit(row.session, project);
        });
        wrap.append(card, settings);
        list.append(wrap);
        if (focus === project.id) card.focus({ preventScroll: true });
      }
    }
    $("project-empty-state").classList.toggle("hidden", !!visible);
    $("project-empty-title").textContent = !loaded ? "正在读取项目…" : failed.length && !total ? "暂时无法读取项目" : total && !visible ? "没有匹配的项目" : "创建你的第一个项目";
    $("project-empty-desc").textContent = !loaded ? "读取现有实例中的项目目录。" : failed.length && !total ? "检查连接后点击刷新重试，不会更改现有实例。" : total && !visible ? "尝试其他关键词，或切换实例。" : S.sessions.length ? "选择一个实例，新项目将共享它的账号、代理和容器。" : "先在实例页创建实例，再在这里添加项目。";
    $("project-empty-create").classList.toggle("hidden", !loaded || !!total || !!failed.length || !S.sessions.length);
    $("project-empty-configure").classList.toggle("hidden", !loaded || !!S.sessions.length);
    $("project-result-count").textContent = loaded ? `${visible} 个项目` : "读取中…";
  }

  async function load() {
    renderWorkspaces();
    syncStatsPolling();
    request?.abort();
    const controller = request = new AbortController();
    rows = rows.filter(row => S.sessions.some(session => session.id === row.session.id));
    fillWorkspaces($<HTMLSelectElement>("project-filter"), true);
    renderProjects();
    const result = await Promise.all(S.sessions.map(async session => {
      try {
        const projects = await api<Project[]>(`/sessions/${encodeURIComponent(session.id)}/projects`, { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15000)]) });
        if (!Array.isArray(projects)) throw new Error("项目列表格式不正确，请重试");
        return { session, projects, error: "" };
      } catch (error) {
        return { session, projects: [], error: (error as Error).message };
      }
    }));
    if (controller.signal.aborted || lifetime.signal.aborted) return;
    rows = result;
    loaded = true;
    setSidebarProjects(rows);
    renderProjects();
  }

  const configure = () => { showView("workspaces"); void load(); };
  bus.addEventListener("open-workspaces", configure, options);
  bus.addEventListener("projects-home", () => { void load(); }, options);
  bus.addEventListener("open-sidebar-project", event => {
    const { session, project } = (event as CustomEvent<{ session: Session; project: Project }>).detail;
    void openSession(session, "term", project);
  }, options);
  bus.addEventListener("data-updated", () => { void load(); }, options);
  // 视图切换与退出登录都要收拾轮询：没人看就不该继续采样。
  bus.addEventListener("view-changed", () => syncStatsPolling(), options);
  bus.addEventListener("unauthorized", () => { statsPoller.stop(); statsActive = false; }, options);
  $("btn-workspaces").addEventListener("click", configure, options);
  $("workspace-refresh").addEventListener("click", () => {
    if (S.view === "workspaces" && S.sessions.length) statsPoller.start(STATS_INTERVAL, signal => pollStats(signal));
  }, options);
  $("project-empty-configure").addEventListener("click", configure, options);
  $("project-configure").addEventListener("click", () => { dialog.close(); configure(); }, options);
  for (const id of ["btn-new", "empty-new", "project-empty-create"]) {
    $(id).addEventListener("click", () => openCreate(), options);
  }
  $("project-refresh").addEventListener("click", () => { void load(); }, options);
  $("project-filter").addEventListener("change", renderProjects, options);
  $("project-search").addEventListener("input", renderProjects, options);
  $("project-workspace").addEventListener("change", () => {
    const session = S.sessions.find(item => item.id === $<HTMLSelectElement>("project-workspace").value);
    fillProjectAgent($<HTMLSelectElement>("project-agent"), session, "");
    renderProjectPathHint();
  }, options);
  $("project-name").addEventListener("input", renderProjectPathHint, options);
  $("project-cancel").addEventListener("click", () => dialog.close(), options);
  dialog.addEventListener("cancel", event => { if (busy) event.preventDefault(); }, options);
  $("project-form").addEventListener("submit", async event => {
    event.preventDefault();
    if (busy) return;
    const sessionID = $<HTMLSelectElement>("project-workspace").value;
    const name = $<HTMLInputElement>("project-name").value.trim();
    const agent = $<HTMLSelectElement>("project-agent").value;
    $("project-error").classList.add("hidden");
    if (!S.sessions.some(session => session.id === sessionID) || !name || name.startsWith(".") || /[\/\\\u0000]/.test(name)) {
      $("project-error").textContent = "请选择实例；项目名称不能以点开头或包含路径分隔符。";
      $("project-error").classList.remove("hidden");
      return;
    }
    busy = true;
    btnBusy($("project-ok"), editing ? "保存中…" : "创建中…");
    $<HTMLButtonElement>("project-cancel").disabled = true;
    try {
      if (editing) {
        await api<Project>(`/sessions/${encodeURIComponent(editing.session.id)}/projects/${encodeURIComponent(editing.project.id)}`, {
          method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, agent }), signal: lifetime.signal,
        });
      } else {
        await api<Project>(`/sessions/${encodeURIComponent(sessionID)}/projects`, {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, agent }), signal: lifetime.signal,
        });
      }
      if (lifetime.signal.aborted) return;
      const wasEditing = !!editing;
      dialog.close();
      $<HTMLInputElement>("project-search").value = "";
      setSelectValue($<HTMLSelectElement>("project-filter"), "");
      await load();
      toast(wasEditing ? "项目设置已保存" : "项目已创建");
    } catch (error) {
      if (lifetime.signal.aborted) return;
      $("project-error").textContent = (error as Error).message;
      $("project-error").classList.remove("hidden");
    } finally {
      busy = false;
      if (!lifetime.signal.aborted) {
        btnDone($("project-ok"));
        $<HTMLButtonElement>("project-cancel").disabled = false;
      }
    }
  }, options);
  renderProjects();
  renderWorkspaces();
  return () => {
    lifetime.abort(); request?.abort(); statsPoller.stop(); statsActive = false; dialog.close(); rows = []; loaded = false;
    setSidebarProjects([]);
    stats.clear(); previousNet.clear(); statsWindow = 0; statsReceivedAt = 0; statsServerNow = 0; statsError = false;
    renderInstanceSummary();
    $("project-grid").replaceChildren(); $("workspace-grid").replaceChildren();
    $<HTMLFormElement>("project-form").reset();
    btnDone($("project-ok"));
    $<HTMLButtonElement>("project-cancel").disabled = false;
    $("project-workspace").replaceChildren();
    $("project-agent").replaceChildren();
    $("project-filter").replaceChildren(new Option("全部实例", ""));
    $<HTMLInputElement>("project-search").value = "";
  };
}
