import { defineConfig } from "@neon/config/v1";

const tokenSha256 = process.env.LENSCAP_DEVICE_TOKEN_SHA256;
if (!tokenSha256 || !/^[a-f0-9]{64}$/.test(tokenSha256)) {
  throw new Error("Set LENSCAP_DEVICE_TOKEN_SHA256 through a private deployment environment file.");
}

export default defineConfig({
  preview: {
    buckets: { lenscap: { access: "private" } },
    functions: {
      lenscap: {
        name: "Lenscap personal cloud", source: "src/index.ts",
        env: { LENSCAP_DEVICE_TOKEN_SHA256: tokenSha256 },
      },
    },
  },
});
