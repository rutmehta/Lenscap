import assert from "node:assert/strict";
import { test } from "node:test";
import { migrationConnectionString, parseRuntimeConfig } from "../src/config.js";

const environment = {
  DATABASE_URL: "postgresql://fixture:fixture@ep-test-pooler.us-east-2.aws.neon.tech/lenscap?sslmode=require",
  DATABASE_URL_UNPOOLED: "postgresql://fixture:fixture@ep-test.us-east-2.aws.neon.tech/lenscap?sslmode=require",
  AWS_ENDPOINT_URL_S3: "https://storage.example.invalid",
  AWS_REGION: "us-east-2", AWS_ACCESS_KEY_ID: "fixture-id", AWS_SECRET_ACCESS_KEY: "fixture-secret",
};

test("runtime config requires all branch resources and rejects insecure or unsupported endpoints", () => {
  assert.equal(parseRuntimeConfig(environment).databaseUrl, environment.DATABASE_URL.replace("sslmode=require", "sslmode=verify-full"));
  for (const name of ["DATABASE_URL", "AWS_ENDPOINT_URL_S3", "AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]) {
    assert.throws(() => parseRuntimeConfig({ ...environment, [name]: "" }), { code: "configuration_error" });
  }
  assert.throws(() => parseRuntimeConfig({ ...environment, AWS_ENDPOINT_URL_S3: "http://storage.example.invalid" }), { code: "configuration_error" });
  assert.throws(() => parseRuntimeConfig({ ...environment, AWS_REGION: "us-west-2" }), { code: "configuration_error" });
});

test("migrations require an explicit direct Postgres URL and never fall back to a pooled URL", () => {
  assert.equal(migrationConnectionString(environment), environment.DATABASE_URL_UNPOOLED.replace("sslmode=require", "sslmode=verify-full"));
  assert.throws(() => migrationConnectionString({ DATABASE_URL: environment.DATABASE_URL }), /DATABASE_URL_UNPOOLED/);
  assert.throws(() => migrationConnectionString({ DATABASE_URL_UNPOOLED: environment.DATABASE_URL }), /direct/);
  assert.throws(() => migrationConnectionString({ DATABASE_URL_UNPOOLED: "not-a-url" }), /direct/);
});

test("pooled and direct database connections always verify TLS certificates and hostnames", () => {
  for (const sslmode of ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]) {
    const pooled = environment.DATABASE_URL.replace("sslmode=require", `sslmode=${sslmode}`);
    const direct = environment.DATABASE_URL_UNPOOLED.replace("sslmode=require", `sslmode=${sslmode}`);
    assert.equal(new URL(parseRuntimeConfig({ ...environment, DATABASE_URL: pooled }).databaseUrl).searchParams.get("sslmode"), "verify-full");
    assert.equal(new URL(migrationConnectionString({ DATABASE_URL_UNPOOLED: direct })).searchParams.get("sslmode"), "verify-full");
  }
  assert.equal(new URL(migrationConnectionString({ DATABASE_URL_UNPOOLED: environment.DATABASE_URL_UNPOOLED.split("?")[0] })).searchParams.get("sslmode"), "verify-full");
});
