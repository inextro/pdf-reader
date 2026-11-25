// 이미 서재에 있는 논문일 때 팝업에 보일 것: 지금 어디에 있는지, 어떤 버튼을 켤지, Move here가 무엇을 바꾸는지.
// 앱의 AddOutcome(식별자로 추가)과 Workspace.planMove(viewing 없이 옮기기)와 같은 규칙이다.
// 화면을 만지지 않는 순수 함수라 node로 시험한다.

const quoted = (name) => `“${name}”`;

// Move here가 할 일을 한 줄로: "archive → RL-temp", 빼지 않고 더하기만 하면 "+ RL-temp". 바뀌는 게 없으면 ''.
// home: 원본 자리(PDF가 있는 컬렉션 id, 'top'이면 Unfiled, PDF가 없으면 null)
function movePlan(item, selected, name) {
  const ids = item.collections || [];
  const to = selected === null ? 'Unfiled' : name(selected);
  if (item.home !== null && item.home !== undefined) {
    const from = item.home === 'top' ? 'Unfiled' : name(item.home);
    return from === to ? '' : `${from} → ${to}`;
  }
  // PDF 없는 논문: 한 곳에만 있으면 거기서 옮기고, 여러 곳이면 더하기만 한다.
  if (ids.length <= 1) return `${ids.length ? name(ids[0]) : 'Unfiled'} → ${to}`;
  return selected === null ? '' : `+ ${to}`;
}

// item: /save가 돌려준 항목(in: 컬렉션 이름들, collections: 그 id들, home, allowReferences)
// selected: 팝업에서 고른 컬렉션 id(Unfiled면 null), names: id → 컬렉션 이름
export function duplicateView(item, selected, names = new Map()) {
  const ids = item.collections || [];
  const inNames = item.in || [];
  const name = (id) => names.get(id) || inNames[ids.indexOf(id)] || '';
  const allow = item.allowReferences !== false;
  // 고른 곳에 이미 있다: Unfiled를 골랐고 어느 컬렉션에도 없을 때도 같다.
  const here = selected === null ? ids.length === 0 : ids.includes(selected);
  if (here) {
    return { where: `Already in ${selected === null ? 'Unfiled' : quoted(name(selected))}.`, move: false, plan: '', reference: false, hint: '' };
  }
  const where = inNames.length ? `In ${inNames.map(quoted).join(', ')}.` : 'In Unfiled.';
  const plan = movePlan(item, selected, name);
  let hint = '';
  if (!allow) hint = 'Turn on Allow references in Settings.';
  else if (selected === null) hint = 'Pick a collection to add a reference.';
  return { where, move: plan !== '', plan, reference: allow && selected !== null, hint };
}
