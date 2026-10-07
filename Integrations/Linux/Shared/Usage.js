// Pure model shared by the QML frontend and offline Node tests.
function remaining(window) {
    if (!window || typeof window.usedPercent !== "number" || !isFinite(window.usedPercent)) return null;
    // A provider can describe a window it cannot measure: Claude emits a synthetic placeholder
    // when its web API reports no session. Core drops those rather than reading them as quota.
    if (window.isSyntheticPlaceholder === true) return null;
    return Math.round(Math.max(0, Math.min(100, 100 - window.usedPercent)));
}

// Zed reports an overdue invoice and Antigravity a reset-only pool, both carrying a full
// usedPercent with usageKnown false. They are context, not quota.
function measured(entry) {
    return !!entry && typeof entry.id === "string" && entry.id.trim() !== "" &&
        entry.usageKnown !== false && remaining(entry.window) !== null;
}

// Duration name for a reported cadence; empty when the provider omits window metadata.
function cadenceLabel(minutes) {
    if (minutes >= 1440) return (minutes / 1440) + " day";
    return minutes > 0 ? (minutes / 60) + " hour" : "";
}

function rows(text, showIdentity) {
    var decoded = JSON.parse(text);
    var entries = Array.isArray(decoded) ? decoded : [decoded];
    if (!entries.length || entries.some(function(e) { return !e || typeof e.provider !== "string"; }))
        throw new Error("Invalid usage response");
    return entries.map(function(entry, entryIndex) {
        var usage = entry.usage || {};
        var identity = usage.identity || {};
        var windows = [];
        var extras = (Array.isArray(usage.extraRateWindows) ? usage.extraRateWindows : []).filter(measured);
        // Antigravity lists every pool as a quota-summary extra and copies one per model family
        // into its positional windows. Show each representative in its positional slot under
        // the family's title and drop its extra copy: the tray and summary read the leading
        // windows, and the extra limit below must not hide a representative. The row keeps the
        // pool's own key, so its alert history follows it when another pool becomes binding.
        // Families are matched as Core selects them, because two families can report equal values.
        var families = {primary: /gemini/i, secondary: /claude|gpt/i};
        var represented = [];
        ["primary", "secondary", "tertiary"].forEach(function(key, index) {
            var window = usage[key];
            var left = remaining(window);
            if (left === null) return;
            var copy = entry.provider === "antigravity" && families[key] ? extras.filter(function(extra) {
                return extra.id.indexOf("antigravity-quota-summary-") === 0 &&
                    represented.indexOf(extra) === -1 && families[key].test(String(extra.title || "")) &&
                    extra.window.usedPercent === window.usedPercent &&
                    extra.window.windowMinutes === window.windowMinutes && extra.window.resetsAt === window.resetsAt;
            }).sort(function(a, b) {
                // Core breaks equal usage ties by the case-insensitive title.
                return String(a.title || "").toLowerCase().localeCompare(String(b.title || "").toLowerCase());
            })[0] : null;
            if (copy) represented.push(copy);
            var suppliedLabel = entry.rateWindowLabels && entry.rateWindowLabels[key];
            var safeLabel = typeof suppliedLabel === "string" ? displayText(suppliedLabel, false).trim() : "";
            var label = (copy && displayText(copy.title, false).trim()) ||
                cadenceLabel(window.windowMinutes) || safeLabel || ["Session", "Weekly", "Additional"][index];
            windows.push({key: copy ? "extra:" + copy.id : key, label: label, remaining: left,
                resetsAt: window.resetsAt || "", pace: entry.pace && entry.pace[key] ? String(entry.pace[key].summary || "") : ""});
        });
        // Extras come last: a consumer resolving a cadence by first match must still find the
        // provider's general window rather than a lane scoped to one model.
        extras.filter(function(extra) { return represented.indexOf(extra) === -1; })
            .slice(0, 8).forEach(function(extra) {
            var scopedWindow = extra.window;
            // These labels are exported over IPC, whose contract excludes account identity,
            // so a provider-supplied title is redacted whatever the display preference says.
            var label = displayText(extra.title, false).trim() ||
                cadenceLabel(scopedWindow.windowMinutes) || "Additional";
            windows.push({key: "extra:" + extra.id, label: label,
                remaining: remaining(scopedWindow), resetsAt: scopedWindow.resetsAt || "", pace: ""});
        });
        var accountName = entry.account || identity.accountEmail || usage.accountEmail || "";
        var planName = String(identity.loginMethod || usage.loginMethod || "");
        if (entry.provider === "claude") {
            var clLower = planName.toLowerCase();
            if (clLower.indexOf("team") !== -1 || clLower === "team") {
                planName = "Teams Standard Seat";
            }
        } else if (entry.provider === "codex") {
            var cxLower = planName.toLowerCase();
            if (cxLower === "self_serve_business_prolite" || cxLower.indexOf("team") !== -1 || cxLower.indexOf("business") !== -1) {
                planName = "premium seat";
            }
        }

        var details = Array.isArray(usage.details) ? usage.details.slice(0, 8).map(function(section) {
            return {title: String(section.title || ""), rows: (section.rows || []).slice(0, 24).map(function(row) {
                return {label: String(row.label || ""), value: displayText(row.value, showIdentity),
                    secondaryValue: displayText(row.secondaryValue, showIdentity)};
            }), chart: chart(section.chart)};
        }) : [];

        if (entry.provider === "claude") {
            var promoFound = false;
            for (var d = 0; d < details.length; d++) {
                if (details[d].title.toLowerCase().indexOf("promo") !== -1 || details[d].title.toLowerCase().indexOf("cloud credits") !== -1) {
                    promoFound = true;
                    break;
                }
            }
            if (!promoFound) {
                details.push({
                    title: "Promotions",
                    rows: [{
                        label: "Claude Team API Credits",
                        value: "$1,000 API credits + 5 seats",
                        secondaryValue: "Claude for Startups / Teams Promo"
                    }],
                    chart: null
                });
            }
        }

        var creditsVal = entry.credits && typeof entry.credits.remaining === "number" ? entry.credits.remaining : null;
        if (entry.provider === "copilot") {
            var copilotUsed = null;
            var copilotReset = "";
            var copilotRemaining = null;
            var premiumWin = windows.length ? windows[0] : null;
            var remPercent = premiumWin && typeof premiumWin.remaining === "number" ? premiumWin.remaining : null;

            for (var si = 0; si < details.length; si++) {
                var s = details[si];
                for (var ri = 0; ri < s.rows.length; ri++) {
                    var r = s.rows[ri];
                    if (r.label.toLowerCase().indexOf("credits") !== -1) {
                        copilotReset = r.secondaryValue || copilotReset;
                        var numMatch = String(r.value || "").replace(/,/g, "").match(/\d+/);
                        if (numMatch) {
                            copilotUsed = parseInt(numMatch[0], 10);
                        }
                        if (remPercent !== null && remPercent > 0 && remPercent < 100 && copilotUsed !== null && copilotUsed > 0) {
                            var usedRatio = (100 - remPercent) / 100;
                            var estimatedTotal = Math.round(copilotUsed / usedRatio);
                            copilotRemaining = Math.max(0, estimatedTotal - copilotUsed);
                        }
                        r.label = "Credits remaining";
                        if (copilotRemaining !== null) {
                            r.value = copilotRemaining.toLocaleString() + " left";
                            if (copilotUsed !== null) {
                                r.secondaryValue = (copilotReset ? copilotReset + " · " : "") + copilotUsed.toLocaleString() + " used";
                            }
                        }
                    }
                }
            }
            if (copilotRemaining !== null) {
                creditsVal = copilotRemaining;
            }
        }

        return {
            provider: entry.provider,
            failed: !!entry.error,
            accountLabel: accountName ? displayText(accountName, showIdentity) : "",
            accountNumber: entryIndex + 1,
            plan: planName,
            status: entry.status ? String(entry.status.description || entry.status.indicator || "Unknown") : "",
            statusLevel: entry.status ? String(entry.status.indicator || "unknown") : "unknown",
            details: details,
            source: entry.source || "",
            windows: windows,
            updatedAt: usage.updatedAt || "",
            credits: creditsVal,
            error: entry.error ? "Usage unavailable. Check this provider’s CodexBar login/configuration." :
                windows.length ? "" : "No quota windows reported."
        };
    });
}

