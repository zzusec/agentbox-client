import { S, bus } from "./state.js";
import { api } from "./api.js";
import { $, btnBusy, btnDone, toast } from "./util.js";
import { setSelectValue } from "./select.js";
import { openHome, openSession } from "./sessions.js";
import { showView } from "./shell.js";
import { svgIcon } from "./chat-render.js";
import { agentName } from "./brand.js";
import { buttonLabel } from "./icons.js";
export function initProjects() {
    const lifetime = new AbortController();
    const options = { signal: lifetime.signal };
    const dialog = $("dlg-project");
    let request = null;
    let rows = [];
    let busy = false;
    let loaded = false;
    function text(tag, className, value) {
        const element = document.createElement(tag);
        element.className = className;
        element.textContent = value;
        return element;
    }
    function button(label, action, primary = false) {
        const element = document.createElement("button");
        element.type = "button";
        element.className = "btn" + (primary ? " btn-primary" : "");
        buttonLabel(element, label, primary ? "plus" : "folder");
        element.addEventListener("click", action);
        return element;
    }
    function fillWorkspaces(select, all, preferred = select.value) {
        select.replaceChildren();
        if (all)
            select.append(new Option("全部工作空间", ""));
        for (const session of S.sessions)
            select.append(new Option(session.name, session.id));
        if (!S.sessions.length && !all)
            select.append(new Option("请先创建工作空间", ""));
        setSelectValue(select, [...select.options].some(option => option.value === preferred) ? preferred : select.options[0]?.value || "");
    }
    function openCreate(sessionID = "") {
        fillWorkspaces($("project-workspace"), false, sessionID);
        $("project-form").reset();
        setSelectValue($("project-workspace"), sessionID || S.sessions[0]?.id || "");
        $("project-error").classList.add("hidden");
        $("project-no-workspace").classList.toggle("hidden", !!S.sessions.length);
        $("project-ok").disabled = !S.sessions.length;
        dialog.showModal();
    }
    function renderWorkspaces() {
        const list = $("workspace-grid");
        list.replaceChildren();
        $("workspace-total").textContent = String(S.sessions.length);
        $("workspace-running").textContent = String(S.sessions.filter(session => session.status === "running").length);
        $("workspace-accounts").textContent = String(new Set(S.sessions.map(session => session.account_id)).size);
        $("workspace-empty").classList.toggle("hidden", !!S.sessions.length);
        for (const session of S.sessions) {
            const card = document.createElement("article");
            card.className = "workspace-tile";
            const heading = document.createElement("div");
            heading.className = "tile-heading";
            const icon = document.createElement("span");
            icon.className = "console-icon";
            icon.append(svgIcon("folder", 20));
            heading.append(icon, text("h2", "tile-title", session.name), text("span", "console-status" + (session.status === "running" ? " running" : ""), session.status === "running" ? "运行中" : "已停止"));
            const details = document.createElement("dl");
            details.className = "workspace-details";
            for (const [label, value] of [["绑定账号", session.account_label || session.account_id], ["Agent", agentName(session.agent)], ["容器", session.container_id || "尚未创建"], ["出口代理", "沿用账号的现有配置"]]) {
                details.append(text("dt", "", label), text("dd", "", value));
            }
            const actions = document.createElement("div");
            actions.className = "tile-actions";
            actions.append(button("进入工作空间", () => { void openSession(session); }), button("新建项目", () => openCreate(session.id), true));
            card.append(heading, details, actions);
            list.append(card);
        }
    }
    function renderProjects() {
        const list = $("project-grid");
        const filter = $("project-filter").value;
        const query = $("project-search").value.trim().toLocaleLowerCase();
        const failed = rows.filter(row => row.error);
        const total = rows.reduce((count, row) => count + row.projects.length, 0);
        $("project-total").textContent = loaded ? String(total) + (failed.length ? "+" : "") : "—";
        $("project-workspace-total").textContent = String(S.sessions.length);
        $("project-running-total").textContent = String(S.sessions.filter(session => session.status === "running").length);
        $("projects-load-error").textContent = failed.map(row => `${row.session.name}：${row.error}`).join("；");
        $("projects-load-error").classList.toggle("hidden", !failed.length);
        const focus = document.activeElement?.closest("[data-project-id]")?.dataset.projectId;
        list.replaceChildren();
        let visible = 0;
        for (const row of rows) {
            if (filter && filter !== row.session.id)
                continue;
            for (const project of row.projects) {
                if (query && !`${project.name} ${row.session.name}`.toLocaleLowerCase().includes(query))
                    continue;
                visible++;
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
                footer.append(text("span", "", agentName(row.session.agent)), text("span", "project-open-label", "打开终端"));
                card.append(icon, body, footer);
                card.addEventListener("click", () => { void openSession(row.session, "term", project); });
                list.append(card);
                if (focus === project.id)
                    card.focus({ preventScroll: true });
            }
        }
        $("project-empty-state").classList.toggle("hidden", !!visible);
        $("project-empty-title").textContent = !loaded ? "正在读取项目…" : failed.length && !total ? "暂时无法读取项目" : total && !visible ? "没有匹配的项目" : "创建你的第一个项目";
        $("project-empty-desc").textContent = !loaded ? "读取现有工作空间中的项目目录。" : failed.length && !total ? "检查连接后点击刷新重试，不会更改现有工作空间。" : total && !visible ? "尝试其他关键词，或切换工作空间。" : S.sessions.length ? "选择一个工作空间，新项目将共享它的账号、代理和容器。" : "先在工作空间配置中创建工作空间，再在这里添加项目。";
        $("project-empty-create").classList.toggle("hidden", !loaded || !!total || !!failed.length || !S.sessions.length);
        $("project-empty-configure").classList.toggle("hidden", !loaded || !!S.sessions.length);
        $("project-result-count").textContent = loaded ? `${visible} 个项目` : "读取中…";
    }
    async function load() {
        renderWorkspaces();
        if (S.view !== "workspaces" && (S.view !== "work" || S.current))
            return;
        request?.abort();
        const controller = request = new AbortController();
        rows = rows.filter(row => S.sessions.some(session => session.id === row.session.id));
        fillWorkspaces($("project-filter"), true);
        renderProjects();
        const result = await Promise.all(S.sessions.map(async (session) => {
            try {
                const projects = await api(`/sessions/${encodeURIComponent(session.id)}/projects`, { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15000)]) });
                if (!Array.isArray(projects))
                    throw new Error("项目列表格式不正确，请重试");
                return { session, projects, error: "" };
            }
            catch (error) {
                return { session, projects: [], error: error.message };
            }
        }));
        if (controller.signal.aborted || lifetime.signal.aborted)
            return;
        rows = result;
        loaded = true;
        renderProjects();
    }
    const configure = () => { showView("workspaces"); void load(); };
    bus.addEventListener("open-workspaces", configure, options);
    bus.addEventListener("projects-home", () => { void load(); }, options);
    bus.addEventListener("data-updated", () => { void load(); }, options);
    $("btn-workspaces").addEventListener("click", configure, options);
    $("project-empty-configure").addEventListener("click", configure, options);
    $("project-configure").addEventListener("click", () => { dialog.close(); configure(); }, options);
    for (const id of ["btn-new", "empty-new", "project-empty-create"]) {
        $(id).addEventListener("click", () => openCreate(), options);
    }
    $("project-refresh").addEventListener("click", () => { void load(); }, options);
    $("project-filter").addEventListener("change", renderProjects, options);
    $("project-search").addEventListener("input", renderProjects, options);
    $("project-cancel").addEventListener("click", () => dialog.close(), options);
    dialog.addEventListener("cancel", event => { if (busy)
        event.preventDefault(); }, options);
    $("project-form").addEventListener("submit", async (event) => {
        event.preventDefault();
        if (busy)
            return;
        const sessionID = $("project-workspace").value;
        const name = $("project-name").value.trim();
        $("project-error").classList.add("hidden");
        if (!S.sessions.some(session => session.id === sessionID) || !name || name.startsWith(".") || /[\/\\\u0000]/.test(name)) {
            $("project-error").textContent = "请选择工作空间；项目名称不能以点开头或包含路径分隔符。";
            $("project-error").classList.remove("hidden");
            return;
        }
        busy = true;
        btnBusy($("project-ok"), "创建中…");
        $("project-cancel").disabled = true;
        try {
            await api(`/sessions/${encodeURIComponent(sessionID)}/projects`, {
                method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name }), signal: lifetime.signal,
            });
            if (lifetime.signal.aborted)
                return;
            dialog.close();
            $("project-search").value = "";
            setSelectValue($("project-filter"), "");
            openHome();
            toast("项目已创建");
        }
        catch (error) {
            if (lifetime.signal.aborted)
                return;
            $("project-error").textContent = error.message;
            $("project-error").classList.remove("hidden");
        }
        finally {
            busy = false;
            if (!lifetime.signal.aborted) {
                btnDone($("project-ok"));
                $("project-cancel").disabled = false;
            }
        }
    }, options);
    renderProjects();
    renderWorkspaces();
    return () => {
        lifetime.abort();
        request?.abort();
        dialog.close();
        rows = [];
        loaded = false;
        $("project-grid").replaceChildren();
        $("workspace-grid").replaceChildren();
        $("project-form").reset();
        btnDone($("project-ok"));
        $("project-cancel").disabled = false;
        $("project-workspace").replaceChildren();
        $("project-filter").replaceChildren(new Option("全部工作空间", ""));
        $("project-search").value = "";
    };
}
