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
        if (entry.provider === "cursor") {
            var grokIdx = -1;
            for (var w = 0; w < windows.length; w++) {
                if (windows[w].label === "Grok Bot" || String(windows[w].key).indexOf("cursor-grok-bot") !== -1 || String(windows[w].key).indexOf("sand-usage") !== -1) {
                    grokIdx = w;
                    break;
                }
            }
            if (grokIdx > 0) {
                var grokWin = windows.splice(grokIdx, 1)[0];
                windows.unshift(grokWin);
            }
        }
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

        // Banked Resets Parsing (for both Codex and Claude accounts)
        var bankedResets = null;

        // 1. Direct codexResetCredits payload (Codex accounts)
        if (usage.codexResetCredits && typeof usage.codexResetCredits === "object") {
            var crc = usage.codexResetCredits;
            var rawCredits = Array.isArray(crc.credits) ? crc.credits : [];
            var nowMs = Date.now();
            var activeCredits = rawCredits.filter(function(c) {
                if (!c) return false;
                if (c.status && c.status !== "available") return false;
                if (c.expires_at) {
                    var expMs = Date.parse(c.expires_at);
                    if (!isNaN(expMs) && expMs <= nowMs) return false;
                }
                return true;
            });
            var reportedCount = typeof crc.availableCount === "number" && crc.availableCount >= 0
                ? crc.availableCount
                : activeCredits.length;

            if (reportedCount > 0 || activeCredits.length > 0) {
                var cCount = Math.max(reportedCount, activeCredits.length);
                var earliestExp = null;
                for (var ci = 0; ci < activeCredits.length; ci++) {
                    var cred = activeCredits[ci];
                    if (cred && cred.expires_at) {
                        var eMs = Date.parse(cred.expires_at);
                        if (!isNaN(eMs)) {
                            if (earliestExp === null || eMs < earliestExp) {
                                earliestExp = eMs;
                            }
                        }
                    }
                }
                var expText = "";
                if (earliestExp !== null) {
                    var secDiff = Math.max(0, Math.round((earliestExp - nowMs) / 1000));
                    var days = Math.floor(secDiff / 86400);
                    var hours = Math.floor((secDiff % 86400) / 3600);
                    if (days > 0) expText = "Next expires in " + days + "d";
                    else if (hours > 0) expText = "Next expires in " + hours + "h";
                    else expText = "Next expires soon";
                }
                var cText = cCount === 1 ? "1 available" : cCount + " available";
                bankedResets = {
                    available: true,
                    count: cCount,
                    text: cText,
                    expiryText: expText,
                    summary: cText + (expText ? " · " + expText : "")
                };
            }
        }

        // 2. Direct claudeResetCredits payload (Claude accounts)
        if (!bankedResets && usage.claudeResetCredits && typeof usage.claudeResetCredits === "object") {
            var clrc = usage.claudeResetCredits;
            var rawExpirations = Array.isArray(clrc.expirations) ? clrc.expirations : [];
            var nowMsCl = Date.now();
            var activeExps = rawExpirations.filter(function(exp) {
                if (!exp) return true; // null expiry means no expiration date
                var expMs = Date.parse(exp);
                return isNaN(expMs) || expMs > nowMsCl;
            });
            if (activeExps.length > 0) {
                var clCount = activeExps.length;
                var earliestClExp = null;
                for (var cei = 0; cei < activeExps.length; cei++) {
                    var expVal = activeExps[cei];
                    if (expVal) {
                        var cMs = Date.parse(expVal);
                        if (!isNaN(cMs)) {
                            if (earliestClExp === null || cMs < earliestClExp) {
                                earliestClExp = cMs;
                            }
                        }
                    }
                }
                var clExpText = "";
                if (earliestClExp !== null) {
                    var sDiff = Math.max(0, Math.round((earliestClExp - nowMsCl) / 1000));
                    var clDays = Math.floor(sDiff / 86400);
                    var clHours = Math.floor((sDiff % 86400) / 3600);
                    if (clDays > 0) clExpText = "Next expires in " + clDays + "d";
                    else if (clHours > 0) clExpText = "Next expires in " + clHours + "h";
                    else clExpText = "Next expires soon";
                }
                var clText = clCount === 1 ? "1 available" : clCount + " available";
                bankedResets = {
                    available: true,
                    count: clCount,
                    text: clText,
                    expiryText: clExpText,
                    summary: clText + (clExpText ? " · " + clExpText : "")
                };
            }
        }

        // 3. Details section check (works for both Claude and Codex when emitted as a detail row)
        if (!bankedResets) {
            for (var dIdx = 0; dIdx < details.length; dIdx++) {
                var dSec = details[dIdx];
                for (var rIdx = 0; rIdx < (dSec.rows || []).length; rIdx++) {
                    var dRow = dSec.rows[rIdx];
                    var lLower = String(dRow.label || "").toLowerCase();
                    if (lLower.indexOf("limit reset") !== -1 || lLower.indexOf("reset credit") !== -1 || lLower.indexOf("banked reset") !== -1) {
                        var vStr = String(dRow.value || "");
                        var numMatch = vStr.match(/\d+/);
                        var rCount = numMatch ? parseInt(numMatch[0], 10) : 1;
                        var secVal = String(dRow.secondaryValue || "");
                        bankedResets = {
                            available: rCount > 0,
                            count: rCount,
                            text: vStr.trim() !== "" ? vStr : (rCount === 1 ? "1 available" : rCount + " available"),
                            expiryText: secVal,
                            summary: vStr + (secVal ? " · " + secVal : "")
                        };
                        break;
                    }
                }
                if (bankedResets) break;
            }
        }

        // Ensure details has Limit Reset Credits row if bankedResets exist
        if (bankedResets && bankedResets.available) {
            var detailRowFound = false;
            for (var df = 0; df < details.length; df++) {
                for (var rf = 0; rf < (details[df].rows || []).length; rf++) {
                    var rowLbl = String(details[df].rows[rf].label || "").toLowerCase();
                    if (rowLbl.indexOf("limit reset") !== -1 || rowLbl.indexOf("reset credit") !== -1 || rowLbl.indexOf("banked reset") !== -1) {
                        detailRowFound = true;
                        break;
                    }
                }
                if (detailRowFound) break;
            }
            if (!detailRowFound) {
                details.unshift({
                    title: "",
                    rows: [{
                        label: "Limit Reset Credits",
                        value: bankedResets.text,
                        secondaryValue: bankedResets.expiryText
                    }],
                    chart: null
                });
            }
        }

        return {
            provider: entry.provider,
            failed: !!entry.error,
            accountLabel: showIdentity ? String(identity.accountEmail || usage.accountEmail || "") : "",
            accountNumber: entryIndex + 1,
            plan: planName,
            status: entry.status ? String(entry.status.description || entry.status.indicator || "Unknown") : "",
            statusLevel: entry.status ? String(entry.status.indicator || "unknown") : "unknown",
            details: details,
            source: entry.source || "",
            windows: windows,
            updatedAt: usage.updatedAt || "",
            credits: creditsVal,
            bankedResets: bankedResets,
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

// Evaluate whether a window is being actively drained (deficit pace, burn-out projection, drop, or critical/warning)
function windowDrainScore(window, previousRemaining) {
    if (!window || typeof window.remaining !== "number") return 0;
    var pace = String(window.pace || "").toLowerCase();
    var score = 0;
    var isDraining = false;

    // 1. Explicit pace deficit or burn-out projection
    if (pace.indexOf("deficit") !== -1) {
        isDraining = true;
        score += 1000;
        var match = pace.match(/(\d+)%\s*in\s*deficit/);
        if (match) score += parseInt(match[1], 10) * 10;
    }
    if (pace.indexOf("projected empty") !== -1) {
        isDraining = true;
        score += 500;
    } else if (pace.indexOf("runs out in") !== -1) {
        isDraining = true;
        score += 300;
    }

    // 2. Active quota drop since previous refresh
    if (typeof previousRemaining === "number" && previousRemaining > window.remaining) {
        isDraining = true;
        var drop = previousRemaining - window.remaining;
        score += 2000 + drop * 50;
    }

    // 3. Critical or warning urgency
    if (window.critical === true) {
        isDraining = true;
        score += 400;
    } else if (window.warning === true) {
        isDraining = true;
        score += 200;
    }

    if (!isDraining) return 0;

    // Favor primary / 5-hour / session windows
    var isShortTerm = (window.key === "primary") || (window.windowMinutes === 300) ||
        /5[- ]?hour|5h|session/i.test(window.label || "");
    if (isShortTerm) {
        score += 250;
    }

    // Among draining windows, lower remaining is more urgent
    score += (100 - window.remaining);

    return score;
}

// Find the most drained window within an account entry
function drainingWindow(entry, previousMap) {
    if (!entry || !entry.windows || !entry.windows.length) return null;
    var bestWin = null;
    var bestScore = 0;
    for (var i = 0; i < entry.windows.length; i++) {
        var w = entry.windows[i];
        var prev = previousMap && w && w.key ? previousMap[w.key] : undefined;
        var s = windowDrainScore(w, prev);
        if (s > bestScore) {
            bestScore = s;
            bestWin = w;
        }
    }
    return bestWin;
}

// Compute the overall drain score of an account entry
function accountDrainScore(entry, previousMap) {
    if (!entry || entry.failed || !entry.windows || !entry.windows.length) return 0;
    var maxScore = 0;
    for (var i = 0; i < entry.windows.length; i++) {
        var w = entry.windows[i];
        var prev = previousMap && w && w.key ? previousMap[w.key] : undefined;
        var s = windowDrainScore(w, prev);
        if (s > maxScore) maxScore = s;
    }
    return maxScore;
}

function isAccountDraining(entry, previousMap) {
    return accountDrainScore(entry, previousMap) > 0;
}

// Reorder entries so that any account currently being drained moves to the top of the list
function prioritizeDrainingAccounts(entries, previousQuotas) {
    if (!entries || !Array.isArray(entries) || entries.length <= 1) return entries || [];
    var draining = [];
    var nonDraining = [];

    for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        var accNum = entry.accountNumber || (i + 1);
        var prevMap = previousQuotas && entry ? (previousQuotas[entry.provider + ":" + accNum] || previousQuotas[entry.provider]) : null;
        var score = accountDrainScore(entry, prevMap);
        if (score > 0) {
            var copy = {};
            for (var k in entry) {
                if (Object.prototype.hasOwnProperty.call(entry, k)) {
                    copy[k] = entry[k];
                }
            }
            copy.isDraining = true;
            copy.drainScore = score;
            var dw = drainingWindow(entry, prevMap);
            if (dw) copy.drainingWindowKey = dw.key;
            draining.push({entry: copy, score: score, originalIndex: i});
        } else {
            nonDraining.push(entry);
        }
    }

    if (draining.length === 0) return entries;

    draining.sort(function(a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return a.originalIndex - b.originalIndex;
    });

    var result = [];
    for (var j = 0; j < draining.length; j++) {
        result.push(draining[j].entry);
    }
    for (var k = 0; k < nonDraining.length; k++) {
        result.push(nonDraining[k]);
    }
    return result;
}

