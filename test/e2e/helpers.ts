import { Page, expect } from '@playwright/test';

const PVE_PASSWORD = process.env.PVE_PASSWORD || 'testpassword';
const PVE_USER = process.env.PVE_USER || 'root@pam';

/**
 * Login to PVE and dismiss any popups. Call at the start of every test.
 */
export async function ensureLoggedIn(page: Page) {
    await page.goto('/');

    // Check if login dialog appears
    try {
        await page.waitForSelector('text=Proxmox VE Login', { timeout: 5000 });
    } catch {
        // Already logged in or different page state
        await page.waitForTimeout(2000);
        return;
    }

    // Fill username and password
    await page.locator('input[name="username"]').first().click();
    await page.locator('input[name="username"]').first().fill(PVE_USER.split('@')[0]);
    await page.locator('input[name="password"]').first().click();
    await page.locator('input[name="password"]').first().fill(PVE_PASSWORD);

    // Click Login button (ExtJS: <a class="x-btn"><span class="x-btn-inner">Login</span></a>)
    await page.locator('.x-btn-inner:text-is("Login")').click();

    // Wait for login form to disappear (look for the username field to be gone)
    await page.waitForSelector('input[name="username"]', { state: 'hidden', timeout: 15000 });
    await page.waitForTimeout(2000);

    // Dismiss "No valid subscription" nag dialog
    try {
        const okBtn = page.locator('.x-btn-inner:text-is("OK")').first();
        await okBtn.waitFor({ state: 'visible', timeout: 5000 });
        await okBtn.click();
        await page.waitForTimeout(1000);
    } catch {
        // No subscription dialog
    }

    // Wait for masks to clear
    await page.waitForTimeout(1000);
}

/**
 * Navigate to the node view by clicking pve-test in the tree.
 */
export async function navigateToNode(page: Page) {
    await ensureLoggedIn(page);

    // Click the pve-test node in the navigation tree
    // PVE 9 uses x-tree-node-text for tree items
    const nodeItem = page.locator('.x-tree-node-text:has-text("pve-test")').first();
    await nodeItem.waitFor({ state: 'visible', timeout: 10000 });
    await nodeItem.click({ force: true });
    await page.waitForTimeout(3000);
}

/**
 * Navigate to the node view where GPU panel is automatically visible.
 * In PVE 9, our plugin adds the GPU panel to the node view via override,
 * so it's visible as soon as you navigate to the node.
 */
export async function openGpuTab(page: Page) {
    await navigateToNode(page);

    // Click the GPU item in the tree navigation
    const gpuItem = page.locator('.x-treelist-item-text:has-text("GPU")').first();
    await gpuItem.scrollIntoViewIfNeeded();
    await gpuItem.click({ timeout: 10000 });
    await page.waitForTimeout(2000);
}

/**
 * Open the Create VFs dialog for device 0000:03:00.0
 */
export async function openCreateVfsDialog(page: Page) {
    await openGpuTab(page);

    // Click the Flex 170 device row
    await page.locator('text=0000:03:00.0').first().click();
    await page.waitForTimeout(1000);

    // Click Create VFs button
    await page.locator('.x-btn-inner:has-text("Create")').first().click();

    // Wait for dialog
    const dialog = page.locator('.x-window').last();
    await expect(dialog).toBeVisible({ timeout: 5000 });
    return dialog;
}
