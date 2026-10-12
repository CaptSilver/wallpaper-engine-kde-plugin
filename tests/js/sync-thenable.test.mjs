// syncThenable: the promise-like value Pyext's synchronous FileHelper calls
// return. It lives in a module, not on the Pyext QML object, so a real
// Promise can still adopt it after that Pyext is destroyed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { syncThenable } from '../../plugin/contents/ui/js/utils.mjs';

test('then calls back before returning', () => {
    let seen = null;
    syncThenable(5).then(v => { seen = v; });
    assert.equal(seen, 5);
});

test('then chains the callback result, or the value when it returns nothing', () => {
    const seen = [];
    syncThenable(1).then(v => v + 1).then(v => { seen.push(v); }).then(v => seen.push(v));
    assert.deepEqual(seen, [2, 2]);
});

test('catch passes the value along', () => {
    let seen = null;
    syncThenable('x').catch(() => 'never').then(v => { seen = v; });
    assert.equal(seen, 'x');
});

test('a real Promise adopts it', async () => {
    assert.equal(await Promise.resolve(syncThenable(7)), 7);
    assert.equal(await Promise.resolve().then(() => syncThenable('y')), 'y');
});

test('a then with no callback hands the value on', async () => {
    assert.equal(await Promise.resolve(syncThenable(3).then()), 3);
});

test('the result field holds the value', () => {
    assert.equal(syncThenable(9).result, 9);
});
