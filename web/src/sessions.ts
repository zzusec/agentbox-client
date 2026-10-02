/* sessions：实例的打开/切换、生命周期（启动/停止/删除，含 ⋯ 菜单）、
 * 新建实例弹窗、工作台标签页。 */
"use strict";

import { S, bus, emit } from "./state.js";
import type { Tab } from "./state.js";
import type { InstanceProxyOption, Session, GitConnection, Project } from "./types.js";
import { setSelectValue } from "./select.js";
import { $, btnBusy, btnDone, wbBusy, wbIdle, toast, askPrompt } from "./util.js";
import { api } from "./api.js";
import { refreshAll, boundAccounts, instanceTools } from "./data.js";
import { showView, renderSidebar, updateTopbarTitle } from "./shell.js";
import { chatTeardown, resetChatImgs, loadPick, updateHero, loadHistory, connectChat } from "./chat.js";
import { setThreadBar, closeThreadPanel } from "./chat-threads.js";
import { termTeardown, termDisconnect, openTerm, termSpendPolling } from "./term.js";
import { resetTree, loadFiles } from "./files.js";
import { loadChanges, resetChangesRepo } from "./changes.js";
import { loadSkills } from "./skills.js";
import { agentKey, agentName, agentIcon, agentAvatar, decorateAgentOpts } from "./brand.js";
import { openAcctUsage } from "./acct-usage.js";
import { showBrowser, browserDisconnect } from "./remote-browser.js";
import { setTip } from "./tip.js";
import { bindMenu } from "./menu.js";
import { sessionState } from "./session-state.js";
import { actionButton } from "./icons.js";
import type { MenuItem } from "./menu.js";

/* ---------------- 打开 / 切换 ---------------- */

export async function openSession(sess: Session, tab?: Tab, project?: Project) {
  if (project && tab !== "files") tab = "term";
  if (!instanceTools(sess).includes("claude") && (tab === "skills" || tab === "mcp")) tab = "chat";
  if (S.current && S.current.id === sess.id && S.project?.id === project?.id) {
    showView("work");
    if (tab && tab !== S.tab) setTab(tab);
    return;
  }
  closeChannels();
  showView("work");
  S.current = sess;
  S.project = project || null;
  S.filePath = project?.name || "";
  if (project) S.fileScope = "workspace";
  resetTree();
  resetChangesRepo();
  resetChatImgs();
  if (!project) loadPick();
  $("empty").classList.add("hidden");
  $("workbench").classList.remove("hidden");
  $("chat-log").replaceChildren();
  setThreadBar(null); // 切换会话时先清掉上一个会话的线程标题
  S.histLoading = !project; // loadHistory 还没跑之前也不要闪引导页
  updateHero();
  setTab(tab || "chat");
  renderSidebar();
  renderHead();
  if (project) return;
  await loadHistory();
  if (S.current?.id === sess.id && !S.project) connectChat();
}

export function renderHead() {
  const sess = S.current;
  if (!sess) return;
  updateTopbarTitle();
  $("wb-name").textContent = S.project?.name || sess.name;
  const av = agentAvatar(sess.agent, { size: 32, icon: 17, led: true });
  setTip(av, agentName(sess.agent));
  if (sess.status === "running") av.querySelector(".led")!.classList.add("on");
  $("wb-avatar").replaceChildren(av);
  const meta = $("wb-meta");
  meta.replaceChildren();
  const an = document.createElement("span");
  an.className = "agent-text agent-" + agentKey(sess.agent);
  an.textContent = agentName(sess.agent);
  // 实例可以同时绑两个账号，两个都要报出来，否则用户看不出这条命令走的是谁。
  const accounts = boundAccounts(sess).map(account => `${agentName(account.tool)}：${account.label}`).join(" · ") || "未绑定账号";
  const proxy = sess.proxy_label || (sess.proxy_id ? sess.proxy_id : "未绑定代理");
  meta.append(an, document.createTextNode(` · ${accounts} · 出口 ${proxy} · #${sess.id}`));
  if (S.project) meta.append(document.createTextNode(` · ${sess.name} · ${S.project.path}`));
  $("workbench").classList.toggle("project-workbench", !!S.project);
  $("project-scope-note").classList.toggle("hidden", !S.project);
  for (const name of ["chat", "changes"]) {
    document.querySelector<HTMLElement>(`.tab[data-tab="${name}"]`)!.classList.toggle("hidden", !!S.project);
  }
  document.querySelector<HTMLElement>('.tab[data-tab="files"] .t')!.textContent = S.project ? "空间文件" : "文件";
  // 技能是 Claude Code 的机制，codex 会话没有对应目录，页签直接藏掉。
  // 判定按绑定的账号集合而不是默认工具：默认 Codex、同时绑定 Claude 的实例仍可用。
  const claude = instanceTools(sess).includes("claude");
  $("tab-btn-skills").classList.toggle("hidden", !claude || !!S.project);
  $("tab-btn-mcp").classList.toggle("hidden", !claude || !!S.project);
  if (!claude && (S.tab === "skills" || S.tab === "mcp")) setTab("chat");
  const running = sess.status === "running";
  const state = sessionState(sess);
  const pill = $("wb-state");
  pill.className = "state-pill " + state.cls;
  pill.textContent = state.label;
  setTip(pill, state.tip);
  if (!S.actionBusy) { // 启动/停止执行中由按钮自己管理，轮询刷新不得把另一个按钮换回来
    $("btn-start").classList.toggle("hidden", running);
    $("btn-stop").classList.toggle("hidden", !running);
  }
}


