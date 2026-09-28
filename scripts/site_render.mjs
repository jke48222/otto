#!/usr/bin/env node
//
// site_render.mjs: validate site/commerce.json and render the commercial website (SPEC-v2 §14.13).
//
// Node only, no packages. scripts/build_site.sh runs it when SITE_COMMERCIAL=1:
//   node scripts/site_render.mjs --render --site DIR --out DIR [--commerce FILE] [--sponsors 0|1] [--now ISO]
// Jalen checks his values before publishing with:
//   node scripts/site_render.mjs --check-commerce [--commerce FILE]
// --check-commerce reads only commerce.json; --render also needs release.json and appcast.xml in the
// site folder, because selling needs a downloadable trial.
//
// Both exit 0 when everything is in order and 1 with one line per problem, each naming the field and,
// where Jalen supplies the value, its J-item (§14.20). Usage errors exit 2. SITE_NOW (an ISO 8601
// instant) or --now overrides the build time, which decides whether launch pricing renders.
//

import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const PLACEHOLDER = "JALEN_MUST_SET";
export const COMMERCIAL_PAGES = ["buy.html", "thanks.html", "download.html", "terms.html", "privacy.html", "refunds.html"];
export const RENDERED_PAGES = ["index.html", ...COMMERCIAL_PAGES];

const HOUR_MS = 3_600_000;
const LAUNCH_LENGTH_MS = 7 * 24 * HOUR_MS;
// A launch week that spans a daylight saving change is 7 calendar days but 7 × 24 hours ± 1 hour.
const LAUNCH_LENGTH_TOLERANCE_MS = HOUR_MS;

const J_ITEMS = [
  [/^siteHost$/, "J8"],
  [/^downloadsHost$/, "J9"],
  [/^seller(\.|$)/, "J11"],
  [/^polar\.checkoutURL$/, "J4"],
  [/^polar(\.|$)/, "J1"],
  [/^launch\.checkoutURL$/, "J4"],
  [/^launch(\.|$)/, "J19"],
  [/^legal(\.|$)/, "J12"],
];

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// ---------------------------------------------------------------------------------------------------
// Validation

function jItemFor(field) {
  for (const [pattern, item] of J_ITEMS) {
    if (pattern.test(field)) return item;
  }
  return null;
}

