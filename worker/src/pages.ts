/** Small server-rendered pages: login, OAuth consent, and errors. */

export function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
    },
  });
}

export function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export const baseStyles = `
  :root { color-scheme: dark; --bg: #0b0c0f; --panel: #15171c; --line: #262a33; --text: #eef0f4; --muted: #8b92a1; --accent: #7cc4ff; --danger: #ff7a7a; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  .card { max-width: 380px; margin: 12vh auto 0; padding: 28px; background: var(--panel); border: 1px solid var(--line); border-radius: 18px; }
  h1 { font-size: 20px; margin: 0 0 6px; letter-spacing: -0.01em; }
  p { margin: 0 0 18px; color: var(--muted); }
  label { display: block; font-size: 13px; color: var(--muted); margin-bottom: 6px; }
  input[type=password] { width: 100%; padding: 12px 14px; border-radius: 10px; border: 1px solid var(--line); background: #0f1115; color: var(--text); font-size: 16px; }
  input[type=password]:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  .row { display: flex; gap: 10px; margin-top: 16px; }
  button { flex: 1; padding: 12px 14px; border-radius: 10px; border: 1px solid var(--line); background: #1d2027; color: var(--text); font-size: 15px; font-weight: 600; cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #06121d; }
  .error { color: var(--danger); font-size: 14px; margin: 10px 0 0; }
  .mark { display: inline-flex; align-items: center; gap: 8px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 18px; }
  .mark i { width: 10px; height: 10px; border-radius: 3px; background: var(--accent); display: inline-block; }
  code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: #0f1115; border: 1px solid var(--line); border-radius: 6px; padding: 1px 5px; word-break: break-all; }
`;

function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(title)} · minirun</title><style>${baseStyles}</style></head><body>${body}</body></html>`;
}

export function loginPage(options: { error?: string; next?: string }): string {
  return page("Log in", `<form class="card" method="post" action="/login">
  <div class="mark"><i></i>minirun</div>
  <h1>Log in</h1>
  <p>Enter your minirun password to watch and control your Mac's simulators.</p>
  <label for="password">Password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" autofocus required>
  <input type="hidden" name="next" value="${escapeHTML(options.next ?? "/")}">
  ${options.error ? `<div class="error">${escapeHTML(options.error)}</div>` : ""}
  <div class="row"><button class="primary" type="submit">Log in</button></div>
</form>`);
}

export function authorizePage(options: { clientName: string; redirectUri: string; state: string; error?: string }): string {
  let host = options.redirectUri;
  try {
    host = new URL(options.redirectUri).host;
  } catch {
    // keep the raw value
  }
  return page("Connect", `<form class="card" method="post" action="/authorize">
  <div class="mark"><i></i>minirun</div>
  <h1>Connect ${escapeHTML(options.clientName)}?</h1>
  <p>It will be able to build apps and control the simulators on your Mac. You'll be sent back to <code>${escapeHTML(host)}</code>.</p>
  <label for="password">Your minirun password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" autofocus>
  <input type="hidden" name="state" value="${escapeHTML(options.state)}">
  ${options.error ? `<div class="error">${escapeHTML(options.error)}</div>` : ""}
  <div class="row">
    <button type="submit" name="action" value="deny" formnovalidate>Cancel</button>
    <button class="primary" type="submit" name="action" value="approve">Connect</button>
  </div>
</form>`);
}

export function messagePage(title: string, message: string): string {
  return page(title, `<div class="card"><div class="mark"><i></i>minirun</div><h1>${escapeHTML(title)}</h1><p>${escapeHTML(message)}</p></div>`);
}
