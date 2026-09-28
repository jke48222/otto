#!/usr/bin/env node
//
// release_tools.mjs
// Otto
//
// Release helpers for scripts/publish.sh, the Homebrew tap and the launch-switch README edits (SPEC-v2 §14.12.2,
// §14.14, §14.15). Plain Node, no packages, so it runs anywhere `node` does.
//
//   node scripts/release_tools.mjs changelog-html --version <v> <CHANGELOG.md>
//   node scripts/release_tools.mjs release-json --version <v> --build <n> --dmg <Otto-<v>.dmg> --downloads-host <host>
//                                               [--released-at YYYY-MM-DD]
//   node scripts/release_tools.mjs cask <release.json> <commerce.json> [--template <file>]
//   node scripts/release_tools.mjs check-readme-prices <README.md> <commerce.json>
//   node scripts/release_tools.mjs hosts <commerce.json>
//
// changelog-html   the version's CHANGELOG section as an HTML fragment for the appcast (no DOCTYPE or body, so
//                  generate_appcast embeds it); every character is escaped except <kbd> tags
// release-json     site/release.json for that DMG (size and SHA-256 read from the file)
// cask             Casks/otto.rb from packaging/homebrew/otto.rb.template; the same command renders the first cask
//                  by hand at gate HM5
// check-readme-prices  every "$N", "N-day trial" and "up to N Macs" in the README equals commerce.json
// hosts            prints "siteHost <host>" and "downloadsHost <host>"; refuses placeholders and anything that isn't
//                  a bare host name
//
// Output goes to stdout. Exit: 0 success, 1 a problem (one line each on stderr), 2 usage error.

import { createHash } from "node:crypto";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const defaultTemplate = join(repoRoot, "packaging", "homebrew", "otto.rb.template");

const placeholderMarker = "JALEN_MUST_SET";
// The host rule of scripts/check_commercial_config.sh: lowercase labels, at least one dot, no scheme, port or path.
const hostPattern = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;
const versionPattern = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const buildPattern = /^[1-9][0-9]*$/;
const sha256Pattern = /^[0-9a-f]{64}$/;
const datePattern = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
const minimumSystemVersion = "14.0";

/** A problem the caller can fix: printed as one line, exit 1. */
export class ReleaseToolsError extends Error {
    constructor(problems) {
        const list = Array.isArray(problems) ? problems : [problems];
        super(list.join("\n"));
        this.problems = list;
    }
}

/** A malformed command line: printed with the usage, exit 2. */
class UsageError extends Error {}

// MARK: - hosts

/**
 * The two hosts publishing needs from site/commerce.json. Throws a ReleaseToolsError naming each bad field and its
 * open item (J8 siteHost, J9 downloadsHost).
 */
export function commerceHosts(commerce) {
    const problems = [];
    const siteHost = commerce?.siteHost;
    const downloadsHost = commerce?.downloadsHost;
    const siteProblem = hostProblem(siteHost);
    if (siteProblem) {
        problems.push(`commerce.json: siteHost ${siteProblem} (J8).`);
    } else if (siteHost.endsWith("-projects.vercel.app")) {
        problems.push("commerce.json: siteHost is a *-projects.vercel.app address, which sends visitors to the Vercel login (J8).");
    }
    const downloadsProblem = hostProblem(downloadsHost);
    if (downloadsProblem) {
        problems.push(`commerce.json: downloadsHost ${downloadsProblem} (J9).`);
    }
    if (problems.length > 0) throw new ReleaseToolsError(problems);
    return { siteHost, downloadsHost };
}

function hostProblem(value) {
    if (typeof value !== "string" || value.length === 0) return "is missing";
    if (value.includes(placeholderMarker)) return "is still a placeholder";
    if (!hostPattern.test(value)) return `is not a bare host name (no https:// and no path): "${value}"`;
    return null;
}

// MARK: - release-json

/**
 * site/release.json for a published DMG. `dmgPath` must be the notarized `Otto-<version>.dmg`; its size and SHA-256
 * are read from the file.
 */
