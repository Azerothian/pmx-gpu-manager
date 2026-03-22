import { test as setup, expect } from '@playwright/test';

const PVE_USER = process.env.PVE_USER || 'root@pam';
const PVE_PASSWORD = process.env.PVE_PASSWORD || 'testpassword';

setup('authenticate', async ({ page }) => {
    await page.goto('/');

    // Wait for the PVE login window to appear
    await page.waitForSelector('text=Proxmox VE Login', { timeout: 15000 });

    // Fill username — PVE 9 uses ExtJS textfields with specific IDs
    const usernameInput = page.locator('input[name="username"]').first();
    await usernameInput.waitFor({ state: 'visible', timeout: 5000 });
    await usernameInput.click();
    await usernameInput.fill(PVE_USER.split('@')[0]);

    // Fill password
    const passwordInput = page.locator('input[name="password"]').first();
    await passwordInput.click();
    await passwordInput.fill(PVE_PASSWORD);

    // Realm defaults to "Linux PAM standard authentication" which is correct for root@pam
    // No need to change it

    // Click Login button
    await page.click('text=Login');

    // Wait for the main UI to load — the navigation tree appears after login
    // PVE 9 uses x-treelist-item for tree nodes
    await page.waitForFunction(() => {
        return document.querySelectorAll('.x-treelist-item, .x-tree-node-text').length > 0;
    }, { timeout: 30000 });

    // Small delay for UI to settle
    await page.waitForTimeout(2000);

    // Save auth state
    await page.context().storageState({ path: '.auth/pve-session.json' });
});
