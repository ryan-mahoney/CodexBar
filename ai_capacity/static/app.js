'use strict';

const $ = id => document.getElementById(id);
const names = {codex: 'Codex', claude: 'Claude', zai: 'Z.ai', qwencloud: 'Qwen Cloud', deepseek: 'DeepSeek', openrouter: 'OpenRouter'};
const access = {
  codex: 'Refresh the affected account’s login in Codex, then refresh this report.',
  claude: 'Refresh the affected account’s login in Claude Code, then refresh this report.',
  zai: 'Check the Coding Plan API key in OpenCode or the CodexBar configuration. Browser sign-in does not supply this key.',
  deepseek: 'Check the DeepSeek API key in OpenCode or the CodexBar configuration. Browser sign-in is not required.',
  openrouter: 'Check the OpenRouter key in OpenCode. If credit access is denied, set OPENROUTER_MANAGEMENT_API_KEY before you start the server.',
  qwencloud: 'Check the Qwen Cloud sign-in and cookie access. For a one-time cookie refresh, run the command below in a terminal.'
};
let current = null;
let reportSignature = '';
let connectionError = false;
let pending = false;
let manualPending = false;
let timer;
let clockOffset = 0;
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
const numeric = value => typeof value === 'number' && Number.isFinite(value);
const left = window => window && numeric(window.usedPercent) ? Math.max(0, 100 - window.usedPercent) : null;
const now = () => Date.now() + clockOffset;
const dateValue = value => value ? Date.parse(value) : NaN;

