// Run: node tests/model_test.mjs   (checks Model.js times, zones, schedule and input handling)
import { readFileSync } from "node:fs"
import assert from "node:assert/strict"
const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const names = [...src.matchAll(/^function (\w+)/gm)].map((m) => m[1])
const M = new Function(src + "; return { " + names.join(", ") + ", METHOD_NAMES, PRAYERS }")()
const fixture = (name) => readFileSync(new URL(name, import.meta.url), "utf8")

const hm = (s) => { const [h, m] = s.split(":").map(Number); return h * 60 + m }
const umm = { method: "Makkah", asr: "Standard" }
const MIN = 60000

// ---- Calculation -----------------------------------------------------------

// Makkah, 10 Nov 2026, Umm al-Qura + standard Asr, matches the published
// reference (api.aladhan.com method 4, school 0) to the minute.
assert.deepEqual(M.compute(2026, 11, 10, 21.4225, 39.8262, 3, umm), {
  fajr: hm("05:10"), sunrise: hm("06:29"), dhuhr: hm("12:05"),
  asr: hm("15:17"), maghrib: hm("17:40"), isha: hm("19:10")
})

const lh = M.compute(2026, 11, 10, 31.5204, 74.3587, 5, umm)
assert.ok(lh.fajr < lh.sunrise && lh.sunrise < lh.dhuhr && lh.dhuhr < lh.asr && lh.asr < lh.maghrib && lh.maghrib < lh.isha)
assert.equal(lh.isha - lh.maghrib, 90)
assert.ok(lh.dhuhr > hm("11:30") && lh.dhuhr < hm("12:15"))

// Ramadan (12 Ramadan 1447 = 1 Mar 2026): Isha 120 minutes after Maghrib; Qatar stays at 90.
assert.equal(M.hijri(2026, 3, 1).month, 9)
const rm = M.compute(2026, 3, 1, 31.5204, 74.3587, 5, umm)
assert.equal(rm.isha - rm.maghrib, 120)
const qa = M.compute(2026, 3, 1, 25.2854, 51.531, 3, { method: "Qatar", asr: "Standard" })
assert.equal(qa.isha - qa.maghrib, 90)

assert.ok(M.compute(2026, 11, 10, 31.5204, 74.3587, 5, { method: "Makkah", asr: "Hanafi" }).asr > lh.asr)
for (const method of M.METHOD_NAMES) {
  const t = M.compute(2026, 11, 10, 31.5204, 74.3587, 5, { method, asr: "Standard" })
  assert.ok(t.fajr < t.sunrise && t.maghrib < t.isha, method)
}
// Singapore's 20° Fajr is earlier than Karachi's 18°.
assert.ok(M.compute(2026, 11, 10, 1.35, 103.82, 8, { method: "Singapore" }).fajr < M.compute(2026, 11, 10, 1.35, 103.82, 8, { method: "Karachi" }).fajr)

// ---- Time zones --------------------------------------------------------------

assert.equal(M.parseOffset("+05"), 300)
assert.equal(M.parseOffset("-0330"), -210)
assert.equal(M.parseOffset("+0545"), 345)
assert.equal(M.parseOffset("+99"), null)
assert.equal(M.parseOffset("x"), null)

const karachi = M.parseZoneDump(fixture("zone_Asia_Karachi.txt"), "Asia/Karachi")
const london = M.parseZoneDump(fixture("zone_Europe_London.txt"), "Europe/London")
const newYork = M.parseZoneDump(fixture("zone_America_New_York.txt"), "America/New_York")
assert.deepEqual(karachi, { id: "Asia/Karachi", base: 300, steps: [] })
assert.equal(london.steps.length, 10)
// BST starts 29 Mar 2026 at 01:00 UTC and ends 25 Oct 2026 at 01:00 UTC.
assert.equal(M.offsetAt(london, Date.UTC(2026, 2, 29, 0, 59)), 0)
assert.equal(M.offsetAt(london, Date.UTC(2026, 2, 29, 1, 0)), 60)
assert.equal(M.offsetAt(london, Date.UTC(2026, 9, 25, 0, 59)), 60)
assert.equal(M.offsetAt(london, Date.UTC(2026, 9, 25, 1, 0)), 0)
assert.equal(M.offsetAt(newYork, Date.UTC(2026, 6, 1)), -240)
assert.equal(M.offsetAt(newYork, Date.UTC(2026, 0, 1)), -300)
assert.equal(M.parseZoneDump("garbage", "x"), null)
assert.equal(M.parseZoneDump("-\t-\t+01\tCET\n", "../etc/passwd").id, "")
assert.equal(M.offsetAt(5, 0), 300) // a number is fixed hours