function closeChannels() {
  browserDisconnect();
  chatTeardown();
  termTeardown();
  closeThreadPanel();
}

bus.addEventListener("open-session", (e) => openSession((e as CustomEvent<Session>).detail));
bus.addEventListener("data-updated", () => { if (S.current) renderHead(); });

/* ---------------- 标签页 ---------------- */

export function setTab(name: Tab) {
  if (S.tab === "browser" && name !== "browser") browserDisconnect();
  if (S.project && name !== "term" && name !== "files") name = "term";
  S.tab = name;
  emit("navigation-changed");
  for (const t of document.querySelectorAll<HTMLElement>(".tab")) {
    t.classList.toggle("active", t.dataset.tab === name);
  }
  $("tab-chat").classList.toggle("hidden", name !== "chat");
  $("tab-term").classList.toggle("hidden", name !== "term");
  $("tab-files").classList.toggle("hidden", name !== "files");
  $("tab-changes").classList.toggle("hidden", name !== "changes");
  $("tab-skills").classList.toggle("hidden", name !== "skills");
  $("tab-mcp").classList.toggle("hidden", name !== "mcp");
  $("tab-browser").classList.toggle("hidden", name !== "browser");
  if (name === "browser") void showBrowser();
  if (name === "files") loadFiles();
  if (name === "changes") loadChanges();
  if (name === "skills") loadSkills();
  if (name === "term") openTerm(); // 进入即自动拉起 shell；已连上则只重排尺寸
  // 「本会话已花」只在终端页轮询：切走了没人看，没必要一直问服务端。
  termSpendPolling(name === "term");
}

for (const t of document.querySelectorAll<HTMLElement>(".tab")) {
  t.addEventListener("click", () => setTab(t.dataset.tab as Tab));
}

/* ---------------- 生命周期：启动 / 停止 / 删除 ---------------- */

async function doStart() {
  const s = S.current; if (!s || S.actionBusy) return;
  S.actionBusy = true;
  wbBusy("start");
  btnBusy($("btn-start"), "启动中…");
  try {
    const res = await api<Session>(`/sessions/${s.id}/start`, { method: "POST" });
    if (S.current && S.current.id === s.id) S.current = res; // 期间切换了会话则不覆盖
  } catch (e) { toast("启动失败：" + (e as Error).message, true); }
  S.actionBusy = false;
  wbIdle();
  btnDone($("btn-start"));
  renderHead(); refreshAll();
}

async function doStop() {
  const s = S.current; if (!s || S.actionBusy) return;
  S.actionBusy = true;
  wbBusy("stop");
  btnBusy($("btn-stop"), "停止中…");
  try {
    const res = await api<Session>(`/sessions/${s.id}/stop`, { method: "POST" });
    if (S.current && S.current.id === s.id) S.current = res;
    browserDisconnect();
    termDisconnect(); // 容器停了收掉连接，但保留终端画面
  } catch (e) { toast("停止失败：" + (e as Error).message, true); }
  S.actionBusy = false;
  wbIdle();
  btnDone($("btn-stop"));
  renderHead(); refreshAll();
}