function duration(milliseconds) {
  const minutes = Math.max(0, Math.ceil(milliseconds / 60000));
  if (minutes < 1) return 'less than 1m';
  if (minutes >= 1440) return `${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`;
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes}m`;
}

function absolute(value, compact = false) {
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? new Intl.DateTimeFormat(undefined, {
    month:'short', day:'numeric', hour:'numeric', minute:'2-digit', ...(compact ? {} : {timeZoneName:'short'})
  }).format(date) : 'Not reported';
}

function isWeekly(window) {
  return window?.windowMinutes === 10080 || /\bweekly\b/i.test(window?.name || '');
}

function reset(window, prefix = '') {
  const name = prefix ? `<span class="reset-name">${esc(prefix)}</span> ` : '';
  if (!window?.resetsAt) return `<p class="time muted">${name}Not reported</p>`;
  const timestamp = dateValue(window.resetsAt);
  return `<p class="time muted" data-urgency-at="${isWeekly(window) ? timestamp : NaN}" data-remaining="${left(window) ?? -1}">${name}<span data-reset="${timestamp}">${resetText(timestamp)}</span><span aria-hidden="true"> · </span><time datetime="${esc(window.resetsAt)}" title="${esc(absolute(window.resetsAt))}">${esc(absolute(window.resetsAt, true))}</time></p>`;
}

function resetText(timestamp) {
  return timestamp > now() ? `in ${duration(timestamp - now())}` : 'Reset passed';
}

function percentage(value) {
  return value > 0 && value < 0.1 ? '&lt;0.1%' : `${Number(value.toFixed(1))}%`;
}

function capacity(window, withReset = true) {
  const remaining = left(window);
  if (remaining === null) return `<p class="unknown">Unknown</p>${window && withReset ? reset(window) : ''}`;
  return `<div class="capacity-value" data-urgency-at="${isWeekly(window) ? dateValue(window.resetsAt) : NaN}" data-remaining="${remaining}"><p class="numbers"><span class="percent ${remaining === 0 ? 'danger' : ''}">${percentage(remaining)}</span><span class="sr-only"> remaining</span></p>
    <div class="meter" aria-hidden="true"><span style="width:${remaining}%"></span></div></div>${withReset ? reset(window) : ''}`;
}

function splitWindows(row) {
  const weekly = row.windows.find(w => /^weekly$/i.test(w.name));
  const short = row.windows.find(w => /^(session|5[- ]hour|daily)$/i.test(w.name));
  return {weekly, short, extras: row.windows.filter(w => w !== weekly && w !== short)};
}

function cell(window, title, unavailable) {
  const shortReset = window?.resetsAt ? `<span data-reset="${dateValue(window.resetsAt)}" data-reset-prefix="resets " title="${esc(absolute(window.resetsAt))}">${dateValue(window.resetsAt) > now() ? 'resets ' : ''}${resetText(dateValue(window.resetsAt))}</span>` : 'reset unknown';
  const shortInfo = window && title !== 'Weekly remaining' ? `<p class="text-xs muted short-window-info">${window.windowMinutes ? `${esc(window.windowMinutes / 60)}h window · ` : ''}${shortReset}</p>` : '';
  return `<td class="window"><span class="label">${esc(title)}</span>${window ? `${capacity(window, false)}${shortInfo}` : `<p class="${unavailable ? 'unknown' : 'muted'}">${unavailable ? 'Unavailable' : 'Not reported'}</p>`}</td>`;
}

function troubleshooting(row, id) {
  return `<details class="mt-2" id="help-${id}"><summary class="text-xs muted">Account access</summary><div class="details-help text-xs muted"><p>${esc(access[row.provider])}</p>${row.provider === 'qwencloud' ? '<p class="mt-2"><code>codexbar cookie refresh --provider qwencloud --allow-keychain-prompt</code></p><p class="mt-2">Use the same executable path as this server. Complete the macOS prompt in the terminal.</p><a class="link-button" href="https://home.qwencloud.com/analytics/token-plan/individual" target="_blank" rel="noreferrer">Open Qwen Cloud</a>' : ''}</div></details>`;
}

function renderTables() {
  const report = current?.report;
  if (!report) {
    $('report').innerHTML = `<div class="empty-space"><p>${current?.error ? 'No report available.' : 'Fetching provider data…'}</p></div>`;
    $('balance').innerHTML = '<p class="muted">No balance available.</p>';
    $('extra-limits').hidden = true;
    return;
  }
  const expanded = [...document.querySelectorAll('details[open][id]')].map(element => element.id);
  const focused = document.activeElement?.closest('details[id]')?.id;
  const subscriptions = report.accounts.filter(row => row.kind === 'subscription').map(row => ({...row, ...splitWindows(row)}));
  const order = $('order').value;
  subscriptions.sort((a,b) => {
    const aKnown = a.windows.some(w => left(w) !== null), bKnown = b.windows.some(w => left(w) !== null);
    if (aKnown !== bKnown) return Number(bKnown) - Number(aKnown);
    const aRemaining = left(a.weekly), bRemaining = left(b.weekly);
    if (order === 'remaining') return (bRemaining ?? -1) - (aRemaining ?? -1) || a.provider.localeCompare(b.provider);
    if (order === 'reset') {
      const aReset = dateValue(a.weekly?.resetsAt), bReset = dateValue(b.weekly?.resetsAt);
      const diff = (Number.isFinite(aReset) ? aReset : Infinity) - (Number.isFinite(bReset) ? bReset : Infinity);
      if (diff) return diff;
    }
    return names[a.provider].localeCompare(names[b.provider]);
  });
  $('report').innerHTML = subscriptions.length ? `<table aria-label="Subscription allowances remaining"><thead><tr>
    <th scope="col" class="provider">Provider / account</th><th scope="col" class="window">Short window remaining</th><th scope="col" class="window">Weekly remaining</th><th scope="col" class="note">Weekly reset</th>
    </tr></thead><tbody>${subscriptions.map((row,index) => {
      return `<tr><td class="provider"><h3 class="text-base font-medium">${esc(names[row.provider])}</h3><p class="mt-1 text-xs muted">${esc(row.account)}</p></td>
        ${cell(row.short, row.short ? `${row.short.name} remaining` : 'Short window remaining', row.unavailable)}
        ${cell(row.weekly, 'Weekly remaining', row.unavailable)}
        <td class="note"><span class="label">Weekly reset</span>${row.weekly ? reset(row.weekly) : '<p class="text-xs muted">Not reported</p>'}
        ${row.unavailable ? troubleshooting(row, `subscription-${index}`) : ''}</td></tr>`;
    }).join('')}</tbody></table>` : '<div class="empty-space">No subscriptions in the report.</div>';
  const extras = subscriptions.flatMap(row => row.extras.map(window => ({row, window})));
  $('extra-limits').hidden = extras.length === 0;
  $('extra-count').textContent = `(${extras.length})`;
  $('extras').innerHTML = extras.map(({row, window}) => `<div class="extra-item"><h3 class="font-medium">${esc(names[row.provider])} · ${esc(window.name)}</h3><p class="mb-3 text-xs muted">${esc(row.account)}${window.windowMinutes ? ` · ${esc(window.windowMinutes)} min` : ''}</p>${capacity(window)}</div>`).join('');
  const balances = report.accounts.filter(row => row.kind === 'balance');
  $('balance').innerHTML = balances.length ? balances.map((row,index) => `<div class="balance-row grid gap-3 sm:grid-cols-[1fr_1fr_2fr] sm:gap-10"><div><h3 class="text-base font-medium">${esc(names[row.provider])}</h3><p class="mt-1 text-xs muted">${esc(row.account)}</p></div><div>${row.balances.map(balance => {
    const amount = new Intl.NumberFormat(undefined, {style:'currency', currency:balance.currency}).format(balance.amount);
    return `<p class="numbers"><span class="text-3xl font-medium tracking-tight ${balance.amount <= 0 ? 'danger' : ''}">${esc(amount)}</span><span class="ml-2 text-xs muted">${esc(balance.currency)}</span></p>`;
  }).join('') || '<p class="unknown">Unavailable</p>'}</div><div><p class="text-xs muted">${row.unavailable ? 'Balance unknown' : 'Prepaid credit'}</p>${row.unavailable ? troubleshooting(row, `balance-${index}`) : ''}</div></div>`).join('') : '<p class="muted">No balances in the report.</p>';
  for (const id of expanded) if ($(id)) $(id).open = true;
  if (focused && $(focused)) $(focused).querySelector('summary').focus({preventScroll:true});
}

function renderStatus() {
  const report = current?.report;
  $('checked').textContent = report ? `Checked ${absolute(report.checkedAt)}` : 'No report yet';
  $('schedule').textContent = current?.refreshing ? 'Fetching provider data… · Auto-refresh: 15 minutes' : current ? `Auto-refresh: 15 minutes · Next in ${duration(dateValue(current.nextRefreshAt) - now())}` : 'Auto-refresh: 15 minutes';
  $('refresh').disabled = manualPending || Boolean(current?.refreshing);
  $('refresh').textContent = manualPending || current?.refreshing ? 'Refreshing…' : 'Refresh report';
  $('report').setAttribute('aria-busy', String(Boolean(current?.refreshing)));
  $('order').disabled = !report;
  const failed = report?.accounts.filter(row => row.unavailable).length || 0;
  let message = '';
  if (connectionError) message = 'Local server unavailable. The last report remains visible and can be out of date. Reconnect or restart the server.';
  else if (current?.error) message = `${current.error}${report ? ' The last report remains visible and is out of date.' : ''}`;
  else if (current?.stale) message = 'This report is out of date. Refresh the report before you use these readings.';
  else if (failed) message = `${report.accounts.length - failed} of ${report.accounts.length} accounts reported all requested data. ${failed} ${failed === 1 ? 'account is' : 'accounts are'} incomplete.`;
  else if (!report) message = 'Fetching provider data…';
  $('notice').hidden = !message;
  if ($('notice').textContent !== message) $('notice').textContent = message;
  document.querySelectorAll('[data-reset]').forEach(element => {
    const timestamp = Number(element.dataset.reset);
    element.textContent = (timestamp > now() ? element.dataset.resetPrefix || '' : '') + resetText(timestamp);
  });
  document.querySelectorAll('[data-urgency-at]').forEach(element => {
    const hours = (Number(element.dataset.urgencyAt) - now()) / 3600000;
    const usable = Number(element.dataset.remaining) > 0 && !connectionError && !current?.stale && !current?.error;
    element.dataset.urgency = usable && hours > 0 && hours <= 6 ? 'soon' : usable && hours > 6 && hours <= 24 ? 'today' : '';
  });
}

function accept(payload) {
  if (!payload || typeof payload.refreshing !== 'boolean' || !numeric(payload.refreshIntervalSeconds)) throw new Error('Invalid response');
  current = payload;
  clockOffset = dateValue(payload.serverTime) - Date.now();
  connectionError = false;
  const signature = JSON.stringify(payload.report);
  if (signature !== reportSignature || !payload.report) {
    reportSignature = signature;
    renderTables();
  }
  renderStatus();
}

async function fetchReport(manual = false) {
  if (pending) return;
  clearTimeout(timer);
  pending = true;
  manualPending = manual;
  renderStatus();
  try {
    const response = await fetch(manual ? '/api/refresh' : '/api/report', {
      method: manual ? 'POST' : 'GET', cache:'no-store', credentials:'omit', signal:AbortSignal.timeout(15000)
    });
    if (!response.ok) throw new Error('Request failed');
    const payload = await response.json();
    if (manual && payload.accepted) payload.refreshing = true;
    accept(payload);
  } catch {
    connectionError = true;
  } finally {
    pending = false;
    manualPending = false;
    renderStatus();
    timer = setTimeout(fetchReport, current?.refreshing ? 1000 : 5000);
  }
}

$('timezone').textContent = `Times: ${Intl.DateTimeFormat().resolvedOptions().timeZone}`;
$('order').addEventListener('change', () => {
  renderTables();
  $('sort-status').textContent = `Ordered by ${$('order').selectedOptions[0].text.toLowerCase()}. Unknown readings stay last.`;
});
$('refresh').addEventListener('click', () => fetchReport(true));
document.addEventListener('visibilitychange', () => { if (!document.hidden) fetchReport(); });
window.addEventListener('online', () => fetchReport());
fetchReport();
