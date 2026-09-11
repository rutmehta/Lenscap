import { createApp } from "./app.js";
import type { CloudAPI } from "./contracts.js";
import { createRuntimeService } from "./runtime.js";

export function createRuntimeApp(environment: Record<string, string | undefined>) {
  let service: CloudAPI | undefined;
  return createApp({
    tokenSha256: environment.LENSCAP_DEVICE_TOKEN_SHA256,
    service: () => service ??= createRuntimeService(environment),
  });
}

export default createRuntimeApp(process.env);
