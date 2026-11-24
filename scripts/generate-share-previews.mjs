import { readFile, writeFile, copyFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
// Run from this workspace after editing a logo. Uses the simulator's existing
// Playwright dependency only to rasterize native SVG branding into crawler PNGs.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const { chromium } = await import(resolve(root, 'FTO-simulator/node_modules/playwright/index.mjs'));
const { browserLaunchOptions } = await import(resolve(root, 'FTO-simulator/tests/browser-options.js'));
const specs = [
  { title: 'FTOers', logo: 'ftoers/public/logo.svg', output: 'ftoers/public', size: 108 },
  { title: 'FTO Simulator', logo: 'FTO-simulator/public/logo.png', output: 'FTO-simulator/public', size: 76 },
  { title: 'First Block', logo: 'FTO-FB/public/logo.svg', output: 'FTO-FB/public', size: 88 },
  { title: 'FTO Alg Finder', logo: 'FTO-alg-finder/public/assets/app-icon.png', output: 'FTO-alg-finder/public', size: 72 },
];
const browser = await chromium.launch(browserLaunchOptions);
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  for (const spec of specs) {
    const path = resolve(root, spec.logo), logo = await readFile(path);
    const mime = path.endsWith('.svg') ? 'image/svg+xml' : 'image/png';
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <title>${spec.title} — FTOers</title>
  <rect width="1200" height="630" fill="#111719"/>
  <image href="data:${mime};base64,${logo.toString('base64')}" x="90" y="205" width="210" height="220"/>
  <text x="350" y="339" font-family="Arial, sans-serif" font-size="${spec.size}" font-weight="700" fill="#e9eeeb">${spec.title}</text>
  <text x="353" y="391" font-family="Arial, sans-serif" font-size="24" fill="#92a49d">ftoers.web.app</text>
</svg>\n`;
    const output = resolve(root, spec.output);
    await writeFile(resolve(output, 'social-preview.svg'), svg);
    await page.setContent(`<html><body style="margin:0">${svg}</body></html>`);
    await page.evaluate(async () => { await document.fonts.ready; await Promise.all([...document.images].map((img) => img.decode())); });
    await page.screenshot({ path: resolve(output, 'social-preview.png') });
  }
  for (const extension of ['svg', 'png']) await copyFile(
    resolve(root, `FTO-alg-finder/public/social-preview.${extension}`),
    resolve(root, `FTO-alg-finder/main/public/social-preview.${extension}`),
  );
} finally { await browser.close(); }
