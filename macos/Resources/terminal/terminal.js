// The Mac app's terminal: xterm.js draws, Swift owns the socket.
//
// This is the engine the web console already runs against the same socket
// protocol, so both clients draw a session the same way. Swift keeps the
// connection (reconnects, heartbeats, the upload hold) and talks to this page
// through two narrow channels:
//
//   Swift -> page: window.agentboxTerm.* (write output, configure, focus …)
//   page -> Swift: webkit.messageHandlers.term.postMessage({type, …})
//
// Output arrives base64-encoded, because the PTY stream is bytes, not text: a
// multi-byte character can be split across two chunks and only xterm.js's own
// decoder knows how to stitch it back together.
(() => {
  "use strict";

  const post = (message) => window.webkit.messageHandlers.term.postMessage(message);
  // The UMD builds put either the class or a namespace holding it on window,
  // depending on the bundle; accept both, as the web console does.
  const Terminal = window.Terminal.Terminal || window.Terminal;
  const FitAddon = window.FitAddon.FitAddon || window.FitAddon;
  const WebglAddon = window.WebglAddon && (window.WebglAddon.WebglAddon || window.WebglAddon);

  let settings = {
    fontFamily: "Monaco, monospace",
    fontSize: 13,
    autoFit: true,
    fitColumns: 100,
    mouse: "on",
    theme: {},
  };

  const term = new Terminal({
    allowProposedApi: true,
    scrollback: 10000,
    cursorBlink: true,
    fontFamily: settings.fontFamily,
    fontSize: settings.fontSize,
    // Option keeps producing macOS characters; ⌥-drag selects even while a
    // program has the mouse (⇧-drag is mapped onto it below).
    macOptionIsMeta: false,
    macOptionClickForcesSelection: true,
    linkHandler: {
      activate: (_event, uri) => post({ type: "link", uri }),
    },
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  const mount = document.getElementById("term");
  term.open(mount);
  // GPU rendering, as in the web console; on any failure xterm.js keeps its
  // DOM renderer.
  if (WebglAddon) {
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => webgl.dispose());
      term.loadAddon(webgl);
    } catch (_) { /* DOM renderer */ }
  }

  // ---- input -------------------------------------------------------------
  term.onData((data) => post({ type: "input", data }));
  // Some mouse reports are bytes rather than text.
  term.onBinary((data) => post({ type: "binary", data: btoa(data) }));
  term.onTitleChange((title) => post({ type: "title", title }));
  term.onBell(() => post({ type: "bell" }));

  // Programs copy to the clipboard with OSC 52 ("c;<base64>"); xterm.js core
  // does not, so it is handled here. A query ("?") is never answered — a
  // program has no business reading the user's clipboard.
  term.parser.registerOscHandler(52, (data) => {
    const payload = data.slice(data.indexOf(";") + 1);
    if (payload && payload !== "?") {
      try {
        const bytes = Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
        post({ type: "clipboard", text: new TextDecoder().decode(bytes) });
      } catch (_) { /* malformed: ignore */ }
    }
    return true;
  });

  // 鼠标上报 = 关闭: programs never get the mouse, so every drag selects and
  // the wheel scrolls this terminal's own history. Only sequences made of
  // mouse modes alone are dropped; anything mixed goes through untouched.
  //
  // What was held back is remembered, so switching back to 开启 hands the
  // program the mouse it asked for: a program asks once, at start-up, and
  // would otherwise stay deaf to clicks until it was restarted.
  const MOUSE_MODES = new Set([9, 1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016]);
  const heldMouseModes = new Set();
  const mouseModesOf = (params) => {
    const modes = params.map((p) => (Array.isArray(p) ? p[0] : p));
    return modes.length > 0 && modes.every((m) => MOUSE_MODES.has(m)) ? modes : null;
  };
  term.parser.registerCsiHandler({ prefix: "?", final: "h" }, (params) => {
    if (settings.mouse !== "off") return false;
    const modes = mouseModesOf(params);
    if (!modes) return false;
    modes.forEach((m) => heldMouseModes.add(m));
    return true;
  });
  // A program turning a mode off while it is held just forgets it.
  term.parser.registerCsiHandler({ prefix: "?", final: "l" }, (params) => {
    if (settings.mouse !== "off") return false;
    const modes = mouseModesOf(params);
    if (modes) modes.forEach((m) => heldMouseModes.delete(m));
    return false;
  });

  // ⇧-drag selects locally even while a program tracks the mouse — the gesture
  // people know from other terminals. xterm.js spells that ⌥-drag on macOS,
  // so the press is re-sent as one; the drag that follows is xterm's own.
  term.element.addEventListener("mousedown", (event) => {
    if (!event.isTrusted || !event.shiftKey || event.altKey) return;
    if (term.modes.mouseTrackingMode === "none") return;
    event.stopImmediatePropagation();
    event.preventDefault();
    event.target.dispatchEvent(new MouseEvent("mousedown", {
      bubbles: true, cancelable: true, view: window, detail: event.detail,
      screenX: event.screenX, screenY: event.screenY,
      clientX: event.clientX, clientY: event.clientY,
      button: event.button, buttons: event.buttons,
      altKey: true, shiftKey: false, ctrlKey: event.ctrlKey, metaKey: event.metaKey,
    }));
  }, true);

  // ---- size --------------------------------------------------------------
  // Columns and rows are decided in exactly one place: the fit addon, over
  // the element's real size. The old engine counted them two different ways
  // and the size sent to the server flipped between the results.
  term.onResize(({ cols, rows }) => post({ type: "resize", cols, rows }));

  function refit() {
    if (mount.clientWidth === 0 || mount.clientHeight === 0) return; // hidden tab
    const base = settings.fontSize;
    let size = base;
    if (settings.autoFit) {
      // 自动字号: shrink, never grow, until the target column count fits.
      // A monospaced cell scales with the point size, so the ratio is enough.
      if (term.options.fontSize !== base) term.options.fontSize = base;
      const dims = fit.proposeDimensions();
      if (dims && dims.cols > 0 && dims.cols < settings.fitColumns) {
        size = Math.max(8, Math.floor((base * dims.cols / settings.fitColumns) * 2) / 2);
      }
    }
    if (term.options.fontSize !== size) term.options.fontSize = size;
    fit.fit();
  }
  new ResizeObserver(() => refit()).observe(mount);

  // ---- API for Swift -----------------------------------------------------
  window.agentboxTerm = {
    write(base64) {
      term.write(Uint8Array.from(atob(base64), (c) => c.charCodeAt(0)));
    },
    configure(next) {
      const wasOff = settings.mouse === "off";
      settings = Object.assign({}, settings, next);
      term.options.theme = settings.theme;
      term.options.fontFamily = settings.fontFamily;
      // Cursor and line spacing follow the profile too when it says so.
      if (settings.cursorStyle) term.options.cursorStyle = settings.cursorStyle;
      if (typeof settings.cursorBlink === "boolean") term.options.cursorBlink = settings.cursorBlink;
      if (settings.lineHeight > 0) term.options.lineHeight = settings.lineHeight;
      document.body.style.background = settings.theme.background || "";
      if (settings.mouse === "off" && !wasOff) {
        // A program that already turned tracking on keeps it until it says
        // otherwise; switch it off locally so the setting applies right away,
        // and remember it so 开启 can give it back.
        // Exactly the tracking the program had, plus SGR encoding, which is
        // what current programs ask for and xterm.js does not report.
        const tracking = { x10: 9, vt200: 1000, drag: 1002, any: 1003 }[term.modes.mouseTrackingMode];
        if (tracking) {
          heldMouseModes.add(tracking);
          heldMouseModes.add(1006);
        }
        term.write("\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l");
      } else if (settings.mouse !== "off" && wasOff && heldMouseModes.size > 0) {
        // Hand back what the program asked for while the mouse was withheld.
        const modes = [...heldMouseModes];
        heldMouseModes.clear();
        term.write(modes.map((m) => `\x1b[?${m}h`).join(""));
      }
      refit();
    },
    refit,
    size() { return { cols: term.cols, rows: term.rows }; },
    focus() { term.focus(); },
    selection() { return term.getSelection(); },
    selectAll() { term.selectAll(); },
    bracketedPaste() { return term.modes.bracketedPasteMode; },
    paste(text) { term.paste(text); },
  };

  refit();
  post({ type: "ready", cols: term.cols, rows: term.rows });
})();
