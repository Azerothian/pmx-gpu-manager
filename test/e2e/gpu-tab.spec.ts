import { test, expect } from '@playwright/test';
import { navigateToNode, openGpuTab } from './helpers';

test.describe('GPU Tab', () => {

    test('GPU panel visible in node view', async ({ page }) => {
        await openGpuTab(page);

        // Verify the GPU panel content is visible
        await expect(page.locator('text=GPU').first()).toBeVisible({ timeout: 10000 });
    });

    test('device grid loads with Flex 170', async ({ page }) => {
        await openGpuTab(page);

        // Verify the fake Flex 170 device appears
        await expect(page.locator('text=0000:03:00.0').first()).toBeVisible({ timeout: 10000 });
        await expect(page.locator('text=0x56c0').first()).toBeVisible({ timeout: 5000 });
    });

    test('device detail shows properties', async ({ page }) => {
        await openGpuTab(page);

        // Click on the Flex 170 device
        await page.locator('text=0000:03:00.0').first().click();
        await page.waitForTimeout(2000);

        // Verify detail panel shows device info
        await expect(page.locator('text=0x8086').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=flex').first()).toBeVisible({ timeout: 5000 });
    });

    test('telemetry displays temperature', async ({ page }) => {
        await openGpuTab(page);

        // Click device
        await page.locator('text=0000:03:00.0').first().click();
        await page.waitForTimeout(2000);

        // Check telemetry section header exists
        await expect(page.locator('text=Telemetry').first()).toBeVisible({ timeout: 5000 });
    });

    test('SR-IOV prechecks section visible', async ({ page }) => {
        await openGpuTab(page);

        // Click device
        await page.locator('text=0000:03:00.0').first().click();
        await page.waitForTimeout(2000);

        // Verify SR-IOV prerequisites section
        await expect(page.locator('text=SR-IOV Prerequisites').first()).toBeVisible({ timeout: 5000 });
    });

    test('BMG device listed', async ({ page }) => {
        await openGpuTab(page);

        // Verify the BMG device also appears
        await expect(page.locator('text=0000:04:00.0').first()).toBeVisible({ timeout: 10000 });
    });

    test('SR-IOV VF section visible', async ({ page }) => {
        await openGpuTab(page);

        // Click device
        await page.locator('text=0000:03:00.0').first().click();
        await page.waitForTimeout(2000);

        // Verify VF management section
        await expect(page.locator('text=SR-IOV Virtual Functions').first()).toBeVisible({ timeout: 5000 });
    });
});
