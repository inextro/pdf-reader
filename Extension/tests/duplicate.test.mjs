// 확장 팝업의 "이미 있는 논문" 화면 규칙. 실행: node --test Extension/tests
import test from 'node:test';
import assert from 'node:assert/strict';
import { duplicateView } from '../Chrome/duplicate.js';

const names = new Map([[1, 'archive'], [2, 'SerenUplift'], [3, 'RL-temp']]);
// PDF는 archive에 있고 SerenUplift에는 참조로 들어 있다.
const item = { in: ['archive', 'SerenUplift'], collections: [1, 2], home: 1, allowReferences: true };

test('다른 컬렉션을 고르면 두 버튼을 켜고 원본 자리 → 고른 곳을 보인다', () => {
  assert.deepEqual(duplicateView(item, 3, names),
    { where: 'In “archive”, “SerenUplift”.', move: true, plan: 'archive → RL-temp', reference: true, hint: '' });
});

test('이미 고른 컬렉션에 있으면 두 버튼을 끈다', () => {
  assert.deepEqual(duplicateView(item, 2, names),
    { where: 'Already in “SerenUplift”.', move: false, plan: '', reference: false, hint: '' });
});

test('참조가 꺼져 있으면 Add as reference만 끄고 짧게 안내한다', () => {
  const v = duplicateView({ ...item, allowReferences: false }, 3, names);
  assert.equal(v.move, true);
  assert.equal(v.reference, false);
  assert.equal(v.hint, 'Turn on Allow references in Settings.');
});

test('Unfiled를 고르면 참조는 못 넣고 옮기기만 된다', () => {
  const v = duplicateView(item, null, names);
  assert.equal(v.plan, 'archive → Unfiled');
  assert.equal(v.reference, false);
  assert.equal(v.hint, 'Pick a collection to add a reference.');
});

test('PDF가 workspace 맨 위에 있으면 Unfiled에서 옮긴다', () => {
  assert.equal(duplicateView({ in: [], collections: [], home: 'top' }, 3, names).plan, 'Unfiled → RL-temp');
});

test('PDF 없는 논문이 한 컬렉션에만 있으면 거기서 옮긴다', () => {
  assert.equal(duplicateView({ in: ['archive'], collections: [1], home: null }, 3, names).plan, 'archive → RL-temp');
});

test('PDF 없는 논문이 여러 컬렉션에 있으면 더하기만 한다', () => {
  const v = duplicateView({ in: ['archive', 'SerenUplift'], collections: [1, 2], home: null }, 3, names);
  assert.equal(v.plan, '+ RL-temp');
  assert.equal(v.move, true);
});

test('PDF 없는 논문이 여러 컬렉션에 있는데 Unfiled를 고르면 Move here가 바꿀 게 없다', () => {
  const v = duplicateView({ in: ['archive', 'SerenUplift'], collections: [1, 2], home: null }, null, names);
  assert.equal(v.move, false);
  assert.equal(v.plan, '');
});

test('어느 컬렉션에도 없는 논문에서 Unfiled를 고르면 이미 거기 있다', () => {
  assert.deepEqual(duplicateView({ in: [], collections: [], home: null }, null, names),
    { where: 'Already in Unfiled.', move: false, plan: '', reference: false, hint: '' });
});

test('컬렉션 목록을 아직 못 받았으면 항목의 이름으로 대신한다', () => {
  assert.equal(duplicateView(item, 2).where, 'Already in “SerenUplift”.');
});

test('예전 앱(allowReferences를 안 보냄)에서는 참조를 켠 것으로 본다', () => {
  assert.equal(duplicateView({ in: ['archive'], collections: [1] }, 3, names).reference, true);
});
