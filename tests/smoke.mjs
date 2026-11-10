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
  'inventoryGrid','petsGrid','leaderboard','chatMessages','chatInput','toast',
  'guildStatus','myGuild','guildName','guildDescription','guildList',
  'pvpRating','pvpWins','pvpLosses','pvpQueueButton','pvpStatus'
];
const missingIds = requiredIds.filter(id => !ids.has(id));
if (missingIds.length) throw new Error('Required UI elements are missing: ' + missingIds.join(', '));

const source = scripts.join('\n');
const inlineHandlers = [...html.matchAll(/\bonclick=["']\s*([A-Za-z_$][\w$]*)\s*\(/gi)].map(match => match[1]);
const missingHandlers = [...new Set(inlineHandlers)].filter(name =>
  !new RegExp('(?:function\\s+' + name + '\\b|window\\.' + name + '\\s*=)').test(source)
);
if (missingHandlers.length) throw new Error('Inline button handlers are missing: ' + missingHandlers.join(', '));

for (const name of ['attackBoss','submitAuth','openAuth','buyUpgrade','claimQuest','sendGameChat','loadGuilds','createGuild','joinGuild','joinPvpQueue']) {
  if (!new RegExp('window\\.' + name + '\\s*=').test(source)) throw new Error('Core action is not exposed: ' + name);
}


const monsterStart = source.indexOf('function monsterSvg(index){');
const monsterEnd = source.indexOf('\nfunction renderGame()', monsterStart);
if (monsterStart < 0 || monsterEnd < 0) throw new Error('Boss renderer is missing');
const monsterRenderer = vm.runInNewContext(source.slice(monsterStart, monsterEnd) + '\nmonsterSvg');
const bossLabels = new Set();
for (let index = 0; index < 7; index++) {
  const svg = monsterRenderer(index);
  if (!svg.includes('<svg') || !svg.includes('boss-art')) throw new Error('Boss ' + index + ' did not render SVG artwork');
  const label = svg.match(/aria-label="([^"]+)"/)?.[1];
  if (!label) throw new Error('Boss ' + index + ' is missing accessible artwork label');
  bossLabels.add(label);
}
if (bossLabels.size !== 7) throw new Error('Bosses must have seven distinct names and art variants');
if (!source.includes('Math.max(game.bossIndex,Math.floor((game.tower-1)/3))')) {
  throw new Error('Infinite tower boss progression regression');
}
if (!html.includes('@media(max-width:420px)')) throw new Error('Small-screen layout rules are missing');
if (!html.includes('prefers-reduced-motion:reduce')) throw new Error('Reduced-motion accessibility rules are missing');


if (!source.includes('const saveKeyFor=owner=>SAVE_KEY+')) throw new Error('Account-specific local save keys are missing');
if (!source.includes('readSavedGame(nextId)')) throw new Error('Account-specific local save restore is missing');
if (!source.includes('if(currentUser?.id!==owner)return')) throw new Error('Cloud save owner guard is missing');
if (!source.includes("select('user_id,username,level,gold,kills,total_damage,save_data,updated_at')")) throw new Error('Cloud save query must explicitly select the expected schema');
if (!source.includes('username,body')) throw new Error('Chat username integration is missing');
if (html.includes('⚔') || html.includes('◆')) throw new Error('Emoji game icons must be replaced by vector artwork');
if (!html.includes('pet-sigil')) throw new Error('Pet icon styling is missing');

console.log('Lootora smoke checks passed: ' + scripts.length + ' script(s), ' + ids.size + ' DOM ids, ' + new Set(inlineHandlers).size + ' inline actions.');