// Wall clock <-> instants, including DST gaps and overlaps.
const d = M.mkDate(2026, 3, 29)
assert.equal(M.wallToMs(d, 12 * 60, london), Date.UTC(2026, 2, 29, 11, 0))
assert.equal(M.wallToMs(d, 60 + 30, london), Date.UTC(2026, 2, 29, 1, 30)) // 01:30 is in the gap: moves to 02:30 BST
assert.equal(M.wallToMs(M.mkDate(2026, 10, 25), 90, london), Date.UTC(2026, 9, 25, 0, 30)) // overlap: the earlier (BST)
assert.equal(M.localDate(Date.UTC(2026, 10, 9, 23, 30), karachi).key, "2026-11-10")
assert.deepEqual(M.clock(Date.UTC(2026, 6, 1, 11, 0), london), { h: 12, m: 0 })
assert.equal(M.addDays(M.mkDate(2026, 12, 31), 1).key, "2027-01-01")
assert.equal(M.mkDate(2026, 11, 13).weekday, 5) // a Friday
assert.equal(M.validZoneId("Asia/Karachi"), true)
assert.equal(M.validZoneId("America/Argentina/Buenos_Aires"), true)
assert.equal(M.validZoneId("UTC"), true)
for (const bad of ["../x", "Asia/../etc", "a b", "", "Asia/<b>", "/etc/passwd"]) assert.equal(M.validZoneId(bad), false, bad)

// London prayer times follow BST: Dhuhr near 12:00 GMT in winter, 13:00 BST in summer.
const lon = { name: "London", lat: 51.5074, lon: -0.1278, zone: london }
const dhuhr = (ms) => M.clock(M.day(ms, lon, umm, 0).find((r) => r.key === "dhuhr").at, london)
assert.equal(dhuhr(Date.UTC(2026, 0, 15, 9)).h, 12)
assert.equal(dhuhr(Date.UTC(2026, 6, 15, 9)).h, 13)

// ---- Schedule at Lahore ------------------------------------------------------

const lahore = { name: "Lahore", lat: 31.5204, lon: 74.3587, zone: karachi }
const noon = Date.UTC(2026, 10, 10, 7, 0) // 12:00 in Lahore, a Tuesday
const rows = M.day(noon, lahore, umm, 0)
const at = Object.fromEntries(rows.map((r) => [r.key, r.at]))
assert.equal(rows[0].weekday, 2)
assert.equal(rows[0].date, "2026-11-10")
assert.equal(M.next(noon, lahore, umm).key, "asr")
const late = Date.UTC(2026, 10, 10, 18, 0) // 23:00: next is tomorrow's Fajr
assert.equal(M.next(late, lahore, umm).key, "fajr")
assert.equal(M.next(late, lahore, umm).date, "2026-11-11")

// Phase: + after a prayer until halfway, then − to the next time.
const p1 = M.phase(at.dhuhr + 10 * MIN, lahore, umm)
assert.equal(p1.current.key, "dhuhr"); assert.equal(p1.target.key, "asr"); assert.equal(p1.since, true)
assert.equal(p1.anchor.key, "dhuhr")
const p2 = M.phase(at.asr - 10 * MIN, lahore, umm)
assert.equal(p2.since, false); assert.equal(p2.anchor.key, "asr")
const p3 = M.phase(at.sunrise + 1 * MIN, lahore, umm) // after Sunrise: straight down to Dhuhr
assert.equal(p3.current.key, "sunrise"); assert.equal(p3.since, false); assert.equal(p3.target.key, "dhuhr")
assert.equal(M.phase(late, lahore, umm).current.key, "isha")
assert.deepEqual(M.counter(at.dhuhr + 43 * MIN + 9000, p1, true), { sign: "+", h: 0, m: 43, s: 9 })
assert.deepEqual(M.counter(at.asr - 29 * MIN - 54000, p2, true), { sign: "−", h: 0, m: 29, s: 54 })
assert.deepEqual(M.counter(at.asr - 29 * MIN - 54000, p2, false), { sign: "−", h: 0, m: 30, s: 0 }) // rounded up
assert.deepEqual(M.counter(at.dhuhr + 43 * MIN + 59000, p1, false), { sign: "+", h: 0, m: 43, s: 0 }) // floored

