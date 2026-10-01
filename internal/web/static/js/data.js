/* data：sessions / accounts 的拉取与轮询。拉到新数据后广播 data-updated，
 * 由 shell（侧栏）、sessions（工作台头部）、settings（账号池）各自刷新。 */
"use strict";
import { Poller } from "./shared/poller.js";
import { S, emit } from "./state.js";
import { api } from "./api.js";
import { agentKey, agentName } from "./brand.js";
/** 账号池里的展示名；查不到时回退 id，绝不显示空白。 */
export function accountLabel(id) {
    if (!id)
        return "";
    return S.accounts.find(account => account.id === id)?.label || id;
}
/** 实例绑定的账号，按工具拆开。
 *
 * 一个实例可以同时绑 Claude 和 Codex。服务端下发的 *_account_id 是权威来源；
 * 只带旧 account_id 的行（尚未回填）按默认工具归位，界面才不会把老实例显示成
 * 「未绑定账号」。放在 data.js 而不是 shell.js/sessions.js：这三个模块互相引用
 * 会成环，而 data.js 只依赖 state/api。 */
export function boundAccounts(sess) {
    const out = [];
    for (const tool of ["claude", "codex"]) {
        const id = (tool === "claude" ? sess.claude_account_id : sess.codex_account_id) || "";
        if (!id)
            continue;
        const label = (tool === "claude" ? sess.claude_account_label : sess.codex_account_label) || accountLabel(id);
        out.push({ tool, id, label });
    }
    if (!out.length && sess.account_id) {
        out.push({ tool: agentKey(sess.agent), id: sess.account_id, label: sess.account_label || accountLabel(sess.account_id) });
    }
    return out;
}
/** 实例当前可用的工具；项目里的开发工具只在这几个里选。 */
export function instanceTools(sess) {
    return boundAccounts(sess).map(account => account.tool);
}
/** 实例的工具概览文案，例如「Claude Code + Codex CLI」。 */
export function instanceToolsLabel(sess) {
    const tools = boundAccounts(sess);
    return tools.length ? tools.map(account => agentName(account.tool)).join(" + ") : "未绑定账号";
}
export async function refreshAll(signal) {
    try {
        // 顺带把 /me 拉一遍：余额只在回合结束时变，而 chat.ts 正是在回合收尾
        // 调 refreshAll，所以额度显示会紧跟着扣款更新。
        const [sessions, accounts, me] = await Promise.all([
            api("/sessions", { signal }), api("/accounts", { signal }), api("/me", { signal }),
        ]);
        if (signal?.aborted)
            return;
        S.sessions = sessions;
        S.accounts = accounts;
        S.quota = me.quota || null;
        if (me.timezone && me.timezone !== S.timeZone) {
            S.timeZone = me.timezone;
            emit("timezone-updated");
        }
        if (S.current) {
            const cur = sessions.find((x) => x.id === S.current.id);
            if (cur)
                S.current = cur;
        }
        emit("data-updated");
    }
    catch (_) { /* 网络抖动时保持现状 */ }
}
const polling = new Poller();
export function startPolling() { polling.start(8000, signal => refreshAll(signal)); }
export function stopPolling() { polling.stop(); }