export function releaseJSON({ version, build, dmgPath, downloadsHost, releasedAt }) {
    const problems = [];
    if (!versionPattern.test(version ?? "")) problems.push(`the version "${version}" is not MAJOR.MINOR.PATCH.`);
    if (!buildPattern.test(String(build ?? ""))) problems.push(`the build number "${build}" is not a positive integer.`);
    const hostIssue = hostProblem(downloadsHost);
    if (hostIssue) problems.push(`the downloads host ${hostIssue} (J9).`);
    if (!datePattern.test(releasedAt ?? "")) problems.push(`the release date "${releasedAt}" is not YYYY-MM-DD.`);
    const expectedName = `Otto-${version}.dmg`;
    if (basename(dmgPath ?? "") !== expectedName) {
        problems.push(`the disk image must be ${expectedName} (unnotarized builds are never published), not ${basename(dmgPath ?? "")}.`);
    }
    if (problems.length > 0) throw new ReleaseToolsError(problems);

    const bytes = readFileSync(dmgPath);
    return {
        schema: 1,
        version,
        build: String(build),
        dmgURL: `https://${downloadsHost}/releases/${expectedName}`,
        sha256: createHash("sha256").update(bytes).digest("hex"),
        bytes: statSync(dmgPath).size,
        minimumSystemVersion,
        releasedAt,
    };
}

/** Today's date on this Mac, YYYY-MM-DD. */
export function localDate(now = new Date()) {
    const pad = (number) => String(number).padStart(2, "0");
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

// MARK: - cask

/** Casks/otto.rb from the template, site/release.json and site/commerce.json. */
export function renderCask(template, release, commerce) {
    const problems = [];
    let hosts = null;
    try {
        hosts = commerceHosts(commerce);
    } catch (error) {
        if (!(error instanceof ReleaseToolsError)) throw error;
        problems.push(...error.problems);
    }
    if (release?.schema !== 1) problems.push("release.json: schema is not 1.");
    if (!versionPattern.test(release?.version ?? "")) problems.push(`release.json: version "${release?.version}" is not MAJOR.MINOR.PATCH.`);
    if (!sha256Pattern.test(release?.sha256 ?? "")) problems.push("release.json: sha256 is not 64 lowercase hex digits.");
    if (hosts && versionPattern.test(release?.version ?? "")) {
        const expectedURL = `https://${hosts.downloadsHost}/releases/Otto-${release.version}.dmg`;
        if (release.dmgURL !== expectedURL) {
            problems.push(`release.json: dmgURL is ${release.dmgURL}, but commerce.json's downloadsHost gives ${expectedURL}.`);
        }
    }
    if (problems.length > 0) throw new ReleaseToolsError(problems);

    const tokens = {
        VERSION: release.version,
        DMG_SHA256: release.sha256,
        DOWNLOADS_HOST: hosts.downloadsHost,
        SITE_HOST: hosts.siteHost,
    };
    const rendered = template.replace(/\{\{([A-Z0-9_]+)\}\}/g, (match, name) => tokens[name] ?? match);
    const leftover = rendered.match(/\{\{[^}]*\}\}/);
    if (leftover) throw new ReleaseToolsError(`the cask template has an unknown token ${leftover[0]}.`);
    return rendered;
}

// MARK: - check-readme-prices

/**
 * Every price, trial length and seat count the README states must equal site/commerce.json. Returns the lines that
 * were checked; throws a ReleaseToolsError listing each mismatch.
 */
export function checkReadmePrices(readme, commerce, readmeName = "README.md") {
    const price = commerce?.price ?? {};
    const problems = [];
    for (const [field, value] of [["price.usd", price.usd], ["price.trialDays", price.trialDays], ["price.seats", price.seats]]) {
        if (!Number.isInteger(value) || value <= 0) problems.push(`commerce.json: ${field} is not a positive whole number.`);
    }
    if (problems.length > 0) throw new ReleaseToolsError(problems);

    const rules = [
        { pattern: /\$([0-9]+(?:\.[0-9]+)?)/g, field: "price.usd", expected: price.usd, show: (text) => text },
        { pattern: /\b([0-9]+)-day (?:free )?trial/gi, field: "price.trialDays", expected: price.trialDays, show: (text) => `"${text}"` },
        { pattern: /\bup to ([0-9]+) Macs\b/gi, field: "price.seats", expected: price.seats, show: (text) => `"${text}"` },
    ];
    const checked = [];
    readme.split("\n").forEach((line, index) => {
        for (const rule of rules) {
            for (const match of line.matchAll(rule.pattern)) {
                checked.push(`${readmeName}:${index + 1}: ${match[0]}`);
                if (Number(match[1]) !== rule.expected) {
                    problems.push(`${readmeName}:${index + 1}: ${rule.show(match[0])} doesn't match ${rule.field} (${rule.expected}) in commerce.json.`);
                }
            }
        }
    });
    if (problems.length > 0) throw new ReleaseToolsError(problems);
    return checked;
}

