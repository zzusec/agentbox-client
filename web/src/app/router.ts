import { S, bus, emit } from "../state.js";
import type { Tab } from "../state.js";
import { openHome, openSession } from "../sessions.js";
import { SET_SECS } from "../settings.js";
import { toast } from "../util.js";
import { api } from "../api.js";
import type { Project } from "../types.js";

const GIT_SECS = ["guide", "profile", "connections"];

const TABS: Tab[] = ["chat", "term", "files", "changes", "skills", "mcp", "browser"];

function currentHash() {
  if (S.view === "git") return `#/git/${S.gitSec}`;
  if (S.view === "settings") return `#/settings/${S.sec}`;
  if (S.view !== "work") return `#/${S.view}`;
  if (S.current && S.project) return `#/projects/${encodeURIComponent(S.current.id)}/${encodeURIComponent(S.project.id)}/${S.tab}`;
  return S.current ? `#/sessions/${encodeURIComponent(S.current.id)}/${S.tab}` : "#/";
}

/** Hash routes work with the embedded static server and existing reverse proxies. */
export function initRouter() {
  const lifetime = new AbortController();
  const options = { signal: lifetime.signal };
  let ready = false;
  let applying = false;
  let queued = false;
  let generation = 0;
  let awaitingProject = false;

  function write(replace: boolean) {
    const hash = currentHash();
    if (location.hash !== hash) {
      history[replace ? "replaceState" : "pushState"](null, "", hash);
    }
  }

  async function restore() {
    if (!ready) return; // Keep the destination while waiting for login and session data.
    const request = ++generation;
    awaitingProject = false;
    applying = true;
    try {
      let parts: string[] = [];
      try { parts = location.hash.slice(1).split("/").slice(1).map(decodeURIComponent); } catch { /* invalid URL → home */ }
      const [page, id, tab, projectTab] = parts;
      if (page === "workspaces" && parts.length === 1) {
        emit("open-workspaces");
      } else if (page === "projects" && id && tab && parts.length <= 4) {
        const session = S.sessions.find(sess => sess.id === id);
        if (!session) throw new Error("工作空间不存在或无权访问");
        awaitingProject = true;
        const projects = await api<Project[]>(`/sessions/${encodeURIComponent(id)}/projects`, { signal: AbortSignal.any([lifetime.signal, AbortSignal.timeout(15000)]) });
        if (request !== generation || !ready) return;
        awaitingProject = false;
        if (!Array.isArray(projects)) throw new Error("项目列表格式不正确");
        const project = projects.find(item => item.id === tab);
        if (!project) throw new Error("项目不存在或无权访问");
        await openSession(session, projectTab === "files" ? "files" : "term", project);
      } else if ((page === "usage" || page === "tunnel") && parts.length === 1) {
        emit(`open-${page}`);
      } else if (page === "git" && parts.length <= 2) {
        emit("open-git", GIT_SECS.includes(id) ? id : "guide");
      } else if (page === "settings" && parts.length <= 2 && S.role === "admin") {
        S.sec = SET_SECS.includes(id) ? id : "accounts";
        emit("open-settings");
      } else if (page === "sessions" && id && parts.length <= 3) {
        const session = S.sessions.find(s => s.id === id);
        if (session) {
          const target = TABS.includes(tab as Tab) ? tab as Tab : "chat";
          void openSession(session, target);
        } else {
          openHome();
          toast("该工作空间不存在或无权访问", true);
        }
      } else {
        openHome();
      }
      write(true); // Normalize invalid/inaccessible destinations without adding history.
    } catch (error) {
      if (request !== generation || !ready) return;
      awaitingProject = false;
      openHome();
      toast("无法打开项目：" + (error as Error).message, true);
      write(true);
    } finally {
      if (request === generation) applying = false;
    }
  }

  bus.addEventListener("app-ready", () => { ready = true; restore(); }, options);
  bus.addEventListener("signed-out", () => { ready = false; generation++; applying = false; awaitingProject = false; }, options);
  window.addEventListener("pagehide", () => { ready = false; generation++; }, options);
  window.addEventListener("hashchange", restore, options);
  bus.addEventListener("navigation-changed", () => {
    if (awaitingProject) { generation++; applying = false; awaitingProject = false; }
    if (!ready || applying || queued) return;
    queued = true;
    // Opening a workspace updates view, session and tab together. Record only the final state.
    queueMicrotask(() => {
      queued = false;
      if (ready) write(false);
    });
  }, options);
  return () => { ready = false; generation++; lifetime.abort(); };
}
