// 팝업을 열면 현재 탭의 논문을 PaperLibrary에 저장한다. 팝업을 닫아도 저장은 여기서 끝까지 이어진다.
// 1. 페이지의 메타태그와 PDF 링크를 읽어 PaperLibrary에 보낸다(POST /save). PaperLibrary가 서지 정보를 채워 항목을 만든다.
//    같은 논문이 이미 있으면 아무것도 바꾸지 않고 팝업에서 묻는다. 진행하면 proceed로 다시 보낸다.
// 2. PaperLibrary가 알려 준 PDF 주소를 브라우저의 로그인 상태(학교 구독 등)로 받아 넘긴다(POST /attach).

const API = 'http://127.0.0.1:23120';
const jobs = new Map(); // 탭 id → 마지막 상태

async function api(path, init = {}) {
  let response;
  try {
    response = await fetch(API + path, { ...init, headers: { 'X-PaperLibrary': '1', ...(init.headers || {}) } });
  } catch {
    throw Object.assign(new Error('PaperLibrary is not running.'), { offline: true });
  }
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `PaperLibrary answered ${response.status}.`);
  return body;
}

// 페이지 안에서 실행된다.
function readPage() {
  const meta = [];
  for (const tag of document.querySelectorAll('meta[name], meta[property]')) {
    const name = (tag.getAttribute('name') || tag.getAttribute('property') || '').toLowerCase();
    if (name && tag.content) meta.push([name, tag.content]);
  }
  // IEEE Xplore는 citation_* 메타태그가 없고, 서지 정보를 페이지 스크립트(xplGlobal.document.metadata)에만 둔다.
  // 거기서 DOI를 꺼내 주면 PaperLibrary가 CrossRef로 나머지를 채운다.
  if (location.hostname.endsWith('ieeexplore.ieee.org') && !meta.some(([name]) => name === 'citation_doi')) {
    for (const script of document.scripts) {
      const found = script.textContent.match(/xplGlobal\.document\.metadata\s*=\s*\{[\s\S]*?"doi":"(10\.[^"]+)"/);
      if (found) { meta.push(['citation_doi', found[1]]); break; }
    }
  }
  const links = [];
  for (const a of document.querySelectorAll('a[href]')) {
    if (/\.pdf(?:$|[?#])|\/pdf(?:\/|\?)|pdfft/i.test(a.href) && !links.includes(a.href)) links.push(a.href);
    if (links.length >= 10) break;
  }
  return { url: location.href, title: document.title, meta, links, isPDF: document.contentType === 'application/pdf' };
}

function update(tabId, state) {
  jobs.set(tabId, state);
  chrome.runtime.sendMessage({ type: 'state', tabId, state }).catch(() => {});
  chrome.action.setBadgeText({ tabId, text: { saving: '…', done: '✓', duplicate: '!', error: '!' }[state.phase] || '' });
  chrome.action.setBadgeBackgroundColor({ tabId, color: { error: '#d33b3b', duplicate: '#d98a00' }[state.phase] || '#2f9e72' });
}

// 페이지 안에서 실행된다. 같은 사이트의 PDF를 페이지처럼 받는다(base64). 마지막 주소(넘겨진 뒤)도 돌려준다.
// ACM처럼 Cloudflare가 지키는 사이트는 확장에서 바로 받으면 사람 확인 페이지가 오지만, 페이지 안에서 받으면 통과한다.
async function fetchInPage(url) {
  try {
    const response = await fetch(url, { credentials: 'include' });
    const info = { url: response.url, status: response.status, type: response.headers.get('content-type') || '' };
    if (!response.ok) return info;
    const blob = await response.blob();
    const data = await new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(',')[1] || null);
      reader.onerror = () => resolve(null);
      reader.readAsDataURL(blob);
    });
    return { ...info, data };
  } catch (error) {
    return { error: String(error) };
  }
}

// 실패했을 때 확장 창에 보여 줄 한 줄: 어디서 받았는지, 응답 코드, 형식, 넘겨진 주소, HTML이면 제목.
function note(where, url, info, data) {
  if (info.error) return `${where}: ${info.error} — ${url}`;
  let title = '';
  if (data && /html/i.test(info.type)) {
    title = (new TextDecoder().decode(data.slice(0, 200_000)).match(/<title[^>]*>([^<]*)/i)?.[1] || '').trim().slice(0, 60);
  }
  const moved = info.url && info.url !== url ? ` → ${info.url}` : '';
  return `${where}: ${info.status} ${info.type.split(';')[0]}${title ? ` “${title}”` : ''} — ${url}${moved}`;
}

function isPDF(data) {
  return data && String.fromCharCode(...new Uint8Array(data, 0, Math.min(5, data.byteLength))) === '%PDF-' ? data : null;
}