// MARK: - changelog-html

/** The Markdown body of `## [<version>]` (or `## <version>`) in the changelog, without its heading. */
export function changelogSection(markdown, version) {
    const lines = markdown.split(/\r?\n/);
    const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const heading = new RegExp(`^## \\[?${escaped}\\]?(?:[\\s(]|$)`);
    const start = lines.findIndex((line) => heading.test(line));
    if (start < 0) throw new ReleaseToolsError(`CHANGELOG.md has no "## [${version}]" section.`);
    let end = lines.length;
    for (let index = start + 1; index < lines.length; index += 1) {
        if (/^## /.test(lines[index])) {
            end = index;
            break;
        }
    }
    const body = lines.slice(start + 1, end).join("\n").trim();
    if (body.length === 0) throw new ReleaseToolsError(`CHANGELOG.md's ${version} section is empty.`);
    return body;
}

/** The changelog section as an HTML fragment Sparkle embeds in the appcast item. */
export function changelogHTML(markdown, version) {
    return `${markdownToHTML(changelogSection(markdown, version))}\n`;
}

function escapeHTML(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// Inline Markdown after escaping: `code`, **bold**, *emphasis*, [text](https or mailto link) and <kbd> tags. Code
// spans are cut out first, so nothing inside them is interpreted.
function inline(text) {
    const spans = [];
    let html = escapeHTML(text).replace(/`([^`]+)`/g, (match, code) => {
        spans.push(`<code>${code}</code>`);
        return `\u0000${spans.length - 1}\u0000`;
    });
    html = html
        .replace(/&lt;(\/?)kbd&gt;/g, "<$1kbd>")
        .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
        .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (match, label, url) =>
            /^(https:\/\/|mailto:)/.test(url) ? `<a href="${url}">${label}</a>` : label);
    return html.replace(/\u0000([0-9]+)\u0000/g, (match, index) => spans[Number(index)]);
}

function tableCells(line) {
    return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim());
}

function markdownToHTML(markdown) {
    const lines = markdown.split("\n");
    const out = [];
    let index = 0;
    while (index < lines.length) {
        const line = lines[index];
        if (line.trim() === "") {
            index += 1;
            continue;
        }
        const heading = line.match(/^(#{3,6})\s+(.*)$/);
        if (heading) {
            const level = heading[1].length;
            out.push(`<h${level}>${inline(heading[2].trim())}</h${level}>`);
            index += 1;
            continue;
        }
        if (/^\s*\|/.test(line) && index + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[index + 1])) {
            const header = tableCells(line).map((cell) => `<th>${inline(cell)}</th>`).join("");
            const rows = [];
            index += 2;
            while (index < lines.length && /^\s*\|/.test(lines[index])) {
                rows.push(`<tr>${tableCells(lines[index]).map((cell) => `<td>${inline(cell)}</td>`).join("")}</tr>`);
                index += 1;
            }
            out.push(`<table><thead><tr>${header}</tr></thead><tbody>${rows.join("")}</tbody></table>`);
            continue;
        }
        if (/^[-*] /.test(line)) {
            const items = [];
            while (index < lines.length && (/^[-*] /.test(lines[index]) || /^\s{2,}\S/.test(lines[index]))) {
                const current = lines[index];
                if (/^[-*] /.test(current)) {
                    items.push({ text: current.slice(2).trim(), children: [] });
                } else if (/^\s{2,}[-*] /.test(current) && items.length > 0) {
                    items[items.length - 1].children.push(current.trim().slice(2).trim());
                } else if (items.length > 0) {
                    const last = items[items.length - 1];
                    if (last.children.length > 0) {
                        last.children[last.children.length - 1] += ` ${current.trim()}`;
                    } else {
                        last.text += ` ${current.trim()}`;
                    }
                }
                index += 1;
            }
            const rendered = items.map((item) => {
                const nested = item.children.length > 0
                    ? `<ul>${item.children.map((child) => `<li>${inline(child)}</li>`).join("")}</ul>`
                    : "";
                return `<li>${inline(item.text)}${nested}</li>`;
            });
            out.push(`<ul>\n${rendered.join("\n")}\n</ul>`);
            continue;
        }
        const paragraph = [];
        while (index < lines.length && lines[index].trim() !== "" && !/^(#{3,6}\s|[-*] |\s*\|)/.test(lines[index])) {
            paragraph.push(lines[index].trim());
            index += 1;
        }
        out.push(`<p>${inline(paragraph.join(" "))}</p>`);
    }
    return out.join("\n");
}

// MARK: - Command line

const usageText = `usage: release_tools.mjs changelog-html --version <v> <CHANGELOG.md>
       release_tools.mjs release-json --version <v> --build <n> --dmg <Otto-<v>.dmg> --downloads-host <host>
                                      [--released-at YYYY-MM-DD]
       release_tools.mjs cask <release.json> <commerce.json> [--template <file>]
       release_tools.mjs check-readme-prices <README.md> <commerce.json>
       release_tools.mjs hosts <commerce.json>`;

// Splits "--name value" pairs from positional arguments; every option takes a value.
function parseArguments(argv, allowedOptions, positionalCount) {
    const options = {};
    const positional = [];
    for (let index = 0; index < argv.length; index += 1) {
        const argument = argv[index];
        if (argument.startsWith("--")) {
            const name = argument.slice(2);
            if (!allowedOptions.includes(name)) throw new UsageError(`unknown option ${argument}`);
            if (index + 1 >= argv.length) throw new UsageError(`${argument} needs a value`);
            options[name] = argv[index + 1];
            index += 1;
        } else {
            positional.push(argument);
        }
    }
    if (positional.length !== positionalCount) {
        throw new UsageError(`expected ${positionalCount} file argument${positionalCount === 1 ? "" : "s"}, got ${positional.length}`);
    }
    return { options, positional };
}

function readText(path) {
    try {
        return readFileSync(path, "utf8");
    } catch {
        throw new ReleaseToolsError(`can't read ${path}.`);
    }
}

