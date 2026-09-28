//
// release_tools.test.mjs
// Otto
//
// Tests scripts/release_tools.mjs (SPEC-v2 §14.12.2, §14.14, §14.17.2): the cask against the golden file (which is also
// the output of the HM5 command), release.json, changelog-html escaping, check-readme-prices and hosts. Plain
// `node --test`, no packages, no network.
//
//   node --test scripts/tests/release_tools.test.mjs

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import {
    ReleaseToolsError,
    changelogHTML,
    changelogSection,
    checkReadmePrices,
    commerceHosts,
    releaseJSON,
    renderCask,
} from "../release_tools.mjs";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const tool = join(repoRoot, "scripts", "release_tools.mjs");
const fixtures = join(repoRoot, "scripts", "tests", "fixtures", "release");
const template = readFileSync(join(repoRoot, "packaging", "homebrew", "otto.rb.template"), "utf8");
const golden = readFileSync(join(fixtures, "cask", "otto.rb.golden"), "utf8");
const readJSON = (path) => JSON.parse(readFileSync(path, "utf8"));
const caskRelease = readJSON(join(fixtures, "cask", "release.json"));
const caskCommerce = readJSON(join(fixtures, "cask", "commerce.json"));
const placeholderCommerce = readJSON(join(fixtures, "site-placeholder", "commerce.json"));
const changelog = readFileSync(join(fixtures, "CHANGELOG.fixture.md"), "utf8");

