import { chromium } from 'playwright';

const url = process.env.LOOTORA_URL;
if (!url) throw new Error('LOOTORA_URL is required');

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1365, height: 900 } });
const pageErrors = [];
page.on('pageerror', error => pageErrors.push(error.message));

try {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.locator('#bossName').waitFor({ state: 'visible', timeout: 30000 });
  if (!(await page.title()).includes('Lootora')) throw new Error('Unexpected page title');

  const hpBefore = await page.locator('#bossHpText').innerText();
  await page.locator('.attack-button').click();
  await page.waitForTimeout(300);
  const hpAfterAttack = await page.locator('#bossHpText').innerText();
  if (hpAfterAttack === hpBefore) {
    const diagnostics = await page.evaluate(() => ({
      attackFunction: typeof window.attackBoss,
      buttonDisabled: document.querySelector('.attack-button')?.disabled,
      buttonHandler: document.querySelector('.attack-button')?.getAttribute('onclick'),
      stageClass: document.querySelector('#bossStage')?.className,
      hitText: document.querySelector('#bossHit')?.textContent,
      bossHpText: document.querySelector('#bossHpText')?.textContent
    }));
    throw new Error('Attack button did not change boss HP: ' + JSON.stringify(diagnostics) + '; page errors: ' + pageErrors.join(' | '));
  }
  if (!(await page.locator('#bossStage .boss-art').getAttribute('aria-label'))) {
    throw new Error('Boss artwork has no accessible label');
  }

  await page.locator('button[onclick="buyUpgrade(\'sword\')"]').click();
  if (!(await page.locator('#swordLevel').innerText()).includes('Уровень 1')) {
    throw new Error('Sword upgrade did not update its level');
  }

  await page.evaluate(() => { for (let i = 0; i < 25; i++) window.attackBoss(); });
  if (await page.locator('#questButton').isDisabled()) throw new Error('Daily quest did not unlock at 100 damage');
  await page.locator('#questButton').click();
  if (!(await page.locator('#questButton').innerText()).includes('Получено')) {
    throw new Error('Daily quest reward was not claimed');
  }

  await page.locator('[data-panel="dungeons"]').click();
  await page.getByRole('button', { name: 'Склеп падших' }).click();
  if (!(await page.locator('#dungeonStatus').innerText()).includes('вошёл')) {
    throw new Error('Dungeon entry action failed');
  }

  await page.locator('[data-panel="tower"]').click();
  await page.getByRole('button', { name: 'Следующий этаж' }).click();
  if ((await page.locator('#towerFloor').innerText()).trim() !== '2') {
    throw new Error('Tower floor did not advance');
  }

  const panels = ['inventory','pets','guilds','pvp','top','competition','chat','profile','settings'];
  for (const panel of panels) {
    await page.locator('[data-panel="' + panel + '"]').click();
    if (!(await page.locator('#panel-' + panel).evaluate(el => el.classList.contains('active')))) {
      throw new Error('Panel did not activate: ' + panel);
    }
  }

  await page.locator('#accountBtn').click();
  if (!(await page.locator('#authOverlay').evaluate(el => el.classList.contains('open')))) {
    throw new Error('Account dialog did not open');
  }
  await page.locator('#authSwitch').click();
  if (!(await page.locator('#authTitle').innerText()).includes('Создать аккаунт')) {
    throw new Error('Sign-up mode did not open');
  }
  if (!(await page.locator('#nameField').isVisible())) throw new Error('Sign-up name field is hidden');
  await page.getByRole('button', { name: 'Закрыть' }).click();

  const guestSave = await page.evaluate(() => localStorage.getItem('lootora_clicker_v2:guest'));
  if (!guestSave) throw new Error('Guest progress was not saved locally');
  const parsedSave = JSON.parse(guestSave);
  if (parsedSave.questClaimed !== true || parsedSave.tower !== 2) {
    throw new Error('Local save did not preserve tested game progress');
  }

  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(250);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 2);
  if (overflow) throw new Error('Mobile layout has horizontal overflow');

  if (pageErrors.length) throw new Error('Browser runtime errors: ' + pageErrors.join(' | '));
  console.log('Lootora browser checks passed: combat, upgrade, daily quest, dungeon, tower, all tabs, auth dialog, local save and mobile layout.');
} finally {
  await browser.close();
}