function readJSON(path) {
    const text = readText(path);
    try {
        return JSON.parse(text);
    } catch (error) {
        throw new ReleaseToolsError(`${path} is not valid JSON (${error.message}).`);
    }
}

function requireOptions(options, names) {
    for (const name of names) {
        if (options[name] === undefined) throw new UsageError(`--${name} is required`);
    }
}

export function run(argv) {
    const [command, ...rest] = argv;
    switch (command) {
        case "changelog-html": {
            const { options, positional } = parseArguments(rest, ["version"], 1);
            requireOptions(options, ["version"]);
            return changelogHTML(readText(positional[0]), options.version);
        }
        case "release-json": {
            const { options } = parseArguments(rest, ["version", "build", "dmg", "downloads-host", "released-at"], 0);
            requireOptions(options, ["version", "build", "dmg", "downloads-host"]);
            const release = releaseJSON({
                version: options.version,
                build: options.build,
                dmgPath: options.dmg,
                downloadsHost: options["downloads-host"],
                releasedAt: options["released-at"] ?? localDate(),
            });
            return `${JSON.stringify(release, null, 2)}\n`;
        }
        case "cask": {
            const { options, positional } = parseArguments(rest, ["template"], 2);
            return renderCask(readText(options.template ?? defaultTemplate), readJSON(positional[0]), readJSON(positional[1]));
        }
        case "check-readme-prices": {
            const { positional } = parseArguments(rest, [], 2);
            const checked = checkReadmePrices(readText(positional[0]), readJSON(positional[1]), basename(positional[0]));
            if (checked.length === 0) return `ok: ${basename(positional[0])} states no price, trial length or seat count\n`;
            return checked.map((line) => `ok ${line}\n`).join("");
        }
        case "hosts": {
            const { positional } = parseArguments(rest, [], 1);
            const hosts = commerceHosts(readJSON(positional[0]));
            return `siteHost ${hosts.siteHost}\ndownloadsHost ${hosts.downloadsHost}\n`;
        }
        case "-h":
        case "--help":
            return `${usageText}\n`;
        case undefined:
            throw new UsageError("a command is required");
        default:
            throw new UsageError(`unknown command ${command}`);
    }
}

function main() {
    try {
        process.stdout.write(run(process.argv.slice(2)));
        return 0;
    } catch (error) {
        if (error instanceof UsageError) {
            process.stderr.write(`release_tools.mjs: ${error.message}\n${usageText}\n`);
            return 2;
        }
        if (error instanceof ReleaseToolsError) {
            process.stderr.write(error.problems.map((problem) => `error: ${problem}\n`).join(""));
            return 1;
        }
        throw error;
    }
}

// Run as a command, not when a test imports it. Real paths on both sides, so a doubled slash or a symlinked
// directory (/var → /private/var) in the command line still counts as this file.
function isMainModule() {
    if (!process.argv[1]) return false;
    try {
        return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
    } catch {
        return false;
    }
}

if (isMainModule()) {
    process.exitCode = main();
}
