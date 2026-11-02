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

// 페이지 안에서 실행된다. 같은 사이트의 PDF를 페이지처럼 받는다(base64).
// ACM처럼 Cloudflare가 지키는 사이트는 확장에서 바로 받으면 사람 확인 페이지가 오지만, 페이지 안에서 받으면 통과한다.
async function fetchInPage(url) {
  try {
    const response = await fetch(url, { credentials: 'include' });
    if (!response.ok) return null;
    const blob = await response.blob();
    return await new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(',')[1] || null);
      reader.onerror = () => resolve(null);
      reader.readAsDataURL(blob);
    });
  } catch {
    return null;
  }
}

function isPDF(data) {
  return data && String.fromCharCode(...new Uint8Array(data, 0, Math.min(5, data.byteLength))) === '%PDF-' ? data : null;
}

async function download(url, tab) {
  if (tab?.url && new URL(url, tab.url).origin === new URL(tab.url).origin) {
    try {
      const [{ result }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: fetchInPage, args: [url] });
      if (result) {
        const data = isPDF(Uint8Array.from(atob(result), (c) => c.charCodeAt(0)).buffer);
        if (data) return data;
      }
    } catch {
      // PDF 보기 탭처럼 스크립트를 넣을 수 없으면 확장에서 받는다.
    }
  }
  try {
    const response = await fetch(url, { credentials: 'include' });
    return response.ok ? isPDF(await response.arrayBuffer()) : null;
  } catch {
    return null;
  }
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
  for (const url of item.pdfCandidates) {
    const data = await download(url, tab);
    if (!data) continue;
    update(tabId, { phase: 'saving', step: 'Saving the PDF…', item });
    const attached = await api(`/attach?id=${item.id}`, {
      method: 'POST', headers: { 'Content-Type': 'application/pdf' }, body: data,
    });
    update(tabId, { phase: 'done', item: { ...item, ...attached }, pdf: 'attached' });
    return;
  }
  update(tabId, { phase: 'done', item, pdf: 'failed' });
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
