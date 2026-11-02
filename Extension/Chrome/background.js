// 팝업을 열면 현재 탭의 논문을 PaperLibrary에 저장한다. 팝업을 닫아도 저장은 여기서 끝까지 이어진다.
// 1. 페이지의 메타태그와 PDF 링크를 읽어 PaperLibrary에 보낸다(POST /save). PaperLibrary가 서지 정보를 채워 항목을 만든다.
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
  chrome.action.setBadgeText({ tabId, text: { saving: '…', done: '✓', error: '!' }[state.phase] || '' });
  chrome.action.setBadgeBackgroundColor({ tabId, color: state.phase === 'error' ? '#d33b3b' : '#2f9e72' });
}

async function download(url) {
  try {
    const response = await fetch(url, { credentials: 'include' });
    if (!response.ok) return null;
    const data = await response.arrayBuffer();
    const head = String.fromCharCode(...new Uint8Array(data, 0, Math.min(5, data.byteLength)));
    return head === '%PDF-' ? data : null;
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
    let item = await api('/save', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(page),
    });
    if (item.hasPDF) update(tabId, { phase: 'done', item, pdf: 'attached' });
    else if (!item.pdfCandidates.length) update(tabId, { phase: 'done', item, pdf: 'none' });
    else await savePDF(tabId, item);
  } catch (error) {
    update(tabId, { phase: 'error', message: error.message, offline: !!error.offline });
  }
}

// PaperLibrary가 알려 준 주소를 차례로 받아 보고, 처음 받은 PDF를 붙인다.
async function savePDF(tabId, item) {
  update(tabId, { phase: 'saving', step: 'Downloading the PDF…', item });
  for (const url of item.pdfCandidates) {
    const data = await download(url);
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
  if (message.type !== 'save') return;
  // 저장하는 중에 팝업을 다시 열면 새로 시작하지 않고 지금 상태를 보인다.
  const job = jobs.get(message.tab.id);
  if (job?.phase === 'saving') {
    reply(job);
  } else {
    save(message.tab);
    reply(null);
  }
});