// Share the same compact labels and display limit between text and logo adapters.
function barSegments(entries, mode, starredModel, singleBar, previousQuotas) {
    if (!entries || !entries.length) return [];

    // Prioritize draining accounts: any account currently being drained takes precedence,
    // moves to the top and appears in the menu bar.
    var drainingAccount = null;
    var drainingWin = null;
    var maxDrainScore = 0;

    for (var d = 0; d < entries.length; d++) {
        var e = entries[d];
        var accNum = e.accountNumber || (d + 1);
        var prevMap = previousQuotas && e ? (previousQuotas[e.provider + ":" + accNum] || previousQuotas[e.provider]) : null;
        var dScore = accountDrainScore(e, prevMap);
        if (dScore > maxDrainScore) {
            maxDrainScore = dScore;
            drainingAccount = e;
            drainingWin = drainingWindow(e, prevMap);
        }
    }

    if (drainingAccount && drainingWin) {
        var dTag = drainingAccount.provider === "codex" ? "CX" :
                   drainingAccount.provider === "claude" ? "CL" :
                   drainingAccount.provider;

        var dItem = {
            provider: drainingAccount.provider,
            tag: dTag,
            text: quotaValue(drainingWin.remaining, mode) + "%",
            isDraining: true
        };

        if (drainingAccount.accountNumber && drainingAccount.accountNumber > 1) {
            dItem.accountNumber = drainingAccount.accountNumber;
        }

        return [dItem];
    }

    // When singleBar is enabled (or a starred model is present), show strictly ONE relevant bar as efficiently as possible
    if (singleBar !== false && (singleBar === true || (starredModel && (starredModel.provider || starredModel.label || starredModel.key)))) {
        var targetEntry = null;
        var targetWin = null;
        var isStarred = false;

        // 1. User-explicit starred model selection
        if (starredModel && (starredModel.provider || starredModel.label || starredModel.key)) {
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
                        targetEntry = ent;
                        targetWin = w;
                        isStarred = true;
                        break;
                    }
                }
                if (targetWin) break;
            }
        }

        // 2. Fallback: most relevant available window of the top entry (e.g. 5-hour rate limit or primary representative)
        if (!targetWin) {
            for (var i = 0; i < entries.length; i++) {
                var ent = entries[i];
                if (ent.windows && ent.windows.length) {
                    targetEntry = ent;
                    targetWin = ent.windows[0];
                    break;
                }
            }
        }

        if (targetWin && targetEntry) {
            var tag = targetEntry.provider === "codex" ? "CX" :
                      targetEntry.provider === "claude" ? "CL" :
                      targetEntry.provider;

            var item = {
                provider: targetEntry.provider,
                tag: tag,
                text: quotaValue(targetWin.remaining, mode) + "%"
            };

            if (isStarred) {
                item.isStarred = true;
                item.label = targetWin.label;
            }

            return [item];
        }
    }

    // Default 2-entry presentation for legacy callers and multi-bar tests
    return entries.slice(0, 2).map(function(entry) {
        return {
            provider: entry.provider,
            tag: entry.provider === "codex" ? "CX" : entry.provider === "claude" ? "CL" : entry.provider,
            text: entry.windows && entry.windows.length ? quotaValue(entry.windows[0].remaining, mode) + "%" : "—"
        };
    });
}

function summary(entries, mode, starredModel, singleBar, previousQuotas) {
    var shown = barSegments(entries, mode, starredModel, singleBar, previousQuotas);
    var label = shown.map(function(entry) { return (entry.isStarred ? "★ " : "") + entry.tag + " " + entry.text; }).join("  ·  ");
    if (singleBar !== false && (singleBar === true || (starredModel && starredModel.label) || (shown.length > 0 && shown[0].isDraining))) {
        return label;
    }
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