function fieldProblem(field, message) {
  const item = jItemFor(field);
  return `${field}: ${message}${item ? ` (${item})` : ""}`;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function valueAt(root, field) {
  return field.split(".").reduce((node, key) => (isObject(node) ? node[key] : undefined), root);
}

function collectPlaceholders(node, path, found) {
  if (typeof node === "string") {
    if (node.includes(PLACEHOLDER)) found.set(path, node);
  } else if (Array.isArray(node)) {
    node.forEach((item, index) => collectPlaceholders(item, `${path}[${index}]`, found));
  } else if (isObject(node)) {
    for (const [key, value] of Object.entries(node)) {
      collectPlaceholders(value, path ? `${path}.${key}` : key, found);
    }
  }
  return found;
}

export function isBareHost(value) {
  return (
    typeof value === "string" &&
    value.length <= 253 &&
    /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(value)
  );
}

export function isPolarCheckoutURL(value) {
  return (
    typeof value === "string" &&
    /^https:\/\/(buy\.polar\.sh|polar\.sh)\/\S+$/.test(value)
  );
}

export function isPolarPortalURL(value) {
  return typeof value === "string" && /^https:\/\/polar\.sh\/[A-Za-z0-9][A-Za-z0-9_-]*\/portal$/.test(value);
}

export function isInstant(value) {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

export function isCalendarDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().startsWith(value);
}

export function isTimeZone(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

function isPositiveInteger(value) {
  return Number.isInteger(value) && value > 0;
}

function isPositiveAmount(value) {
  return typeof value === "number" && Number.isFinite(value) && value > 0 && Math.round(value * 100) === value * 100;
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

/**
 * Checks commerce.json against §14.13.1. Returns one message per problem ("field: what is wrong (J-item)").
 * `productionHost` is VERCEL_PROJECT_PRODUCTION_URL when the build runs on Vercel.
 */
export function validateCommerce(commerce, { productionHost = "" } = {}) {
  if (!isObject(commerce)) return ["(root): must be a JSON object"];

  const problems = [];
  const placeholders = collectPlaceholders(commerce, "", new Map());
  for (const [field, value] of placeholders) {
    problems.push(fieldProblem(field, `still the placeholder ${value}`));
  }
  // Each field reports its placeholder once and nothing else until Jalen fills it in.
  const check = (field, isValid, message) => {
    if (placeholders.has(field)) return;
    if (!isValid(valueAt(commerce, field))) problems.push(fieldProblem(field, message));
  };

  check("schema", (v) => v === 1, "must be 1");

  const hostMessage = "must be a bare host name such as otto.example.com, with no scheme, path or port";
  check("siteHost", isBareHost, hostMessage);
  check("downloadsHost", isBareHost, hostMessage);
  const production = String(productionHost || "").trim().toLowerCase();
  if (production && !placeholders.has("siteHost") && isBareHost(commerce.siteHost)) {
    if (commerce.siteHost.toLowerCase() !== production) {
      problems.push(fieldProblem("siteHost", `must equal VERCEL_PROJECT_PRODUCTION_URL (${production})`));
    }
  }

  if (!isObject(commerce.seller)) {
    problems.push(fieldProblem("seller", "must be an object with legalName, supportEmail and governingLaw"));
  } else {
    check("seller.legalName", isNonEmptyString, "must be the seller's legal name");
    check(
      "seller.supportEmail",
      (v) => typeof v === "string" && /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/.test(v),
      "must be an email address",
    );
    check("seller.governingLaw", isNonEmptyString, "must name the US state whose law governs the terms");
  }

  if (!isObject(commerce.price)) {
    problems.push(fieldProblem("price", "must be an object"));
  } else {
    check("price.usd", isPositiveAmount, "must be a positive amount in US dollars");
    check("price.seats", isPositiveInteger, "must be a positive whole number");
    check("price.trialDays", isPositiveInteger, "must be a positive whole number");
    check("price.refundDays", isPositiveInteger, "must be a positive whole number");
    check(
      "price.studentDiscountPercent",
      (v) => Number.isInteger(v) && v > 0 && v < 100,
      "must be a whole number from 1 to 99",
    );
    check("price.minMacOS", (v) => typeof v === "string" && /^\d+(\.\d+)?$/.test(v), 'must be a macOS version such as "14"');
  }

  const checkoutMessage = "must start with https://buy.polar.sh/ or https://polar.sh/";
  if (!isObject(commerce.polar)) {
    problems.push(fieldProblem("polar", "must be an object with checkoutURL and portalURL"));
  } else {
    check("polar.checkoutURL", isPolarCheckoutURL, checkoutMessage);
    check("polar.portalURL", isPolarPortalURL, "must be https://polar.sh/<slug>/portal");
  }

  const launch = commerce.launch;
  if (launch !== null) {
    if (!isObject(launch)) {
      problems.push(fieldProblem("launch", "must be null after launch week, or the launch object"));
    } else {
      check(
        "launch.usd",
        (v) => isPositiveAmount(v) && (!isPositiveAmount(commerce.price?.usd) || v < commerce.price.usd),
        "must be a positive amount below price.usd",
      );
      check("launch.startsAt", isInstant, "must be an ISO 8601 instant with a time zone, such as 2026-10-13T00:00:00-07:00");
      check("launch.endsAt", isInstant, "must be an ISO 8601 instant with a time zone, such as 2026-10-19T23:59:00-07:00");
      if (!placeholders.has("launch.startsAt") && !placeholders.has("launch.endsAt") && isInstant(launch.startsAt) && isInstant(launch.endsAt)) {
        const length = Date.parse(launch.endsAt) - Date.parse(launch.startsAt);
        if (Math.abs(length - LAUNCH_LENGTH_MS) > LAUNCH_LENGTH_TOLERANCE_MS) {
          problems.push(fieldProblem("launch.endsAt", "must be 7 days after launch.startsAt"));
        }
      }
      check("launch.timeZone", isTimeZone, "must be a time zone Intl.DateTimeFormat accepts, such as America/Los_Angeles");
      check("launch.checkoutURL", isPolarCheckoutURL, checkoutMessage);
    }
  }

  if (!isObject(commerce.legal)) {
    problems.push(fieldProblem("legal", "must be an object with approved and effectiveDate"));
  } else {
    check("legal.approved", (v) => v === true, "must be true: no unapproved legal page goes live");
    check("legal.effectiveDate", isCalendarDate, "must be a date such as 2026-10-12");
  }

  return problems;
}

/** Checks release.json (written by scripts/publish.sh) for the fields the pages use. */
export function validateRelease(release, downloadsHost) {
  if (!isObject(release)) return ["(root): must be a JSON object"];
  const problems = [];
  if (release.schema !== 1) problems.push("schema: must be 1");
  if (typeof release.version !== "string" || !/^\d+\.\d+(\.\d+)?$/.test(release.version)) {
    problems.push('version: must be a version such as "1.1.0"');
  }
  let dmgURL = null;
  try {
    dmgURL = new URL(release.dmgURL);
  } catch {
    problems.push("dmgURL: must be an https URL");
  }
  if (dmgURL) {
    if (dmgURL.protocol !== "https:") {
      problems.push("dmgURL: must be an https URL");
    } else if (isBareHost(downloadsHost) && dmgURL.hostname !== downloadsHost.toLowerCase()) {
      problems.push(`dmgURL: its host must be downloadsHost (${downloadsHost}), not ${dmgURL.hostname}`);
    }
  }
  if (typeof release.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(release.sha256)) {
    problems.push("sha256: must be 64 lowercase hex digits");
  }
  if (!isPositiveInteger(release.bytes)) problems.push("bytes: must be the disk image's size in bytes");
  return problems;
}

// ---------------------------------------------------------------------------------------------------
// Rendering

export function formatUSD(amount) {
  return Number.isInteger(amount) ? `$${amount}` : `$${amount.toFixed(2)}`;
}

/** "Oct 19, 11:59 pm PDT": the launch end in the launch's own time zone. */
export function formatLaunchEnds(instant, timeZone) {
  const text = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
    timeZone,
  }).format(new Date(instant));
  return text.replace(/[  ]/g, " ").replace(/\b(AM|PM)\b/g, (meridiem) => meridiem.toLowerCase());
}

/** "5.2 MB", in the decimal megabytes Finder shows. */
export function formatDiskImageSize(bytes) {
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

/** "October 12, 2026" for 2026-10-12. */
export function formatEffectiveDate(date) {
  return new Intl.DateTimeFormat("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" }).format(
    new Date(`${date}T00:00:00Z`),
  );
}

export function isLaunchActive(commerce, now) {
  return isObject(commerce.launch) && now.getTime() < Date.parse(commerce.launch.endsAt);
}

/** Every {{TOKEN}} of §14.13.1 for a validated commerce.json and release.json at the build time `now`. */
export function buildTokens(commerce, release, now) {
  const { price, polar, seller, launch } = commerce;
  const launchActive = isLaunchActive(commerce, now);
  const tokens = {
    PRICE: formatUSD(price.usd),
    SEATS: String(price.seats),
    TRIAL_DAYS: String(price.trialDays),
    REFUND_DAYS: String(price.refundDays),
    STUDENT_DISCOUNT: `${price.studentDiscountPercent}%`,
    MIN_MACOS: price.minMacOS,
    CHECKOUT_URL: launchActive ? launch.checkoutURL : polar.checkoutURL,
    REGULAR_CHECKOUT_URL: polar.checkoutURL,
    BUY_LABEL: `Buy Otto, ${formatUSD(launchActive ? launch.usd : price.usd)}`,
    PORTAL_URL: polar.portalURL,
    SELLER_LEGAL_NAME: seller.legalName,
    SUPPORT_EMAIL: seller.supportEmail,
    GOVERNING_LAW: seller.governingLaw,
    EFFECTIVE_DATE: formatEffectiveDate(commerce.legal.effectiveDate),
    SITE_HOST: commerce.siteHost,
    DOWNLOADS_HOST: commerce.downloadsHost,
    VERSION: release.version,
    DMG_URL: release.dmgURL,
    DMG_SIZE: formatDiskImageSize(release.bytes),
    DMG_SHA256: release.sha256,
  };
  if (isObject(launch)) {
    tokens.LAUNCH_PRICE = formatUSD(launch.usd);
    tokens.LAUNCH_ENDS = formatLaunchEnds(launch.endsAt, launch.timeZone);
    tokens.LAUNCH_ENDS_ISO = new Date(launch.endsAt).toISOString();
  }
  return tokens;
}

/**
 * Keeps or drops `<!-- name:begin -->…<!-- name:end -->` blocks. `keep` maps every allowed block name to
 * whether it stays. Each marker is a line of its own, and the whole line goes; blocks may nest, and a
 * block inside a dropped one goes with it.
 */
export function stripBlocks(text, keep, source = "page") {
  const lines = text.split("\n");
  const output = [];
  const stack = [];
  let dropDepth = 0;
  lines.forEach((line, index) => {
    const marker = /^[ \t]*<!-- ([a-z]+):(begin|end) -->[ \t\r]*$/.exec(line);
    if (!marker) {
      if (dropDepth === 0) output.push(line);
      return;
    }
    const [, name, edge] = marker;
    if (!Object.hasOwn(keep, name)) {
      throw new Error(`${source}:${index + 1}: unknown block "${name}"`);
    }
    if (edge === "begin") {
      stack.push(name);
      if (dropDepth === 0 && !keep[name]) dropDepth = stack.length;
    } else {
      if (stack.at(-1) !== name) throw new Error(`${source}:${index + 1}: unexpected ${name}:end`);
      if (dropDepth === stack.length) dropDepth = 0;
      stack.pop();
    }
  });
  if (stack.length > 0) throw new Error(`${source}: the ${stack.at(-1)} block is never closed`);
  return output.join("\n");
}

export function escapeHTML(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Replaces each {{TOKEN}} with its HTML-escaped value. An unknown token or a leftover "{{" throws. */
export function renderTokens(text, tokens, source = "page") {
  const unknown = new Set();
  const rendered = text.replace(/\{\{([A-Z0-9_]+)\}\}/g, (whole, name) => {
    if (!Object.hasOwn(tokens, name)) {
      unknown.add(name);
      return whole;
    }
    return escapeHTML(tokens[name]);
  });
  if (unknown.size > 0) {
    throw new Error(`${source}: no value for ${[...unknown].map((name) => `{{${name}}}`).join(", ")}`);
  }
  if (rendered.includes("{{")) throw new Error(`${source}: a {{ is left after rendering`);
  return rendered;
}

/** The block choices for a commercial build at `now`. */
export function commercialBlocks(commerce, now, { sponsors = false } = {}) {
  const launchActive = isLaunchActive(commerce, now);
  return { commercial: true, noncommercial: false, sponsors, launch: launchActive, regular: !launchActive };
}

export function renderPage(text, { tokens, blocks, source }) {
  return renderTokens(stripBlocks(text, blocks, source), tokens, source);
}

function readJSON(path, label, problems) {
  if (!existsSync(path)) {
    problems.push(`${label}: missing`);
    return null;
  }
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    problems.push(`${label}: not valid JSON (${error.message})`);
    return null;
  }
}

/**
 * Validates everything a commercial build needs and, only when nothing is wrong, writes index.html and
 * the six commercial pages to `outDir`. Returns the problems, one line each.
 */
export function renderSite({ siteDir, outDir, commercePath, sponsors = false, now, productionHost = "" }) {
  const problems = [];
  const commerceFile = commercePath ?? join(siteDir, "commerce.json");
  const commerce = readJSON(commerceFile, commerceFile, problems);
  if (commerce !== null) {
    problems.push(...validateCommerce(commerce, { productionHost }).map((line) => `${commerceFile}: ${line}`));
  }

  const releaseFile = join(siteDir, "release.json");
  const release = readJSON(releaseFile, `${releaseFile} (scripts/publish.sh writes it; selling needs a downloadable trial)`, problems);
  if (release !== null) {
    const downloadsHost = commerce !== null && isBareHost(commerce.downloadsHost) ? commerce.downloadsHost : "";
    problems.push(...validateRelease(release, downloadsHost).map((line) => `${releaseFile}: ${line}`));
  }

  const appcastFile = join(siteDir, "appcast.xml");
  if (!existsSync(appcastFile)) {
    problems.push(`${appcastFile}: missing (scripts/publish.sh writes it; paid copies need the update feed)`);
  }

  const sources = new Map();
  for (const page of RENDERED_PAGES) {
    const path = join(siteDir, page);
    if (existsSync(path)) sources.set(page, readFileSync(path, "utf8"));
    else problems.push(`${path}: missing`);
  }
  if (problems.length > 0) return problems;

  const tokens = buildTokens(commerce, release, now);
  const blocks = commercialBlocks(commerce, now, { sponsors });
  const rendered = new Map();
  for (const [page, text] of sources) {
    try {
      rendered.set(page, renderPage(text, { tokens, blocks, source: join(siteDir, page) }));
    } catch (error) {
      problems.push(error.message);
    }
  }
  if (problems.length > 0) return problems;

  mkdirSync(outDir, { recursive: true });
  for (const [page, html] of rendered) writeFileSync(join(outDir, page), html);
  return [];
}

// ---------------------------------------------------------------------------------------------------
// Command line

const USAGE = `usage: node scripts/site_render.mjs --check-commerce [--commerce FILE]
       node scripts/site_render.mjs --render --site DIR --out DIR [--commerce FILE] [--sponsors 0|1] [--now ISO]`;

function parseArguments(argv) {
  const options = { mode: null, commerce: null, site: null, out: null, sponsors: "0", now: null };
  const valued = { "--commerce": "commerce", "--site": "site", "--out": "out", "--sponsors": "sponsors", "--now": "now" };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--check-commerce" || argument === "--render") {
      if (options.mode) throw new Error("choose one of --check-commerce and --render");
      options.mode = argument.slice(2);
    } else if (Object.hasOwn(valued, argument)) {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("--")) throw new Error(`${argument} needs a value`);
      options[valued[argument]] = value;
      index += 1;
    } else if (argument === "-h" || argument === "--help") {
      options.mode = "help";
    } else {
      throw new Error(`unknown option ${argument}`);
    }
  }
  if (!options.mode) throw new Error("choose --check-commerce or --render");
  if (options.mode === "render" && (!options.site || !options.out)) throw new Error("--render needs --site and --out");
  if (options.sponsors !== "0" && options.sponsors !== "1") throw new Error("--sponsors must be 0 or 1");
  return options;
}