// Windows and the current prayer.
const w = M.windows(M.mkDate(2026, 11, 10), lahore, umm, 15)
assert.deepEqual(w.map((x) => x.key), M.PRAYERS)
assert.equal(w[0].end, at.sunrise)
assert.equal(w[1].end, at.asr)
assert.equal(w[2].ask, at.maghrib - 15 * MIN)
assert.equal(M.current(noon, lahore, umm).key, "dhuhr")
assert.equal(M.current(at.sunrise + MIN, lahore, umm).key, "fajr") // between times: the last that began

// Check-ins: once per prayer, 15 minutes before its time ends.
const askAsr = at.maghrib - 15 * MIN
assert.deepEqual(M.checkIns(askAsr - 5000, askAsr + 5000, lahore, umm, 15).map((c) => c.key + "@" + c.date), ["asr@2026-11-10"])
assert.equal(M.checkIns(askAsr + 5000, askAsr + 15000, lahore, umm, 15).length, 0)
const day1 = M.checkIns(at.fajr - 1, at.fajr + 30 * 3600000, lahore, umm, 15, 48 * 3600000).filter((c) => c.date === "2026-11-10")
assert.deepEqual(day1.map((c) => c.key).sort(), ["asr", "dhuhr", "fajr", "isha", "maghrib"])

// ---- Jamaat ------------------------------------------------------------------

assert.deepEqual(M.parseJamaat("13:30"), { minute: 810 })
assert.deepEqual(M.parseJamaat(" 1:30 pm "), { minute: 810 })
assert.deepEqual(M.parseJamaat("12:15 AM"), { minute: 15 })
assert.deepEqual(M.parseJamaat("+15"), { after: 15 })
assert.deepEqual(M.parseJamaat("+ 5"), { after: 5 })
for (const bad of ["", "25:00", "13:60", "+500", "13:30 pm", "abc", "<b>1:00</b>", null]) assert.equal(M.parseJamaat(bad), null, String(bad))
assert.equal(M.jamaatValid(""), true)
assert.equal(M.jamaatValid("13:3"), false)
assert.equal(M.jamaatText({ minute: 545 }), "09:05")
assert.equal(M.jamaatText({ after: 15 }), "+15")
assert.equal(M.jamaatText({ minute: 945 }, true), "3:45 pm")
assert.equal(M.jamaatText({ minute: 5 }, true), "12:05 am")
assert.equal(M.jamaatText({ minute: 720 }, true), "12:00 pm")

const rules = M.jamaatRules({ dhuhr: "13:30", asr: "+20", maghrib: "nonsense", jumuah: "13:45", extra: "1:00" })
assert.deepEqual(Object.keys(rules).sort(), ["asr", "dhuhr", "jumuah"])
const rowOf = (k) => rows.find((r) => r.key === k)
assert.equal(M.jamaatAt(rowOf("dhuhr"), rules, karachi), M.wallToMs(M.mkDate(2026, 11, 10), 810, karachi))
assert.equal(M.jamaatAt(rowOf("asr"), rules, karachi), at.asr + 20 * MIN)
assert.ok(isNaN(M.jamaatAt(rowOf("maghrib"), rules, karachi)))
assert.ok(isNaN(M.jamaatAt(rowOf("sunrise"), rules, karachi)))
assert.ok(isNaN(M.jamaatAt(rowOf("dhuhr"), M.jamaatRules({ dhuhr: "06:00" }), karachi))) // before the azan
// Friday: Jumu'ah replaces Dhuhr when set.
const friday = M.dayRows(M.mkDate(2026, 11, 13), lahore, umm).find((r) => r.key === "dhuhr")
assert.equal(M.jamaatKey("dhuhr", 5, rules), "jumuah")
assert.equal(M.jamaatKey("dhuhr", 5, {}), "dhuhr")
assert.equal(M.jamaatAt(friday, rules, karachi), M.wallToMs(M.mkDate(2026, 11, 13), 825, karachi))

// ---- Events ------------------------------------------------------------------