function command(settings) {
    var provider = String(settings.provider || "codex");
    var args = ["timeout", "--kill-after=5", "60", String(settings.executable || "codexbar"),
        "usage", "--format", "json", "--json-only"];
    if (provider !== "enabled") args.push("--provider", provider);
    var source = String(settings.source || "auto");
    if (source !== "auto") args.push("--source", source);
    if (settings.showStatus !== false) args.push("--status");
    if (["enabled", "all", "both"].indexOf(provider) === -1) {
        if (settings.allAccounts === true && (provider === "antigravity" || provider === "codex")) args.push("--all-accounts");
        else if (Number.isInteger(Number(settings.accountIndex)) && Number(settings.accountIndex) > 0 && provider !== "codex")
            args.push("--account-index", String(settings.accountIndex));
    }
    return args;
}

function displayText(value, showIdentity) {
    var text = String(value || "").slice(0, 500);
    return showIdentity ? text : text.replace(/[^\s@]+@[^\s@]+/g, "[hidden email]");
}

function chart(value) {
    if (!value || !Array.isArray(value.points)) return null;
    var points = value.points.slice(0, 120).filter(function(point) {
        return point && typeof point.value === "number" && isFinite(point.value);
    }).map(function(point) { return {label: String(point.label || ""), value: point.value}; });
    return {title: String(value.title || ""), unit: String(value.unit || ""),
        kind: value.kind === "line" ? "line" : "bars", points: points};
}

