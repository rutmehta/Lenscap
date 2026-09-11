# Lenscap personal cloud backend

Private Hono API for a single person's Lenscap devices, deployed on Neon Functions with Drizzle/Postgres metadata and a private S3-compatible bucket.

See [the contract and operations guide](../docs/personal-cloud.md) for upload retries, authentication, link expiry, deletion limitations, quotas, and deployment.

**Upcoming private 1.1.1 navigation — verification pending:** Click the Lenscap menu-bar icon normally for the native menu, then choose **Cloud Library** or **Settings… → Cloud → Open Cloud Library…**. The menu also offers **Check for Updates…** and capture commands. If the icon is hidden, reopening Lenscap shows its capture-controls window when no windows are visible; choose that window's explicit **Settings** button. Reopening does not automatically open Settings or replace a visible window. Capture entry hides Settings and the capture controls, with no automatic restoration afterward.

Use the library's **New Capture** menu for another capture. All new normal captures and explicitly saved edits upload automatically, with no history backfill. The Free storage allowance is 5 GB across the Neon account, with no automatic paid upgrade.

The [historical verification record](../docs/personal-cloud.md#verified-private-build) covers the privately installed, non-notarized 1.1.0 build and live development/main checks. It does not verify the 1.1.1 navigation changes. The upcoming 1.1.1 build is also private and not notarized; neither record describes a published public release.

```sh
npm ci --ignore-scripts
npm run check
```

Tests use local PGlite and fake storage; no credentials are needed. Production runs Node 24; local checks support Node 22 or newer.

Schema changes use `npm run db:generate`. `npm run db:migrate` requires an injected direct `DATABASE_URL_UNPOOLED`; it never uses the pooled runtime URL. Deploy only after selecting the intended Neon project/branch and supplying a private environment file containing `LENSCAP_DEVICE_TOKEN_SHA256`.
