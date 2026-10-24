const assert = require('node:assert/strict');
const test = require('node:test');
const core = require('../Extensions/Companion/core.js');
test('download handoff encodes signed URL exactly once', () => {
 const original = 'https://example.com/file.zip?token=a%2Bb&name=x%20y#fragment';
 const handoff = new URL(core.handoff(original));
 assert.equal(handoff.protocol, 'fetchdock:');
 assert.equal(handoff.searchParams.get('url'), original);
});
test('only HTTPS downloads without URL credentials can leave the browser', () => {
 for (const url of ['http://example.com/file', 'javascript:alert(1)', 'file:///etc/passwd', 'blob:https://example.com/id', 'data:video/mp4;base64,x', 'https://user:password@example.com/file']) assert.equal(core.handoff(url), null);
});
test('file detection ignores query text and resolves relative links', () => {
 assert.equal(core.looksLikeFile('/archive.ZIP?signature=abc', 'https://example.com/a/'), true);
 assert.equal(core.looksLikeFile('https://example.com/search?q=movie.mp4'), false);
 assert.equal(core.looksLikeFile('https://example.com/page'), false);
 assert.equal(core.looksLikeFile('https://example.com/video.m3u8'), false);
});