const cfg = { azan: { fajr: true, dhuhr: true, asr: true, maghrib: true }, rules, jamaatLead: 20 }
const kinds = (list) => list.map((e) => e.kind + ":" + e.key + (e.azan ? "+azan" : ""))
assert.deepEqual(kinds(M.due(at.asr - 15000, at.asr + 5000, lahore, umm, { ...cfg, rules: {} })), ["start:asr+azan"])
assert.equal(M.due(at.asr + 5000, at.asr + 20000, lahore, umm, cfg).length, 0)
assert.equal(M.due(at.asr, at.asr, lahore, umm, cfg).length, 0)
// Isha isn't in the azan set: the start fires without the azan.
assert.deepEqual(kinds(M.due(at.isha - 1000, at.isha + 1000, lahore, umm, cfg)), ["start:isha"])
// Jamaat reminder 20 minutes before Dhuhr jamaat at 13:30.
const dj = M.wallToMs(M.mkDate(2026, 11, 10), 810, karachi)
assert.deepEqual(kinds(M.due(dj - 20 * MIN - 1000, dj - 20 * MIN + 1000, lahore, umm, cfg)), ["jamaat:dhuhr"])
assert.equal(M.due(dj - 20 * MIN - 1000, dj - 20 * MIN + 1000, lahore, umm, cfg)[0].jamaat, dj)
// Asr jamaat at +20 with a 20-minute lead: the reminder lands with the azan, after it in order.
assert.deepEqual(kinds(M.due(at.asr - 1000, at.asr + 1000, lahore, umm, cfg)), ["start:asr+azan", "jamaat:asr"])
// Waking from sleep: within 15 minutes the azan still rings.
assert.deepEqual(kinds(M.due(at.asr - 3600000, at.asr + 10 * MIN, lahore, umm, cfg)), ["start:asr+azan", "jamaat:asr"])
// Later: a quiet "began" for the latest prayer only, and no stale jamaat reminder.
assert.deepEqual(kinds(M.due(at.fajr - MIN, at.asr + 30 * MIN, lahore, umm, cfg)), ["began:asr"])
// Jamaat reminder due during sleep still fires while the jamaat hasn't begun.
assert.deepEqual(kinds(M.due(at.dhuhr - MIN, dj - 5 * MIN, lahore, umm, cfg)), ["began:dhuhr", "jamaat:dhuhr"])
assert.equal(M.due(dj - 3600000, dj + MIN, lahore, umm, cfg).filter((e) => e.kind === "jamaat").length, 0)
// Woken after a prayer's time ended: nothing.
assert.deepEqual(kinds(M.due(at.fajr - MIN, at.sunrise + 10 * MIN, lahore, umm, cfg)), [])

// ---- Hijri -------------------------------------------------------------------

const h0 = M.hijriOf(M.mkDate(2026, 3, 1), 0)
assert.deepEqual([h0.month, h0.day], [9, 12])
assert.equal(M.hijriOf(M.mkDate(2026, 3, 1), 1).day, 13)
assert.equal(M.hijriOf(M.mkDate(2026, 3, 1), -9).day, 10) // clamped to -2

// ---- Location ----------------------------------------------------------------

assert.deepEqual(M.parsePlaceJson('{"name":"Lahore","latitude":31.558,"longitude":74.35071,"country":"PK","timezone":"Asia/Karachi"}'),
  { name: "Lahore", lat: 31.558, lon: 74.35071, zone: "Asia/Karachi" })
assert.equal(M.parsePlaceJson('{"name":"<img src=x>Multan","lat":"30.1","lon":"71.5","zone":"../../etc"}').name, "img src=xMultan")
assert.equal(M.parsePlaceJson('{"name":"<img src=x>Multan","lat":"30.1","lon":"71.5","zone":"../../etc"}').zone, "")
assert.equal(M.parsePlaceJson('{"lat":true,"lon":1}'), null)
assert.equal(M.parsePlaceJson('{"lat":91,"lon":1}'), null)
assert.equal(M.parsePlaceJson("nope"), null)
assert.equal(M.parsePlaceJson('{"lat":1,"lon":2}').name, "1.00, 2.00")
assert.equal(M.parsePlaceJson(JSON.stringify({ name: "x".repeat(500), lat: 1, lon: 1 })).name.length, 60)

const geo = M.parseGeocoding(JSON.stringify({ results: [
  { name: "Lahore", admin1: "Punjab", country: "Pakistan", latitude: 31.558, longitude: 74.35071, timezone: "Asia/Karachi" },
  { name: "Nowhere", latitude: 1, longitude: 1 }, // no zone: dropped
  { name: "Bad", latitude: "x", longitude: 1, timezone: "UTC" }
] }))
assert.deepEqual(geo, [{ name: "Lahore", lat: 31.558, lon: 74.35071, zone: "Asia/Karachi", description: "Punjab, Pakistan" }])
assert.deepEqual(M.parseGeocoding("{}"), [])
assert.deepEqual(M.parseGeocoding("<html>"), [])