function openDeleteDlg() {
  if (!S.current) return;
  const accounts = boundAccounts(S.current).map(account => `${agentName(account.tool)}：${account.label}`).join("；");
  $("del-text").textContent =
    `确认删除实例「${S.current.name}」？实例将从列表移除，容器被删除。` +
    (accounts ? `绑定账号：${accounts}。` : "") +
    `文件、配置和对话记录默认保留在服务器磁盘上。`;
  $<HTMLInputElement>("del-purge").checked = false;
  syncDeleteLabel();
  $<HTMLDialogElement>("dlg-del").showModal();
}

/* 勾选「同时清除」后按钮写明后果，不让同一个「删除」承担两种轻重 */
function syncDeleteLabel() {
  const purge = $<HTMLInputElement>("del-purge").checked;
  actionButton($("del-ok"), purge ? "删除并清除文件" : "删除", "trash");
}
$("del-purge").addEventListener("change", syncDeleteLabel);

$("btn-start").addEventListener("click", doStart);
$("btn-stop").addEventListener("click", doStop);

/* 工作台头部 ⋯ 与窄屏顶栏 ⋯ 共用一份菜单；窄屏没有头部，启动/停止也放进去。
 * 删除与启停不在同一层级：删除只在菜单最后一项。 */
function sessionMenu(withPower: boolean): MenuItem[] {
  const s = S.current;
  if (!s) return [];
  const running = s.status === "running";
  return [
    { label: "启动", icon: "play", run: doStart, hidden: !withPower || running, disabled: S.actionBusy },
    { label: "停止", icon: "stop", run: doStop, hidden: !withPower || !running, disabled: S.actionBusy, tip: "停止工作空间，保留文件与对话" },
    { label: "查看账号额度", icon: "gauge", run: openAcctUsage, hidden: agentKey(s.agent) !== "claude", sep: true, tip: "该账号订阅的 5 小时 / 每周用量窗口" },
    { label: "重命名", icon: "rename", run: renameSession, sep: agentKey(s.agent) !== "claude" },
    { label: "删除工作空间…", icon: "trash", danger: true, sep: true, run: openDeleteDlg, disabled: S.actionBusy },
  ];
}
bindMenu($("btn-wb-more"), () => sessionMenu(false));
bindMenu($("btn-kebab"), () => sessionMenu(true));
/* 会话改名：只改展示名，id / 目录 / 容器名都从 id 派生，不受影响 */
async function renameSession() {
  const sess = S.current; if (!sess) return;
  const name = await askPrompt({
    title: "重命名实例",
    label: "实例名称",
    value: sess.name,
    hint: "1–64 个字符，仅修改实例名称，文件与对话记录保留。",
    validate: (v) => {
      const t = v.trim();
      if (!t) return "名称不能为空";
      if ([...t].length > 64) return "名称最多 64 个字符";
      return "";
    },
  });
  if (name === null) return;
  try {
    const res = await api<Session>(`/sessions/${sess.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: name.trim() }),
    });
    if (S.current && S.current.id === sess.id) S.current = res;
    renderHead();
    renderSidebar();
    refreshAll();
    toast("实例已重命名");
  } catch (e) { toast("重命名失败：" + (e as Error).message, true); }
}

$("del-cancel").addEventListener("click", () => $<HTMLDialogElement>("dlg-del").close());
$("del-close").addEventListener("click", () => $<HTMLDialogElement>("dlg-del").close());
let delBusy = false;
$("dlg-del").addEventListener("cancel", (e) => { if (delBusy) e.preventDefault(); }); // 删除中禁止 Esc 关闭
$("del-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const s = S.current; if (!s || delBusy) return;
  delBusy = true;
  btnBusy($("del-ok"), "删除中…");
  $<HTMLButtonElement>("del-cancel").disabled = true;
  $<HTMLButtonElement>("del-close").disabled = true;
  const purge = $<HTMLInputElement>("del-purge").checked ? "?purge=1" : "";
  try {
    await api(`/sessions/${s.id}${purge}`, { method: "DELETE" });
    $<HTMLDialogElement>("dlg-del").close();
    closeChannels();
    S.current = null;
    $("workbench").classList.add("hidden");
    $("empty").classList.remove("hidden");
    updateTopbarTitle();
    emit("navigation-changed");
    refreshAll();
  } catch (err) { toast("删除失败：" + (err as Error).message, true); }
  delBusy = false;
  btnDone($("del-ok"));
  $<HTMLButtonElement>("del-cancel").disabled = false;
  $<HTMLButtonElement>("del-close").disabled = false;
});

/* ---------------- 新建实例 ---------------- */

/* 无可用代理或未加载完成时，代理下拉里放一条禁用的占位，提交按钮也会跟着禁用，
 * 不让用户对着一个空下拉点「创建」再收到 400。 */
const NO_PROXY = "";

const newProxySelect = () => $<HTMLSelectElement>("new-proxy");

async function loadInstanceProxies(token: string) {
  const select = newProxySelect();
  select.replaceChildren(Object.assign(document.createElement("option"), { value: NO_PROXY, textContent: "正在读取代理…" }));
  select.disabled = true;
  try {
    const options = await api<InstanceProxyOption[]>("/instances/proxies", { signal: AbortSignal.timeout(15000) });
    if (token !== S.token) return;
    fillProxySelect(select, Array.isArray(options) ? options : []);
  } catch (error) {
    if (token !== S.token) return;
    // 读不到就明说，免得用户以为代理池是空的；仍可选择直连。
    select.replaceChildren(Object.assign(document.createElement("option"), { value: NO_PROXY, textContent: "不绑定（读取代理列表失败，服务器直连）" }));
    toast("读取代理列表失败：" + (error as Error).message, true);
  } finally {
    if (token === S.token) select.disabled = false;
  }
}

function fillProxySelect(select: HTMLSelectElement, options: InstanceProxyOption[]) {
  select.replaceChildren();
  // 只有标注为住宅的代理可用于新实例；未标注是历史代理，服务端会拒绝。
  const usable = options.filter(option => option.kind === "residential");
  // 代理可选：留空即实例走服务器自身出口。
  select.append(Object.assign(document.createElement("option"), { value: NO_PROXY, textContent: "不绑定（服务器直连）" }));
  for (const option of usable) select.append(Object.assign(document.createElement("option"), { value: option.id, textContent: option.name }));
}

function accountOptionsFor(tool: "claude" | "codex") {
  return S.accounts.filter(account => account.type === tool);
}

/** 只填「可选」账号下拉：类型下没有账号时给一条禁用的占位，而不是静默空着。 */
function fillOptionalAccountSelect(id: string, tool: "claude" | "codex") {
  const select = $<HTMLSelectElement>(id);
  select.replaceChildren(Object.assign(document.createElement("option"), { value: "", textContent: "不绑定" }));
  // 一个账号只能绑定一个实例：已被占用的列出来但不可选，并说明被谁占用。
  for (const account of accountOptionsFor(tool)) {
    const taken = !!account.bound;
    select.append(Object.assign(document.createElement("option"), {
      value: account.id,
      disabled: taken,
      textContent: taken
        ? `${account.label}（${account.bound_instance ? "已绑定：" + account.bound_instance : "已被其他实例占用"}）`
        : account.label,
    }));
  }
  if (!accountOptionsFor(tool).length) {
    select.append(Object.assign(document.createElement("option"), { value: "", textContent: `没有可用的 ${agentName(tool)} 账号`, disabled: true }));
  }
}

/** 默认工具下拉只列出真的绑定了账号的那一侧，并随两个账号下拉即时更新。 */
function fillDefaultAgentSelect() {
  const select = $<HTMLSelectElement>("new-default-agent");
  const previous = select.value;
  const bound: ("claude" | "codex")[] = [];
  if ($<HTMLSelectElement>("new-account-claude").value) bound.push("claude");
  if ($<HTMLSelectElement>("new-account-codex").value) bound.push("codex");
  select.replaceChildren();
  if (!bound.length) {
    select.append(Object.assign(document.createElement("option"), { value: "", textContent: "先绑定至少一个账号" }));
    return;
  }
  for (const tool of bound) select.append(Object.assign(document.createElement("option"), { value: tool, textContent: agentName(tool) }));
  setSelectValue(select, bound.includes(previous as "claude" | "codex") ? previous : bound[0]!);
}

function fillNewInstanceForm() {
  fillOptionalAccountSelect("new-account-claude", "claude");
  fillOptionalAccountSelect("new-account-codex", "codex");
  fillDefaultAgentSelect();
  const submit = $<HTMLButtonElement>("new-ok");
  const all = [...accountOptionsFor("claude"), ...accountOptionsFor("codex")];
  const free = all.filter(account => !account.bound).length;
  submit.disabled = !free;
  $("new-account-hint").textContent = !all.length
    ? "账号池里还没有你能使用的账号，请先在系统设置里添加。"
    : !free
      ? "所有账号都已绑定到实例（一个账号只能绑定一个实例），请先在系统设置里添加新账号。"
      : "至少绑定一个账号；一个账号只能绑定一个实例，只有绑定过的工具才能出现在项目的开发工具里。";
}

/* 侧栏字标 = 首页入口：放下当前会话回到空状态（只断前端通道，容器不动） */
export function openHome() {
  if (S.current) {
    closeChannels();
    S.current = null;
  }
  S.project = null;
  $("workbench").classList.add("hidden");
  $("empty").classList.remove("hidden");
  showView("work"); /* 已在工作台时走早退分支，仍会收抽屉 */
  updateTopbarTitle();
  renderSidebar();
  emit("navigation-changed");
  emit("projects-home");
}
$("btn-home").addEventListener("click", openHome);
$("btn-projects").addEventListener("click", openHome);

$("btn-new-workspace").addEventListener("click", async () => {
  fillNewInstanceForm();
  $("new-error").classList.add("hidden");
  $<HTMLDialogElement>("dlg-new").showModal();
  const token = S.token;
  const picker = $<HTMLSelectElement>("new-git-connection");
  picker.replaceChildren(Object.assign(document.createElement("option"), {value:"",textContent:"不绑定"}));
  picker.disabled = true;
  void loadInstanceProxies(token);
  try {
    const [cs, def] = await Promise.all([api<GitConnection[]>("/git/connections"),api<{connection_id:string}>("/me/git/default")]);
    if (token !== S.token || !$<HTMLDialogElement>("dlg-new").open) return;
    for (const c of cs) if (c.enabled) picker.append(Object.assign(document.createElement("option"),{value:c.id,textContent:c.label}));
    setSelectValue(picker,def.connection_id);
  } catch (e) { if(token === S.token) toast("读取 Git 连接失败，可选择不绑定后创建："+(e as Error).message,true); }
  finally { picker.disabled = false; }
});
$("new-cancel").addEventListener("click", () => $<HTMLDialogElement>("dlg-new").close());

/* 默认工具跟着两个账号下拉走：绑定变了，可选工具就跟着变，避免提交一个「默认工具
 * 没绑定账号」的组合让服务端打回。 */
for (const id of ["new-account-claude", "new-account-codex"]) {
  $(id).addEventListener("change", fillDefaultAgentSelect);
}

$("new-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $<HTMLInputElement>("new-name").value.trim();
  const claudeID = $<HTMLSelectElement>("new-account-claude").value;
  const codexID = $<HTMLSelectElement>("new-account-codex").value;
  const proxyID = newProxySelect().value;
  const fail = (message: string) => {
    $("new-error").textContent = message;
    $("new-error").classList.remove("hidden");
  };
  if (!name || [...name].length > 64) {
    fail("请填写实例名称（1–64 个字符）。");
    return;
  }
  if (!claudeID && !codexID) {
    fail("请至少绑定一个账号。");
    return;
  }
  const body = {
    name,
    claude_account_id: claudeID,
    codex_account_id: codexID,
    proxy_id: proxyID,
    default_agent: $<HTMLSelectElement>("new-default-agent").value,
    git_connection_id: $<HTMLSelectElement>("new-git-connection").value,
  };
  btnBusy($("new-ok"), "创建中…");
  $<HTMLButtonElement>("new-cancel").disabled = true;
  try {
    await api<Session>("/sessions", { method: "POST", body: JSON.stringify(body) });
    $<HTMLDialogElement>("dlg-new").close();
    $<HTMLInputElement>("new-name").value = "";
    await refreshAll();
    showView("workspaces");
    toast("实例已创建，现在可以在其中新建项目");
  } catch (err) {
    $("new-error").textContent = (err as Error).message;
    $("new-error").classList.remove("hidden");
  } finally {
    btnDone($("new-ok"));
    $<HTMLButtonElement>("new-cancel").disabled = false;
  }
});
