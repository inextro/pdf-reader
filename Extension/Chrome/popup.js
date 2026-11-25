// 팝업: 저장을 시작하고(background.js), 진행 상태와 저장된 논문을 보이고, 컬렉션을 고르게 한다.

import { duplicateView } from './duplicate.js';

const API = 'http://127.0.0.1:23120';
const $ = (id) => document.getElementById(id);

let item = null;
let shownCollection = null; // 팝업에 보이는 컬렉션. 저장한 뒤 바꾸면 그 컬렉션으로 옮긴다.
let duplicate = false; // 이미 있는 논문: 진행을 누르기 전에는 아무것도 바꾸지 않는다.
let collectionsLoaded = false;
let collectionNames = new Map(); // id → 이름(들여쓰기 없이)

async function api(path, init = {}) {
  const response = await fetch(API + path, { ...init, headers: { 'X-PaperLibrary': '1', ...(init.headers || {}) } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `Quillo answered ${response.status}.`);
  return body;
}

function setStatus(text, kind = '') {
  $('status').textContent = text;
  $('status').className = `status ${kind}`;
}

function render(state) {
  $('log').hidden = true;
  $('open').hidden = !(state.phase === 'error' && state.offline);
  if (state.phase === 'error') {
    setStatus(state.offline ? 'Quillo is not running.' : state.message, 'error');
    if (state.offline) $('warnings').replaceChildren(listItem('Open Quillo, then click the extension again.'));
    return;
  }
  if (state.item) showItem(state.item);
  duplicate = state.phase === 'duplicate';
  $('confirm').hidden = !duplicate;
  $('where').hidden = !duplicate;
  $('hint').hidden = true;
  $('collection').disabled = state.phase === 'referenced';
  if (duplicate) {
    // 오류가 아니라 어디에 있는지 알리는 정보다.
    setStatus('Already in your library');
    setPDF('', '');
    showDuplicate();
    return;
  }
  if (state.phase === 'referenced') {
    setStatus(state.message, state.added ? 'ok' : '');
    setPDF('', '');
    return;
  }
  if (state.phase === 'saving') {
    setStatus(state.step);
    if (state.item) setPDF(state.step, '');
    return;
  }
  setStatus('Saved to Quillo', 'ok');
  if (state.pdf === 'attached') setPDF(state.item.file ? `PDF saved as “${state.item.file}”` : 'PDF attached', 'ok');
  else if (state.pdf === 'failed') setPDF('The PDF could not be downloaded. Open the PDF in this tab and click the extension again.', 'warn');
  else setPDF('No PDF found on this page.', 'warn');
  $('log').hidden = !(state.log || []).length;
  $('log-text').textContent = (state.log || []).join('\n');
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
    shownCollection = item.collection;
    loadCollections();
  }
}

// 고른 컬렉션에 따라 안내와 두 버튼을 맞춘다.
function showDuplicate() {
  const view = duplicateView(item, shownCollection, collectionNames);
  $('where').textContent = view.where;
  $('hint').textContent = view.hint;
  $('hint').hidden = !view.hint;
  $('proceed').disabled = !view.move;
  $('plan').textContent = view.plan;
  $('reference').disabled = !view.reference;
  // 기본 버튼은 Add as reference. 쓸 수 없으면 Move here에 포커스를 둔다.
  const focus = view.reference ? $('reference') : view.move ? $('proceed') : $('cancel');
  focus.focus();
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
  options.push(new Option('Unfiled', ''));
  for (const c of collections) options.push(new Option('   '.repeat(c.depth) + c.name, String(c.id)));
  collectionNames = new Map(collections.map((c) => [c.id, c.name]));
  select.replaceChildren(...options);
  select.value = shownCollection === null ? '' : String(shownCollection);
  if (duplicate) showDuplicate();
}

$('collection').addEventListener('change', async (event) => {
  const value = event.target.value;
  const to = value === '' ? null : Number(value);
  if (duplicate) {
    shownCollection = to;
    showDuplicate();
    return;
  }
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

$('proceed').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'proceed', tabId: tab.id, collection: shownCollection });
});
$('reference').addEventListener('click', () => {
  if (shownCollection === null) return;
  chrome.runtime.sendMessage({ type: 'reference', tabId: tab.id, collection: shownCollection });
});
$('cancel').addEventListener('click', () => window.close());

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