assert.deepEqual(M.parseCoordinates("31.52, 74.35"), { name: "31.52, 74.35", lat: 31.52, lon: 74.35, zone: "" })
assert.deepEqual(M.parseCoordinates("-33.9 151.2").lat, -33.9)
assert.equal(M.parseCoordinates("Lahore"), null)
assert.equal(M.parseCoordinates("95, 10"), null)

const tab = M.parseZoneTab("# comment\nPK\t+2452+06703\tAsia/Karachi\nGB,GG\t+513030-0000731\tEurope/London\nXX\tbad\tAsia/Bad\n")
assert.deepEqual(tab.ids, ["Asia/Karachi", "Europe/London"])
assert.ok(Math.abs(tab.coords["Asia/Karachi"].lat - 24.8667) < 0.001)
assert.ok(Math.abs(tab.coords["Europe/London"].lon + 0.1253) < 0.001)
assert.deepEqual(M.zonePlace(tab, "Asia/Karachi").name, "Karachi")
assert.equal(M.zonePlace(tab, "Mars/Base"), null)
// The real table parses and has the common zones.
const realTab = M.parseZoneTab(readFileSync("/usr/share/zoneinfo/zone1970.tab", "utf8"))
assert.ok(realTab.ids.length > 250 && realTab.ids.includes("Asia/Karachi") && realTab.ids.includes("America/New_York"))

const dkm = M.distanceKm({ lat: 31.5204, lon: 74.3587 }, { lat: 33.6844, lon: 73.0479 }) // Lahore-Islamabad
assert.ok(dkm > 260 && dkm < 280, String(dkm))
assert.equal(M.distanceKm(null, { lat: 0, lon: 0 }), Infinity)

// ---- History -----------------------------------------------------------------

const h = M.parseHistory(JSON.stringify({ days: {
  "2026-11-10": { fajr: "jamaat", dhuhr: "late", asr: "alone", isha: "missed", maghrib: "<img src=x>", sunrise: "jamaat" },
  "bad-date": { fajr: "jamaat" }, "2026-11-09": "nope", "2026-11-08": { fajr: "maybe" }
} }))
assert.deepEqual(h, { days: { "2026-11-10": { fajr: "jamaat", dhuhr: "late", asr: "alone", isha: "missed" } } })
assert.deepEqual(M.parseHistory("not json"), { days: {} })
assert.deepEqual(M.parseHistory('{"days":[1,2]}'), { days: {} })
assert.equal(M.statusOf(h, "2026-11-10", "dhuhr"), "late")
assert.equal(M.statusOf(h, "2026-11-01", "asr"), "")
assert.deepEqual(["", "jamaat", "alone", "late", "missed"].map(M.nextStatus), ["jamaat", "alone", "late", "missed", ""])
const h2 = M.withStatus(h, "2026-11-10", "fajr", "")
assert.equal(M.statusOf(h2, "2026-11-10", "fajr"), "")
assert.equal(M.statusOf(h, "2026-11-10", "fajr"), "jamaat") // original untouched
assert.deepEqual(M.withStatus({ days: {} }, "2026-11-01", "isha", ""), { days: {} })

const gd = M.graphDays(noon, karachi, 3, 0)
assert.deepEqual(gd.map((x) => x.key), ["2026-11-08", "2026-11-09", "2026-11-10"])
assert.equal(M.graphDays(noon, karachi, 2, 7)[1].key, "2026-11-03")
assert.equal(M.graphDays(Date.UTC(2026, 10, 9, 23, 30), karachi, 1, 0)[0].key, "2026-11-10")
const counts = M.countStatuses(h, gd)
assert.deepEqual(counts, { jamaat: 1, alone: 1, late: 1, missed: 1 })
assert.equal(M.jamaatShare(counts), 25)
assert.equal(M.jamaatShare({ jamaat: 0, alone: 0, late: 0, missed: 0 }), -1)

// ---- Theme colours -----------------------------------------------------------

assert.equal(M.hueColor("#a6e3a1", 70, 170, "#fb"), "#a6e3a1")
assert.equal(M.hueColor("#FFC107", 70, 170, "#fb"), "#fb")
assert.equal(M.hueColor("#bebebe", 0, 360, "#fb"), "#fb")
assert.equal(M.hueColor("<b>", 0, 360, "#fb"), "#fb")
assert.deepEqual(M.parseThemeColors('green = "#FFC107"\nred = "#D35F5F" # x\nbad = "url(x)"'), { green: "#FFC107", red: "#D35F5F" })
assert.equal(M.validHex(" #00ff00 "), "#00ff00")
assert.equal(M.validHex("red"), "")
console.log("ok")