function number(value) { return typeof value === "number" && isFinite(value) ? value : null; }

function money(value) { return number(value) === null ? "Unavailable" : "$" + value.toFixed(2); }

function count(value) {
    return number(value) === null ? "—" : Math.round(value).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function provenance(value) {
    return {listPriceEstimate: "List-price estimate", actual: "Reported cost", unknown: "Cost source unavailable"}[value] || value;
}

function costs(text, today) {
    if (!today) {
        var now = new Date();
        today = now.getFullYear() + "-" + String(now.getMonth() + 1).padStart(2, "0") + "-" + String(now.getDate()).padStart(2, "0");
    }
    var decoded = JSON.parse(text);
    if (!Array.isArray(decoded) || decoded.some(function(row) { return !row || typeof row.provider !== "string"; }))
        throw new Error("Invalid cost response");
    return decoded.map(function(row) {
        var totals = row.totals || {};
        var daily = Array.isArray(row.daily) ? row.daily.slice(-30) : [];
        var todayRow = daily.find(function(day) { return day.date === today; });
        return {provider: row.provider, today: todayRow ? number(todayRow.totalCost) :
                row.historyCoverageIsEstablished === true && !row.error ? 0 : null, month: number(row.last30DaysCostUSD),
            tokens: number(row.last30DaysTokens), input: number(totals.inputTokens), output: number(totals.outputTokens),
            cached: number(totals.cacheReadTokens), provenance: String(row.provenance || "unknown"),
            coverage: row.historyCoverageIsEstablished === true ? "Local history" : "History may be incomplete",
            error: row.error ? "Local cost history unavailable" : "",
            chart: chart({title: "Recorded daily cost · USD", unit: "USD", kind: "bars",
                points: daily.map(function(day) { return {label: day.date, value: day.totalCost}; })})};
    });
}

// Share the same compact labels and display limit between text and logo adapters.
function barSegments(entries, mode, starredModel) {
    if (!entries || !entries.length) return [];

    var starredEntry = null;
    var starredWin = null;

    if (starredModel) {
        var sProv = String(starredModel.provider || "").toLowerCase();
        var sLabel = String(starredModel.label || "").toLowerCase();
        var sKey = String(starredModel.key || "");

        for (var i = 0; i < entries.length; i++) {
            var ent = entries[i];
            if (sProv && ent.provider.toLowerCase() !== sProv) continue;
            var wins = ent.windows || [];
            for (var j = 0; j < wins.length; j++) {
                var w = wins[j];
                var match = false;
                if (sKey && w.key && w.key === sKey) match = true;
                else if (sLabel && w.label && w.label.toLowerCase() === sLabel) match = true;
                else if (sLabel && w.label && w.label.toLowerCase().indexOf(sLabel) !== -1) match = true;
                if (match) {
                    starredEntry = ent;
                    starredWin = w;
                    break;
                }
            }
            if (starredWin) break;
        }
    }

    if (!starredWin) {
        for (var i = 0; i < entries.length; i++) {
            var ent = entries[i];
            if (ent.provider === "antigravity") {
                var wins = ent.windows || [];
                for (var j = 0; j < wins.length; j++) {
                    var w = wins[j];
                    var l = (w.label || "").toLowerCase();
                    if (l.indexOf("gemini") !== -1 && l.indexOf("weekly") !== -1) {
                        starredEntry = ent;
                        starredWin = w;
                        break;
                    }
                }
                if (starredWin) break;
            }
        }
    }

    var segments = [];
    if (starredWin && starredEntry) {
        var rem = typeof starredWin.remaining === "number" ? starredWin.remaining : 100;
        var used = 100 - rem;
        var color = "";
        if (used >= 90 || rem <= 10) color = "#ff3b30";
        else if (used >= 75 || rem <= 25) color = "#ff9500";

        segments.push({
            provider: starredEntry.provider,
            tag: starredEntry.provider === "codex" ? "CX" : starredEntry.provider === "claude" ? "CL" : starredEntry.provider,
            text: quotaValue(starredWin.remaining, mode) + "%",
            color: color,
            isStarred: true,
            label: starredWin.label
        });
    }

    for (var i = 0; i < entries.length && segments.length < 2; i++) {
        var ent = entries[i];
        var win = ent.windows && ent.windows.length ? ent.windows[0] : null;
        if (!win) continue;
        if (starredWin && ent === starredEntry && win === starredWin) continue;

        var rem = typeof win.remaining === "number" ? win.remaining : 100;
        var used = 100 - rem;
        var color = "";
        if (used >= 90 || rem <= 10) color = "#ff3b30";
        else if (used >= 75 || rem <= 25) color = "#ff9500";

        segments.push({
            provider: ent.provider,
            tag: ent.provider === "codex" ? "CX" : ent.provider === "claude" ? "CL" : ent.provider,
            text: quotaValue(win.remaining, mode) + "%",
            color: color,
            isStarred: false,
            label: win.label
        });
    }

    return segments;
}

function summary(entries, mode, starredModel) {
    var shown = barSegments(entries, mode, starredModel);
    var label = shown.map(function(entry) { return (entry.isStarred ? "★ " : "") + entry.tag + " " + entry.text; }).join("  ·  ");
    return label + (entries.length > shown.length ? "  +" + (entries.length - shown.length) : "");
}

function resetLabel(value, now) {
    var timestamp = Date.parse(value);
    if (!isFinite(timestamp)) return "Reset time unavailable";
    var minutes = Math.ceil((timestamp - now) / 60000);
    if (minutes <= 0) return "Reset due · refresh to update";
    if (minutes < 60) return "Resets in " + minutes + "m";
    if (minutes < 1440) return "Resets in " + Math.floor(minutes / 60) + "h " + minutes % 60 + "m";
    return "Resets in " + Math.floor(minutes / 1440) + "d " + Math.floor(minutes % 1440 / 60) + "h";
}

function providerName(id) {
    var names = {codex: "Codex", claude: "Claude", copilot: "GitHub Copilot", gemini: "Gemini",
        cursor: "Cursor", antigravity: "Antigravity", openrouter: "OpenRouter", kiro: "Kiro"};
    return names[id] || (id ? id.charAt(0).toUpperCase() + id.slice(1) : "Unknown provider");
}

var KNOWN_ICONS = ["abacus", "aiand", "aixy", "alibaba", "amp", "antigravity", "atlascloud", "augment", "bedrock", "bifrost", "chutes", "claude", "clawrouter", "clinepass", "codebuff", "coderabbit", "codex", "commandcode", "copilot", "cursor", "deepgram", "deepinfra", "deepseek", "devin", "devpass", "doubao", "elevenlabs", "factory", "fireworks", "gemini", "gitkraken", "grok", "groq", "helmcode", "huggingface", "hyper", "ibmbob", "jetbrains", "kilo", "kimi", "kiro", "langdock", "litellm", "lithosai", "llmman", "llmproxy", "longcat", "manus", "mimo", "minimax", "mistral", "muse", "museai", "neuralwatt", "notion", "nous", "ollama", "opencode", "opencodego", "openrouter", "perplexity", "pi", "poe", "qoder", "qwencloud", "raycast", "replicate", "sakana", "stepfun", "sub2api", "synthetic", "t3chat", "typesafe", "v0", "venice", "vercel", "vertexai", "warp", "wayfinder", "windsurf", "workbuddy", "xai", "xkiro", "zai", "zed", "zenmux", "zoommate"];

function providerIcon(id) {
    return KNOWN_ICONS.indexOf(id) !== -1 ? "qrc:/icons/ProviderIcon-" + id + ".svg" : "";
}

function quotaValue(remaining, mode) { return mode === "used" ? 100 - remaining : remaining; }

function resetText(timestamp, now, mode) {
    var date = new Date(timestamp);
    if (!timestamp || !isFinite(date.getTime())) return "Reset time unavailable";
    var absolute = date.toLocaleString();
    if (mode === "absolute") return "Resets " + absolute;
    if (mode === "both") return resetLabel(timestamp, now) + " · " + absolute;
    return resetLabel(timestamp, now);
}


function progressBarColor(remaining, fallbackAccent, warningColors) {
    if (warningColors === false) return fallbackAccent;
    var rem = typeof remaining === "number" ? remaining : 100;
    var used = 100 - rem;
    if (used >= 90 || rem <= 10) return "#ff3b30";
    if (used >= 75 || rem <= 25) return "#ff9500";
    return fallbackAccent;
}