function buildTime(option) {
  const value = option ?? process.env.SITE_NOW ?? "";
  if (value === "") return new Date();
  if (!isInstant(value)) throw new Error(`SITE_NOW must be an ISO 8601 instant with a time zone, not "${value}"`);
  return new Date(value);
}

export function main(argv = process.argv.slice(2)) {
  let options;
  let now;
  try {
    options = parseArguments(argv);
    now = buildTime(options.now);
  } catch (error) {
    process.stderr.write(`error: ${error.message}\n${USAGE}\n`);
    return 2;
  }
  if (options.mode === "help") {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }
  const productionHost = process.env.VERCEL_PROJECT_PRODUCTION_URL ?? "";

  if (options.mode === "check-commerce") {
    const file = options.commerce ?? join(REPO_ROOT, "site", "commerce.json");
    const problems = [];
    const commerce = readJSON(file, file, problems);
    if (commerce !== null) problems.push(...validateCommerce(commerce, { productionHost }).map((line) => `${file}: ${line}`));
    if (problems.length > 0) {
      for (const line of problems) process.stderr.write(`error: ${line}\n`);
      return 1;
    }
    process.stdout.write(`${file}: every field is set\n`);
    return 0;
  }

  const problems = renderSite({
    siteDir: options.site,
    outDir: options.out,
    commercePath: options.commerce ?? undefined,
    sponsors: options.sponsors === "1",
    now,
    productionHost,
  });
  if (problems.length > 0) {
    for (const line of problems) process.stderr.write(`error: ${line}\n`);
    return 1;
  }
  process.stdout.write(`Rendered ${RENDERED_PAGES.length} pages into ${options.out}\n`);
  return 0;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main();
}

