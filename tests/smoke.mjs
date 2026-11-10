import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync('index.html', 'utf8');
const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
  .map(match => match[1]).filter(code => code.trim());
if (!scripts.length) throw new Error('No inline application script found');
for (const [index, code] of scripts.entries()) {
  try { new vm.Script(code, { filename: 'index-inline-' + index + '.js' }); }
  catch (error) { throw new Error('Inline script ' + index + ' has invalid JavaScript: ' + error.message); }
}

const ids = new Set([...html.matchAll(/\bid=["']([^"']+)["']/g)].map(match => match[1]));
const requiredIds = [
  'accountBtn','authOverlay','authEmail','authPassword','authSubmit','authStatus',
  'bossStage','bossName','bossHpBar','goldValue','questButton',
  'inventoryGrid','petsGrid','leaderboard','chatMessages','chatInput','toast'
];
const missingIds = requiredIds.filter(id => !ids.has(id));
if (missingIds.length) throw new Error('Required UI elements are missing: ' + missingIds.join(', '));

const source = scripts.join('\n');
const inlineHandlers = [...html.matchAll(/\bonclick=["']\s*([A-Za-z_$][\w$]*)\s*\(/gi)].map(match => match[1]);
const missingHandlers = [...new Set(inlineHandlers)].filter(name =>
  !new RegExp('(?:function\\s+' + name + '\\b|window\\.' + name + '\\s*=)').test(source)
);
if (missingHandlers.length) throw new Error('Inline button handlers are missing: ' + missingHandlers.join(', '));

for (const name of ['attackBoss','submitAuth','openAuth','buyUpgrade','claimQuest','sendGameChat']) {
  if (!new RegExp('window\\.' + name + '\\s*=').test(source)) throw new Error('Core action is not exposed: ' + name);
}

console.log('Lootora smoke checks passed: ' + scripts.length + ' script(s), ' + ids.size + ' DOM ids, ' + new Set(inlineHandlers).size + ' inline actions.');
