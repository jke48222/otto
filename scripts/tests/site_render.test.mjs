//
// site_render.test.mjs: tests for scripts/site_render.mjs (SPEC-v2 §14.13, §14.17.2).
//
// Run with `node --test scripts/tests/*.test.mjs`. No network: every case reads the committed site/
// pages and the fixtures in scripts/tests/fixtures/site/, and writes only to a temporary folder.
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  COMMERCIAL_PAGES,
  RENDERED_PAGES,
  buildTokens,
  escapeHTML,
  formatDiskImageSize,
  formatLaunchEnds,
  isLaunchActive,
  renderSite,
  renderTokens,
  stripBlocks,
  validateCommerce,
  validateRelease,
} from "../site_render.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SCRIPT = join(ROOT, "scripts/site_render.mjs");
const FIXTURES = join(ROOT, "scripts/tests/fixtures/site");
const SITE = join(ROOT, "site");

const readJSON = (path) => JSON.parse(readFileSync(path, "utf8"));
const completeCommerce = () => readJSON(join(FIXTURES, "commerce.complete.json"));
const fixtureRelease = () => readJSON(join(FIXTURES, "release.json"));
const committedCommerce = () => readJSON(join(SITE, "commerce.json"));

const DURING_LAUNCH = new Date("2026-10-15T12:00:00Z");
const AFTER_LAUNCH = new Date("2026-10-20T07:00:00Z");

