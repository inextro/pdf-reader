// 팝업: 저장을 시작하고(background.js), 진행 상태와 저장된 논문을 보이고, 컬렉션을 고르게 한다.

const API = 'http://127.0.0.1:23120';
const $ = (id) => document.getElementById(id);

let item = null;
let shownCollection = null; // 팝업에 보이는 컬렉션. 바꾸면 여기서 빼고 새 컬렉션에 넣는다.
let collectionsLoaded = false;

async function api(path, init = {}) {
  const response = await fetch(API + path, { ...init, headers: { 'X-PaperLibrary': '1', ...(init.headers || {}) } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `PaperLibrary answered ${response.status}.`);
  return body;
}

function setStatus(text, kind = '') {
  $('status').textContent = text;
  $('status').className = `status ${kind}`;
}

function render(state) {
  $('open').hidden = !(state.phase === 'error' && state.offline);
  if (state.phase === 'error') {
    setStatus(state.offline ? 'PaperLibrary is not running.' : state.message, 'error');
    if (state.offline) $('warnings').replaceChildren(listItem('Open PaperLibrary, then click the extension again.'));
    return;
  }
  if (state.item) showItem(state.item);
  if (state.phase === 'saving') {
    setStatus(state.step);
    if (state.item) setPDF(state.step, '');
    return;
  }
  setStatus(state.item.existing ? 'Already in your library' : 'Saved to PaperLibrary', 'ok');
  if (state.pdf === 'attached') setPDF(state.item.file ? `PDF saved as “${state.item.file}”` : 'PDF attached', 'ok');
  else if (state.pdf === 'failed') setPDF('The PDF could not be downloaded. Open the PDF in this tab and click the extension again.', 'warn');
  else setPDF('No PDF found on this page.', 'warn');
}

function showItem(next) {
  const first = item === null;
  item = next;
  $('card').hidden = false;
  $('title').textContent = item.title;
  $('authors').textContent = item.authors;
  $('venue').textContent = [item.venue, item.year].filter(Boolean).join(' · ');
  $('warnings').replaceChildren(...(item.warnings || []).map(listItem));
  if (first) {
    shownCollection = item.existing ? null : item.collection;
    loadCollections();
  }
}

function setPDF(text, kind) {
  $('pdf').textContent = text;
  $('pdf').className = `pdf ${kind}`;
}

function listItem(text) {
  const li = document.createElement('li');
  li.textContent = text;
  return li;
}

async function loadCollections() {
  if (collectionsLoaded) return;
  collectionsLoaded = true;
  const select = $('collection');
  const { collections } = await api('/collections');
  const options = [];
  if (item.existing) options.push(new Option('Keep where it is', 'keep'));
  options.push(new Option('Unfiled', ''));
  for (const c of collections) options.push(new Option('   '.repeat(c.depth) + c.name, String(c.id)));
  select.replaceChildren(...options);
  select.value = item.existing ? 'keep' : (shownCollection === null ? '' : String(shownCollection));
}

$('collection').addEventListener('change', async (event) => {
  const value = event.target.value;
  if (value === 'keep') return;
  const to = value === '' ? null : Number(value);
  try {
    await api('/collection', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: item.id, from: shownCollection, to }),
    });
    shownCollection = to;
  } catch (error) {
    setStatus(error.message, 'error');
  }
});

$('open').addEventListener('click', () => {
  chrome.tabs.create({ url: 'paperlibrary://open' });
  window.close();
});

const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
chrome.runtime.onMessage.addListener((message) => {
  if (message.type === 'state' && message.tabId === tab.id) render(message.state);
});
const running = await chrome.runtime.sendMessage({ type: 'save', tab });
if (running) render(running);