const scratch = mkdtempSync(join(tmpdir(), "release_tools_test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** Runs the tool as a command, the way publish.sh and the HM5 step do. */
function run(...args) {
    const result = spawnSync(process.execPath, [tool, ...args], { encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

/** The problems a ReleaseToolsError carries, or a failure when the call doesn't throw one. */
function problemsOf(call) {
    try {
        call();
    } catch (error) {
        assert.ok(error instanceof ReleaseToolsError, `expected a ReleaseToolsError, got ${error}`);
        return error.problems;
    }
    assert.fail("expected a ReleaseToolsError");
}

describe("cask", () => {
    test("renders the golden file from the fixtures", () => {
        assert.equal(renderCask(template, caskRelease, caskCommerce), golden);
    });

    test("the HM5 command prints the golden file", () => {
        const result = run("cask", join(fixtures, "cask", "release.json"), join(fixtures, "cask", "commerce.json"));
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stdout, golden);
    });

    test("fills every token and keeps Ruby's own interpolation", () => {
        const rendered = renderCask(template, caskRelease, caskCommerce);
        assert.doesNotMatch(rendered, /\{\{/);
        assert.match(rendered, /url "https:\/\/otto-fixture-downloads\.public\.blob\.vercel-storage\.com\/releases\/Otto-#\{version\}\.dmg",/);
        assert.match(rendered, /^  livecheck do\n    url "https:\/\/otto-fixture\.test\/appcast\.xml"\n    strategy :sparkle, &:short_version$/m);
    });

    test("refuses placeholder hosts, naming J8 and J9", () => {
        const problems = problemsOf(() => renderCask(template, caskRelease, placeholderCommerce));
        assert.deepEqual(problems, [
            "commerce.json: siteHost is still a placeholder (J8).",
            "commerce.json: downloadsHost is still a placeholder (J9).",
        ]);
    });

    test("refuses a release.json whose DMG lives on another host", () => {
        const moved = { ...caskRelease, dmgURL: "https://elsewhere.test/releases/Otto-1.1.0.dmg" };
        const problems = problemsOf(() => renderCask(template, moved, caskCommerce));
        assert.equal(problems.length, 1);
        assert.match(problems[0], /^release\.json: dmgURL is https:\/\/elsewhere\.test\/releases\/Otto-1\.1\.0\.dmg, but commerce\.json's downloadsHost gives /);
    });

    test("refuses a malformed checksum, version or schema", () => {
        const broken = { ...caskRelease, schema: 2, version: "1.1", sha256: "ABC" };
        const problems = problemsOf(() => renderCask(template, broken, caskCommerce));
        assert.deepEqual(problems, [
            "release.json: schema is not 1.",
            'release.json: version "1.1" is not MAJOR.MINOR.PATCH.',
            "release.json: sha256 is not 64 lowercase hex digits.",
        ]);
    });

    test("refuses a template token it doesn't know", () => {
        const problems = problemsOf(() => renderCask(`${template}# {{PRICE}}\n`, caskRelease, caskCommerce));
        assert.deepEqual(problems, ["the cask template has an unknown token {{PRICE}}."]);
    });

    test("exits 1 with one error line per problem", () => {
        const result = run("cask", join(fixtures, "cask", "release.json"), join(fixtures, "site-placeholder", "commerce.json"));
        assert.equal(result.status, 1);
        assert.equal(result.stdout, "");
        assert.equal(result.stderr, "error: commerce.json: siteHost is still a placeholder (J8).\nerror: commerce.json: downloadsHost is still a placeholder (J9).\n");
    });
});

describe("release-json", () => {
    const dmg = join(scratch, "Otto-1.1.0.dmg");
    const bytes = Buffer.alloc(5000, 0x6f);
    writeFileSync(dmg, bytes);
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const downloadsHost = "otto-fixture-downloads.public.blob.vercel-storage.com";

    test("describes the DMG with the schema publish.sh writes", () => {
        const release = releaseJSON({ version: "1.1.0", build: "2", dmgPath: dmg, downloadsHost, releasedAt: "2026-10-12" });
        assert.deepEqual(release, {
            schema: 1,
            version: "1.1.0",
            build: "2",
            dmgURL: `https://${downloadsHost}/releases/Otto-1.1.0.dmg`,
            sha256,
            bytes: 5000,
            minimumSystemVersion: "14.0",
            releasedAt: "2026-10-12",
        });
        assert.deepEqual(Object.keys(release), ["schema", "version", "build", "dmgURL", "sha256", "bytes", "minimumSystemVersion", "releasedAt"]);
    });

    test("the command prints the same JSON and defaults the date to today", () => {
        const result = run("release-json", "--version", "1.1.0", "--build", "2", "--dmg", dmg, "--downloads-host", downloadsHost);
        assert.equal(result.status, 0, result.stderr);
        const release = JSON.parse(result.stdout);
        assert.equal(release.sha256, sha256);
        assert.match(release.releasedAt, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/);
        assert.ok(result.stdout.endsWith("}\n"));
    });

    test("never describes an unnotarized DMG", () => {
        const unnotarized = join(scratch, "Otto-1.1.0-UNNOTARIZED.dmg");
        writeFileSync(unnotarized, bytes);
        const problems = problemsOf(() =>
            releaseJSON({ version: "1.1.0", build: "2", dmgPath: unnotarized, downloadsHost, releasedAt: "2026-10-12" }));
        assert.deepEqual(problems, ["the disk image must be Otto-1.1.0.dmg (unnotarized builds are never published), not Otto-1.1.0-UNNOTARIZED.dmg."]);
    });

    test("refuses a placeholder host, a bad build number and a bad date", () => {
        const problems = problemsOf(() =>
            releaseJSON({ version: "1.1.0", build: "0", dmgPath: dmg, downloadsHost: "JALEN_MUST_SET_BLOB_HOST", releasedAt: "12/10/2026" }));
        assert.deepEqual(problems, [
            'the build number "0" is not a positive integer.',
            "the downloads host is still a placeholder (J9).",
            'the release date "12/10/2026" is not YYYY-MM-DD.',
        ]);
    });

    test("a missing option is a usage error", () => {
        const result = run("release-json", "--version", "1.1.0", "--dmg", dmg);
        assert.equal(result.status, 2);
        assert.match(result.stderr, /^release_tools\.mjs: --build is required\nusage: /);
    });
});

describe("changelog-html", () => {
    const html = changelogHTML(changelog, "1.1.0");

    test("takes only the version's section", () => {
        assert.doesNotMatch(html, /1\.0\.9|older release|Unreleased/);
        assert.match(html, /^<h3>Added<\/h3>\n<ul>\n<li>/);
        assert.match(html, /<h3>Fixed<\/h3>/);
    });

    test("escapes HTML and keeps only kbd tags", () => {
        assert.match(html, /Replies that contain <code>&lt;script&gt;<\/code> stay text\./);
        assert.doesNotMatch(html, /<script>/);
        assert.match(html, /Polar &amp; Gumroad/);
        assert.match(html, /Quotes like &quot;this&quot; and ampersands like R&amp;D are escaped\./);
        assert.match(html, /Press <kbd>⌘<\/kbd><kbd>\.<\/kbd> to stop a reply\./);
        assert.match(html, /<strong>Settings → License<\/strong>/);
    });

    test("links only https and mailto URLs", () => {
        assert.match(html, /See <a href="https:\/\/otto-fixture\.test\/docs">the docs<\/a> and a local file\./);
        assert.doesNotMatch(html, /href="docs\//);
    });

    test("is a fragment Sparkle embeds (no DOCTYPE or body)", () => {
        assert.doesNotMatch(html, /<!DOCTYPE|<body|<html/i);
        assert.ok(html.endsWith("\n"));
    });

    test("accepts the heading forms the changelog uses", () => {
        assert.equal(changelogSection("## 1.0.0 (prepared, never tagged)\n\n- One.\n", "1.0.0"), "- One.");
        assert.equal(changelogSection("## [1.1.0] - 2026-10-12\n- Two.\n## [1.0.0]\n- One.\n", "1.1.0"), "- Two.");
        assert.deepEqual(problemsOf(() => changelogSection("## [1.1.00]\n- Two.\n", "1.1.0")),
            ['CHANGELOG.md has no "## [1.1.0]" section.']);
    });

    test("refuses a missing or empty section", () => {
        assert.deepEqual(problemsOf(() => changelogHTML(changelog, "2.0.0")), ['CHANGELOG.md has no "## [2.0.0]" section.']);
        assert.deepEqual(problemsOf(() => changelogHTML(changelog.replace("## [Unreleased]", "## [1.2.0]"), "1.2.0")),
            ["CHANGELOG.md's 1.2.0 section is empty."]);
    });

    test("the command writes the fragment and exits 1 for a missing section", () => {
        const good = run("changelog-html", "--version", "1.1.0", join(fixtures, "CHANGELOG.fixture.md"));
        assert.equal(good.status, 0, good.stderr);
        assert.equal(good.stdout, html);
        const missing = run("changelog-html", "--version", "3.0.0", join(fixtures, "CHANGELOG.fixture.md"));
        assert.equal(missing.status, 1);
        assert.equal(missing.stderr, 'error: CHANGELOG.md has no "## [3.0.0]" section.\n');
    });
});

describe("check-readme-prices", () => {
    const readme = [
        "# Otto",
        "",
        "[Download the 14-day trial](https://otto-fixture.test/download) · [Buy Otto, $19](https://otto-fixture.test/buy)",
        "",
        "Signed app $19 once, with a 14-day trial · source code free under the MIT license",
        "",
        "The signed app is $19 once, for up to 3 Macs, with every 1.x update and a 14-day trial.",
    ].join("\n");

    test("passes when every price, trial length and seat count matches commerce.json", () => {
        const checked = checkReadmePrices(readme, caskCommerce);
        assert.deepEqual(checked, [
            "README.md:3: $19",
            "README.md:3: 14-day trial",
            "README.md:5: $19",
            "README.md:5: 14-day trial",
            "README.md:7: $19",
            "README.md:7: 14-day trial",
            "README.md:7: up to 3 Macs",
        ]);
    });

    test("names each mismatch with its line and field", () => {
        const stale = readme.replace("Buy Otto, $19", "Buy Otto, $14").replace("up to 3 Macs", "up to 2 Macs")
            .replace("with a 14-day trial ·", "with a 7-day trial ·");
        assert.deepEqual(problemsOf(() => checkReadmePrices(stale, caskCommerce)), [
            "README.md:3: $14 doesn't match price.usd (19) in commerce.json.",
            'README.md:5: "7-day trial" doesn\'t match price.trialDays (14) in commerce.json.',
            'README.md:7: "up to 2 Macs" doesn\'t match price.seats (3) in commerce.json.',
        ]);
    });

    test("refuses a commerce.json without whole-number prices", () => {
        const broken = { ...caskCommerce, price: { ...caskCommerce.price, usd: "19", seats: 0 } };
        assert.deepEqual(problemsOf(() => checkReadmePrices(readme, broken)), [
            "commerce.json: price.usd is not a positive whole number.",
            "commerce.json: price.seats is not a positive whole number.",
        ]);
    });

    test("a README that names no price passes, and the command says so", () => {
        const file = join(scratch, "README.md");
        writeFileSync(file, "# Otto\n\nBuild it from source.\n");
        const result = run("check-readme-prices", file, join(fixtures, "cask", "commerce.json"));
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stdout, "ok: README.md states no price, trial length or seat count\n");
    });
});

describe("hosts", () => {
    test("prints the two hosts publishing needs", () => {
        const result = run("hosts", join(fixtures, "site", "commerce.json"));
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stdout, "siteHost otto-fixture.test\ndownloadsHost otto-fixture-downloads.public.blob.vercel-storage.com\n");
    });

    test("rejects placeholders, naming J8 and J9", () => {
        const result = run("hosts", join(fixtures, "site-placeholder", "commerce.json"));
        assert.equal(result.status, 1);
        assert.equal(result.stdout, "");
        assert.equal(result.stderr, "error: commerce.json: siteHost is still a placeholder (J8).\nerror: commerce.json: downloadsHost is still a placeholder (J9).\n");
    });

    test("rejects anything but a bare host name", () => {
        assert.deepEqual(problemsOf(() => commerceHosts({ siteHost: "https://otto.test/", downloadsHost: "Blob.Test" })), [
            'commerce.json: siteHost is not a bare host name (no https:// and no path): "https://otto.test/" (J8).',
            'commerce.json: downloadsHost is not a bare host name (no https:// and no path): "Blob.Test" (J9).',
        ]);
        assert.deepEqual(problemsOf(() => commerceHosts({ downloadsHost: "blob.test" })), ["commerce.json: siteHost is missing (J8)."]);
    });

    test("rejects the SSO-protected team alias", () => {
        assert.deepEqual(problemsOf(() => commerceHosts({ siteHost: "otto-jke48222s-projects.vercel.app", downloadsHost: "blob.test" })),
            ["commerce.json: siteHost is a *-projects.vercel.app address, which sends visitors to the Vercel login (J8)."]);
    });

    test("an unreadable or invalid file exits 1", () => {
        const invalid = join(scratch, "invalid.json");
        writeFileSync(invalid, "{ siteHost: ");
        const result = run("hosts", invalid);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /^error: .*invalid\.json is not valid JSON \(/);
        assert.equal(run("hosts", join(scratch, "missing.json")).status, 1);
    });
});

describe("command line", () => {
    test("usage errors exit 2", () => {
        assert.equal(run().status, 2);
        assert.equal(run("publish").status, 2);
        assert.equal(run("hosts").status, 2);
        assert.equal(run("cask", "--release", "x").status, 2);
    });

    test("--help prints the usage", () => {
        const result = run("--help");
        assert.equal(result.status, 0);
        assert.match(result.stdout, /^usage: release_tools\.mjs changelog-html /);
    });
});