const scratch = mkdtempSync(join(tmpdir(), "site-render-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

function runCLI(args, env = {}) {
  const childEnv = { ...process.env, ...env };
  delete childEnv.VERCEL_PROJECT_PRODUCTION_URL;
  delete childEnv.SITE_NOW;
  Object.assign(childEnv, env);
  return spawnSync(process.execPath, [SCRIPT, ...args], { encoding: "utf8", env: childEnv });
}

function fixtureSite(name, { commerce = completeCommerce() } = {}) {
  const dir = join(scratch, name);
  for (const page of [...RENDERED_PAGES, "styles.css", "script.js"]) cpSync(join(SITE, page), join(dir, page));
  writeFileSync(join(dir, "commerce.json"), JSON.stringify(commerce, null, 2));
  cpSync(join(FIXTURES, "release.json"), join(dir, "release.json"));
  cpSync(join(FIXTURES, "appcast.xml"), join(dir, "appcast.xml"));
  return dir;
}

describe("stripBlocks", () => {
  const page = [
    "<p>a</p>",
    "  <!-- noncommercial:begin -->",
    "<p>free</p>",
    "  <!-- noncommercial:end -->",
    "  <!-- commercial:begin -->",
    "<p>paid</p>",
    "    <!-- launch:begin -->",
    "<p>launch</p>",
    "    <!-- launch:end -->",
    "  <!-- commercial:end -->",
    "<!-- sponsors:begin -->",
    "<p>sponsor</p>",
    "<!-- sponsors:end -->",
    "<!-- Pricing -->",
    "",
  ].join("\n");
  const keep = { commercial: false, noncommercial: true, sponsors: false, launch: true, regular: false };

  test("removes whole marker lines and dropped blocks, nested ones included", () => {
    assert.equal(stripBlocks(page, keep), "<p>a</p>\n<p>free</p>\n<!-- Pricing -->\n");
  });

  test("keeps the commercial side and the sponsors block when asked", () => {
    const rendered = stripBlocks(page, { ...keep, commercial: true, noncommercial: false, sponsors: true });
    assert.equal(rendered, "<p>a</p>\n<p>paid</p>\n<p>launch</p>\n<p>sponsor</p>\n<!-- Pricing -->\n");
  });

  test("rejects unknown, crossed and unclosed blocks", () => {
    assert.throws(() => stripBlocks("<!-- promo:begin -->\n<!-- promo:end -->\n", keep), /unknown block "promo"/);
    assert.throws(
      () => stripBlocks("<!-- commercial:begin -->\n<!-- launch:begin -->\n<!-- commercial:end -->\n", keep),
      /unexpected commercial:end/,
    );
    assert.throws(() => stripBlocks("<!-- sponsors:begin -->\n<p>x</p>\n", keep), /sponsors block is never closed/);
  });

  test("the committed index.html strips to the golden flag-0 page, apart from __SITE_URL__", () => {
    const index = readFileSync(join(SITE, "index.html"), "utf8");
    const golden = readFileSync(join(FIXTURES, "index.noncommercial.golden.html"), "utf8");
    const flagZero = stripBlocks(index, { commercial: false, noncommercial: true, sponsors: false, launch: false, regular: false });
    assert.equal(flagZero.replaceAll("__SITE_URL__", "http://localhost:8000"), golden);
  });
});

describe("tokens", () => {
  test("renders every token HTML-escaped", () => {
    assert.equal(renderTokens('<a href="{{URL}}">{{NAME}}</a>', { URL: "https://x.test/?a=1&b=2", NAME: `O'Neil <co>` }),
      '<a href="https://x.test/?a=1&amp;b=2">O&#39;Neil &lt;co&gt;</a>');
    assert.equal(escapeHTML(`"&'`), "&quot;&amp;&#39;");
  });

  test("an unknown token or a leftover {{ fails", () => {
    assert.throws(() => renderTokens("{{PRICE}} {{NOPE}}", { PRICE: "$19" }, "buy.html"), /buy\.html: no value for \{\{NOPE\}\}/);
    assert.throws(() => renderTokens("{{ PRICE }}", { PRICE: "$19" }), /a \{\{ is left/);
  });

  test("launch week swaps the label and the checkout link together", () => {
    const commerce = completeCommerce();
    const during = buildTokens(commerce, fixtureRelease(), DURING_LAUNCH);
    assert.equal(during.BUY_LABEL, "Buy Otto, $14");
    assert.equal(during.CHECKOUT_URL, commerce.launch.checkoutURL);
    assert.equal(during.REGULAR_CHECKOUT_URL, commerce.polar.checkoutURL);
    assert.equal(during.LAUNCH_PRICE, "$14");
    assert.equal(during.LAUNCH_ENDS_ISO, "2026-10-20T06:59:00.000Z");

    const afterwards = buildTokens(commerce, fixtureRelease(), AFTER_LAUNCH);
    assert.equal(afterwards.BUY_LABEL, "Buy Otto, $19");
    assert.equal(afterwards.CHECKOUT_URL, commerce.polar.checkoutURL);
    assert.equal(isLaunchActive(commerce, new Date("2026-10-20T06:59:00Z")), false);
    assert.equal(isLaunchActive(commerce, new Date("2026-10-20T06:58:59Z")), true);
  });

  test("the fixed values of §14.13.1", () => {
    const tokens = buildTokens(completeCommerce(), fixtureRelease(), AFTER_LAUNCH);
    assert.equal(tokens.PRICE, "$19");
    assert.equal(tokens.SEATS, "3");
    assert.equal(tokens.TRIAL_DAYS, "14");
    assert.equal(tokens.REFUND_DAYS, "30");
    assert.equal(tokens.STUDENT_DISCOUNT, "30%");
    assert.equal(tokens.MIN_MACOS, "14");
    assert.equal(tokens.DMG_SIZE, "5.2 MB");
    assert.equal(tokens.EFFECTIVE_DATE, "October 12, 2026");
    assert.equal(formatDiskImageSize(12_960_000), "13.0 MB");
  });

  test("{{LAUNCH_ENDS}} in two time zones", () => {
    assert.equal(formatLaunchEnds("2026-10-20T06:59:00Z", "America/Los_Angeles"), "Oct 19, 11:59 pm PDT");
    assert.equal(formatLaunchEnds("2026-10-20T06:59:00Z", "America/New_York"), "Oct 20, 2:59 am EDT");
    assert.equal(formatLaunchEnds("2026-10-20T06:59:00Z", "UTC"), "Oct 20, 6:59 am UTC");
  });
});

describe("validateCommerce", () => {
  test("the complete fixture passes, and launch may be null", () => {
    assert.deepEqual(validateCommerce(completeCommerce()), []);
    assert.deepEqual(validateCommerce({ ...completeCommerce(), launch: null }), []);
  });

  test("the committed placeholders name each field and its J-item", () => {
    const problems = validateCommerce(committedCommerce());
    const expected = [
      ["siteHost", "J8"],
      ["downloadsHost", "J9"],
      ["seller.legalName", "J11"],
      ["seller.supportEmail", "J11"],
      ["seller.governingLaw", "J11"],
      ["polar.checkoutURL", "J4"],
      ["polar.portalURL", "J1"],
      ["launch.startsAt", "J19"],
      ["launch.endsAt", "J19"],
      ["launch.timeZone", "J19"],
      ["launch.checkoutURL", "J4"],
      ["legal.approved", "J12"],
      ["legal.effectiveDate", "J12"],
    ];
    for (const [field, item] of expected) {
      assert.ok(
        problems.some((line) => line.startsWith(`${field}: `) && line.endsWith(`(${item})`)),
        `no problem for ${field} (${item}) in:\n${problems.join("\n")}`,
      );
    }
    assert.equal(problems.length, expected.length, problems.join("\n"));
  });

  test("each rule of §14.13.1", () => {
    const cases = [
      [(c) => { c.siteHost = "https://otto.example.com"; }, /^siteHost: must be a bare host name/],
      [(c) => { c.downloadsHost = "blob.example.com/releases"; }, /^downloadsHost: must be a bare host name/],
      [(c) => { c.polar.checkoutURL = "https://checkout.example.com/otto"; }, /^polar\.checkoutURL: must start with https:\/\/buy\.polar\.sh\//],
      [(c) => { c.polar.portalURL = "https://polar.sh/otto-fixture"; }, /^polar\.portalURL: must be https:\/\/polar\.sh\/<slug>\/portal \(J1\)$/],
      [(c) => { c.launch.checkoutURL = "http://buy.polar.sh/x"; }, /^launch\.checkoutURL: .* \(J4\)$/],
      [(c) => { c.legal.approved = "yes"; }, /^legal\.approved: must be true/],
      [(c) => { c.legal.effectiveDate = "2026-02-30"; }, /^legal\.effectiveDate: must be a date/],
      [(c) => { c.launch.usd = 19; }, /^launch\.usd: must be a positive amount below price\.usd \(J19\)$/],
      [(c) => { c.launch.endsAt = "2026-10-21T06:59:00Z"; }, /^launch\.endsAt: must be 7 days after launch\.startsAt \(J19\)$/],
      [(c) => { c.launch.startsAt = "2026-10-13"; }, /^launch\.startsAt: must be an ISO 8601 instant/],
      [(c) => { c.launch.timeZone = "Pacific Time"; }, /^launch\.timeZone: must be a time zone Intl\.DateTimeFormat accepts/],
      [(c) => { delete c.launch; }, /^launch: must be null after launch week/],
      [(c) => { c.seller.supportEmail = "support at example.com"; }, /^seller\.supportEmail: must be an email address \(J11\)$/],
      [(c) => { c.price.studentDiscountPercent = 100; }, /^price\.studentDiscountPercent: /],
      [(c) => { c.schema = 2; }, /^schema: must be 1$/],
    ];
    for (const [mutate, pattern] of cases) {
      const commerce = completeCommerce();
      mutate(commerce);
      const problems = validateCommerce(commerce);
      assert.equal(problems.length, 1, `${pattern}: ${problems.join(" | ")}`);
      assert.match(problems[0], pattern);
    }
  });

  test("a week across a daylight saving change still counts as 7 days", () => {
    const commerce = completeCommerce();
    commerce.launch.startsAt = "2026-10-29T00:00:00-07:00";
    commerce.launch.endsAt = "2026-11-05T00:00:00-08:00";
    assert.deepEqual(validateCommerce(commerce), []);
  });

  test("siteHost must equal VERCEL_PROJECT_PRODUCTION_URL when that is set", () => {
    assert.deepEqual(validateCommerce(completeCommerce(), { productionHost: "otto.example.com" }), []);
    const problems = validateCommerce(completeCommerce(), { productionHost: "otto-jke48222.vercel.app" });
    assert.deepEqual(problems, ["siteHost: must equal VERCEL_PROJECT_PRODUCTION_URL (otto-jke48222.vercel.app) (J8)"]);
  });
});

describe("validateRelease", () => {
  test("the fixture passes; a foreign download host or a bad digest fails", () => {
    const host = completeCommerce().downloadsHost;
    assert.deepEqual(validateRelease(fixtureRelease(), host), []);
    const foreign = { ...fixtureRelease(), dmgURL: "https://github.com/jke48222/otto/releases/Otto-1.1.0.dmg" };
    assert.match(validateRelease(foreign, host)[0], /^dmgURL: its host must be downloadsHost/);
    assert.match(validateRelease({ ...fixtureRelease(), sha256: "ABC" }, host)[0], /^sha256: /);
  });
});

describe("--check-commerce", () => {
  test("exits 1 on the committed placeholders, one line per field", () => {
    const result = runCLI(["--check-commerce"]);
    assert.equal(result.status, 1);
    const lines = result.stderr.trim().split("\n");
    assert.equal(lines.length, 13, result.stderr);
    for (const field of ["siteHost", "downloadsHost", "seller.legalName", "polar.portalURL", "launch.timeZone", "legal.approved"]) {
      assert.ok(lines.some((line) => line.includes(`: ${field}: `)), `${field} missing:\n${result.stderr}`);
    }
  });

  test("exits 0 on a complete file, needing neither release.json nor appcast.xml", () => {
    const result = runCLI(["--check-commerce", "--commerce", join(FIXTURES, "commerce.complete.json")]);
    assert.equal(result.status, 0, result.stderr);
  });

  test("checks VERCEL_PROJECT_PRODUCTION_URL", () => {
    const result = runCLI(["--check-commerce", "--commerce", join(FIXTURES, "commerce.complete.json")], {
      VERCEL_PROJECT_PRODUCTION_URL: "otto-jke48222.vercel.app",
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /siteHost: must equal VERCEL_PROJECT_PRODUCTION_URL/);
  });

  test("usage errors exit 2", () => {
    assert.equal(runCLI([]).status, 2);
    assert.equal(runCLI(["--check-commerce", "--bogus"]).status, 2);
    assert.equal(runCLI(["--render", "--site", SITE]).status, 2);
    assert.equal(runCLI(["--check-commerce", "--now", "tomorrow"]).status, 2);
  });
});

describe("renderSite", () => {
  test("renders every page during launch week with the button data attributes", () => {
    const siteDir = fixtureSite("launch");
    const outDir = join(scratch, "launch-out");
    assert.deepEqual(renderSite({ siteDir, outDir, now: DURING_LAUNCH }), []);
    for (const page of RENDERED_PAGES) {
      const html = readFileSync(join(outDir, page), "utf8");
      assert.ok(!html.includes("{{"), `${page} has a token left`);
      assert.ok(!/<!-- [a-z]+:(begin|end) -->/.test(html), `${page} has a block marker left`);
      assert.ok(html.includes("not affiliated with"), `${page} lacks the shared footer`);
    }
    const buy = readFileSync(join(outDir, "buy.html"), "utf8");
    assert.ok(buy.includes("Launch price: $14 until Oct 19, 11:59 pm PDT."));
    assert.ok(
      buy.includes(
        '<a class="btn btn--primary" href="https://buy.polar.sh/polar_cl_fixtureLaunch" data-ends-at="2026-10-20T06:59:00.000Z" ' +
          'data-href-regular="https://buy.polar.sh/polar_cl_fixtureRegular" data-label-regular="Buy Otto, $19">',
      ),
    );
    assert.ok(buy.includes('<span class="btn__label">Buy Otto, $14</span>'));
    assert.match(buy, /<p class="launch-line" data-ends-at="2026-10-20T06:59:00\.000Z" data-launch-only>/);
    assert.ok(buy.includes("In the US, Canada and India, sales tax is added at checkout. Elsewhere the price includes VAT or GST."));
    assert.ok(!buy.includes("sponsor Otto on GitHub"));

    const index = readFileSync(join(outDir, "index.html"), "utf8");
    assert.ok(index.includes('<a class="notchbar__cta" href="/buy">Buy Otto</a>'));
    assert.ok(!index.includes("Get notified"));
    assert.ok(index.includes('data-ends-at="2026-10-20T06:59:00.000Z" data-label-regular="Buy Otto, $19"'));
    assert.ok(index.includes("The signed app is sold on this site instead."));
  });

  test("after launch week the launch pricing is gone", () => {
    const siteDir = fixtureSite("regular");
    const outDir = join(scratch, "regular-out");
    assert.deepEqual(renderSite({ siteDir, outDir, now: AFTER_LAUNCH, sponsors: true }), []);
    for (const page of RENDERED_PAGES) {
      const html = readFileSync(join(outDir, page), "utf8");
      assert.ok(!html.includes("data-ends-at"), `${page} still carries launch attributes`);
      assert.ok(!html.includes("Launch price"), `${page} still shows the launch price`);
      assert.ok(!html.includes("$14"), `${page} still names the launch price`);
    }
    const buy = readFileSync(join(outDir, "buy.html"), "utf8");
    assert.ok(buy.includes('<a class="btn btn--primary" href="https://buy.polar.sh/polar_cl_fixtureRegular">'));
    assert.ok(buy.includes('<span class="btn__label">Buy Otto, $19</span>'));
    assert.ok(buy.includes("sponsor Otto on GitHub"));
  });

  test("launch null renders the regular pages", () => {
    const siteDir = fixtureSite("no-launch", { commerce: { ...completeCommerce(), launch: null } });
    const outDir = join(scratch, "no-launch-out");
    assert.deepEqual(renderSite({ siteDir, outDir, now: DURING_LAUNCH }), []);
    assert.ok(readFileSync(join(outDir, "buy.html"), "utf8").includes("Buy Otto, $19"));
  });

  test("names every problem and writes nothing when anything is missing", () => {
    const siteDir = fixtureSite("placeholders", { commerce: committedCommerce() });
    rmSync(join(siteDir, "release.json"));
    rmSync(join(siteDir, "appcast.xml"));
    const outDir = join(scratch, "placeholders-out");
    const problems = renderSite({ siteDir, outDir, now: DURING_LAUNCH });
    assert.equal(problems.filter((line) => line.includes("commerce.json: ")).length, 13, problems.join("\n"));
    assert.ok(problems.some((line) => line.includes("release.json") && line.includes("missing")));
    assert.ok(problems.some((line) => line.includes("appcast.xml") && line.includes("missing")));
    assert.throws(() => readFileSync(join(outDir, "buy.html")));
  });

  test("the six commercial pages are the ones §14.13.1 lists", () => {
    assert.deepEqual(COMMERCIAL_PAGES, ["buy.html", "thanks.html", "download.html", "terms.html", "privacy.html", "refunds.html"]);
  });
});