// PDF 대신 받은 HTML이 PDF로 넘겨 주는 중간 페이지면 그 주소를 꺼낸다.
// ScienceDirect(pdfft)는 meta refresh나 window.location으로, IEEE(stamp.jsp)는 iframe으로 실제 PDF를 부른다.
function redirectIn(data, base) {
  if (!data || data.byteLength > 2_000_000) return null;
  const html = new TextDecoder().decode(data);
  const patterns = [
    /<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["']?\s*\d+\s*;\s*url=['"]?([^"'>\s]+)/i,
    /window\.location(?:\.href)?\s*=\s*["']([^"']+)["']/i,
    /<(?:iframe|embed)[^>]+src=["']([^"']*pdf[^"']*)["']/i,
  ];
  for (const pattern of patterns) {
    const found = html.match(pattern);
    if (!found) continue;
    try {
      return new URL(found[1].replace(/&amp;/g, '&'), base).href;
    } catch {
      // 주소가 아니면 다음 규칙을 본다.
    }
  }
  return null;
}

// PDF를 받는다. 중간 페이지가 오면 그 페이지가 가리키는 주소를 한 번 더 받아 본다.
// 시도한 결과는 log에 한 줄씩 남긴다.
async function download(url, tab, log, depth = 0) {
  let fallback = null;
  if (tab?.url && new URL(url, tab.url).origin === new URL(tab.url).origin) {
    try {
      const [{ result }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: fetchInPage, args: [url] });
      const data = result?.data ? Uint8Array.from(atob(result.data), (c) => c.charCodeAt(0)).buffer : null;
      if (isPDF(data)) return data;
      if (result) log.push(note('page', url, result, data));
      fallback = redirectIn(data, result?.url || url);
    } catch (error) {
      // PDF 보기 탭처럼 스크립트를 넣을 수 없으면 확장에서 받는다.
      log.push(`page: ${error} — ${url}`);
    }
  }
  try {
    const response = await fetch(url, { credentials: 'include' });
    const data = response.ok ? await response.arrayBuffer() : null;
    if (isPDF(data)) return data;
    log.push(note('extension', url, { url: response.url, status: response.status, type: response.headers.get('content-type') || '' }, data));
    fallback = fallback || redirectIn(data, response.url || url);
  } catch (error) {
    log.push(`extension: ${error} — ${url}`);
  }
  return fallback && fallback !== url && depth < 2 ? download(fallback, tab, log, depth + 1) : null;
}

async function save(tab) {
  const tabId = tab.id;
  update(tabId, { phase: 'saving', step: 'Reading the page…' });
  try {
    let page;
    try {
      [{ result: page }] = await chrome.scripting.executeScript({ target: { tabId }, func: readPage });
    } catch {
      // Chrome의 PDF 보기처럼 스크립트를 넣을 수 없는 탭은 주소만 보낸다.
      page = { url: tab.url, title: tab.title, meta: [], links: [], isPDF: /\.pdf(?:$|[?#])|\/pdf\//i.test(tab.url) };
    }
    if (!page || !/^https?:/.test(page.url)) throw new Error('This page cannot be saved.');

    update(tabId, { phase: 'saving', step: 'Looking up the paper…' });
    const item = await api('/save', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(page),
    });
    if (item.existing) update(tabId, { phase: 'duplicate', item, page, tab });
    else await finish(tab, item);
  } catch (error) {
    update(tabId, { phase: 'error', message: error.message, offline: !!error.offline });
  }
}

// 이미 있던 논문을 이 페이지의 정보로 고치고 고른 컬렉션으로 옮긴 뒤 PDF를 붙인다.
async function proceed(tabId, collection) {
  const job = jobs.get(tabId);
  if (job?.phase !== 'duplicate') return;
  update(tabId, { phase: 'saving', step: 'Updating the paper…', item: job.item, tab: job.tab });
  try {
    const item = await api('/save', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...job.page, proceed: job.item.id, collection }),
    });
    await finish(job.tab, item);
  } catch (error) {
    update(tabId, { phase: 'error', message: error.message, offline: !!error.offline });
  }
}

async function finish(tab, item) {
  if (item.hasPDF) update(tab.id, { phase: 'done', item, pdf: 'attached' });
  else if (!item.pdfCandidates.length) update(tab.id, { phase: 'done', item, pdf: 'none' });
  else await savePDF(tab, item);
}

// PaperLibrary가 알려 준 주소를 차례로 받아 보고, 처음 받은 PDF를 붙인다.
async function savePDF(tab, item) {
  const tabId = tab.id;
  update(tabId, { phase: 'saving', step: 'Downloading the PDF…', item });
  const log = [];
  for (const url of item.pdfCandidates) {
    const data = await download(url, tab, log);
    if (!data) continue;
    update(tabId, { phase: 'saving', step: 'Saving the PDF…', item });
    const attached = await api(`/attach?id=${item.id}`, {
      method: 'POST', headers: { 'Content-Type': 'application/pdf' }, body: data,
    });
    update(tabId, { phase: 'done', item: { ...item, ...attached }, pdf: 'attached' });
    return;
  }
  update(tabId, { phase: 'done', item, pdf: 'failed', log });
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === 'proceed') {
    proceed(message.tabId, message.collection);
    return;
  }
  if (message.type !== 'save') return;
  // 저장하는 중이거나 진행을 묻는 중에 팝업을 다시 열면 새로 시작하지 않고 지금 상태를 보인다.
  const job = jobs.get(message.tab.id);
  if (job?.phase === 'saving' || job?.phase === 'duplicate') {
    reply(job);
  } else {
    save(message.tab);
    reply(null);
  }
});
