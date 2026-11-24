import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const root = new URL('../../', import.meta.url);
const sites = [
  ['ftoers/public/index.html', 'ftoers/public/social-preview.png', '/'],
  ['FTO-simulator/index.html', 'FTO-simulator/public/social-preview.png', '/virtual/'],
  ['FTO-FB/index.html', 'FTO-FB/public/social-preview.png', '/FB/'],
  ['FTO-alg-finder/public/index.html', 'FTO-alg-finder/public/social-preview.png', '/fto-alg-finder/'],
  ['FTO-alg-finder/main/index.html', 'FTO-alg-finder/main/public/social-preview.png', '/fto-alg-finder/web/'],
];
for (const [entry, image, route] of sites) test(`static share preview: ${route}`, async () => {
  const html = await readFile(new URL(entry, root), 'utf8');
  const meta = (name) => {
    const tag = [...html.matchAll(/<meta\b[^>]*>/g)].map((match) => match[0])
      .find((tag) => tag.includes(`="${name}"`));
    return tag?.match(/content="([^"]*)"/)?.[1];
  };
  assert.equal(meta('og:url'), 'https://ftoers.web.app' + route);
  assert.equal(meta('og:image'), 'https://ftoers.web.app' + route + 'social-preview.png');
  assert.equal(meta('twitter:image'), meta('og:image'));
  assert.equal(meta('twitter:card'), 'summary_large_image');
  assert.ok(meta('og:title')); assert.ok(meta('og:description')); assert.ok(meta('og:image:alt'));
  const png = await readFile(new URL(image, root));
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(png.readUInt32BE(16), 1200); assert.equal(png.readUInt32BE(20), 630);
});
