.pragma library

// Prayer times calculated locally from the sun's position (the PrayTimes.org
// method), for one place. The Android app (prayer-times-android) ports this
// file and checks itself against its output, so keep the two in step:
// after changing the calculation, regenerate its model_vectors.csv.
//
// Time zones: QML's JavaScript has no Intl, so a zone is a table of UTC
// offsets read from `zdump -i` (see parseZoneDump). A plain number is also
// accepted anywhere a zone is, as a fixed offset in hours.

var DEG = Math.PI / 180
function dsin(d) { return Math.sin(d * DEG) }
function dcos(d) { return Math.cos(d * DEG) }
function dtan(d) { return Math.tan(d * DEG) }
function darcsin(x) { return Math.asin(x) / DEG }
function darccos(x) { return Math.acos(x) / DEG }
function darctan2(y, x) { return Math.atan2(y, x) / DEG }
function darccot(x) { return Math.atan(1 / x) / DEG }
function fix(a, b) { a = a - b * Math.floor(a / b); return a < 0 ? a + b : a }
function fixAngle(a) { return fix(a, 360) }
function fixHour(a) { return fix(a, 24) }

var MINUTE = 60000
var HOUR = 3600000
var DAY = 86400000

// Fajr and Isha twilight angles. Methods with ishaMinutes put Isha a fixed
// time after Maghrib ("Makkah" is Umm al-Qura: 90 minutes, 120 in Ramadan).
var METHODS = {
  Makkah: { fajr: 18.5, ishaMinutes: 90, ramadanIshaMinutes: 120 },
  Karachi: { fajr: 18, isha: 18 },
  MWL: { fajr: 18, isha: 17 },
  ISNA: { fajr: 15, isha: 15 },
  Egypt: { fajr: 19.5, isha: 17.5 },
  Kuwait: { fajr: 18, isha: 17.5 },
  Qatar: { fajr: 18, ishaMinutes: 90, ramadanIshaMinutes: 90 },
  Singapore: { fajr: 20, isha: 18 }
}
var METHOD_NAMES = ["Makkah", "Karachi", "MWL", "ISNA", "Egypt", "Kuwait", "Qatar", "Singapore"]

var PRAYERS = ["fajr", "dhuhr", "asr", "maghrib", "isha"]
var ROWS = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]
var JAMAAT_KEYS = ["fajr", "dhuhr", "asr", "maghrib", "isha", "jumuah"]

function julian(y, m, d) {
  if (m <= 2) { y -= 1; m += 12 }
  var A = Math.floor(y / 100)
  var B = 2 - A + Math.floor(A / 4)
  return Math.floor(365.25 * (y + 4716)) + Math.floor(30.6001 * (m + 1)) + d + B - 1524.5
}

function sunPosition(jd) {
  var D = jd - 2451545.0
  var g = fixAngle(357.529 + 0.98560028 * D)
  var q = fixAngle(280.459 + 0.98564736 * D)
  var L = fixAngle(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g))
  var e = 23.439 - 0.00000036 * D
  var RA = darctan2(dcos(e) * dsin(L), dcos(L)) / 15
  return { decl: darcsin(dsin(e) * dsin(L)), eqt: q / 15 - fixHour(RA) }
}

// Tabular (civil) Hijri date. Umm al-Qura's calendar can differ by a day or
// two, which only moves the Ramadan Isha switch at the month's edges.
function hijri(y, m, d) {
  var jdn = Math.floor(julian(y, m, d) + 0.5)
  var l = jdn - 1948440 + 10632
  var n = Math.floor((l - 1) / 10631)
  l = l - 10631 * n + 354
  var j = Math.floor((10985 - l) / 5316) * Math.floor(50 * l / 17719) + Math.floor(l / 5670) * Math.floor(43 * l / 15238)
  l = l - Math.floor((30 - j) / 15) * Math.floor(17719 * j / 50) - Math.floor(j / 16) * Math.floor(15238 * j / 43) + 29
  var hm = Math.floor(24 * l / 709)
  return { year: 30 * n + j - 30, month: hm, day: l - Math.floor(709 * hm / 24) }
}

// Times for one calendar day at a place, in minutes after that place's local
// midnight (rounded to the minute). Unreachable angles give NaN.
// tz is the UTC offset in hours; opts: { method, asr: "Standard"|"Hanafi" }
function compute(y, m, d, lat, lon, tz, opts) {
  var method = METHODS[opts && opts.method] || METHODS.Makkah
  var asrFactor = opts && opts.asr === "Hanafi" ? 2 : 1
  var jDate = julian(y, m, d) - lon / (15 * 24)

  function midDay(t) { return fixHour(12 - sunPosition(jDate + t).eqt) }
  function angleTime(angle, t, ccw) {
    var decl = sunPosition(jDate + t).decl
    var x = (-dsin(angle) - dsin(decl) * dsin(lat)) / (dcos(decl) * dcos(lat))
    var h = darccos(x) / 15
    return midDay(t) + (ccw ? -h : h)
  }
  function asrTime(t) {
    var decl = sunPosition(jDate + t).decl
    return angleTime(-darccot(asrFactor + dtan(Math.abs(lat - decl))), t, false)
  }

  var h = { fajr: 5, sunrise: 6, dhuhr: 12, asr: 13, sunset: 18, isha: 18 }
  for (var i = 0; i < 2; i++) {
    h = {
      fajr: angleTime(method.fajr, h.fajr / 24, true),
      sunrise: angleTime(0.833, h.sunrise / 24, true),
      dhuhr: midDay(h.dhuhr / 24),
      asr: asrTime(h.asr / 24),
      sunset: angleTime(0.833, h.sunset / 24, false),
      isha: method.isha !== undefined ? angleTime(method.isha, h.isha / 24, false) : h.isha
    }
  }

  var shift = tz - lon / 15
  var out = {}
  out.fajr = h.fajr + shift
  out.sunrise = h.sunrise + shift
  out.dhuhr = h.dhuhr + shift
  out.asr = h.asr + shift
  out.maghrib = h.sunset + shift
  if (method.ishaMinutes !== undefined) {
    var ramadan = hijri(y, m, d).month === 9
    out.isha = out.maghrib + (ramadan ? method.ramadanIshaMinutes : method.ishaMinutes) / 60
  } else {
    out.isha = h.isha + shift
  }
  for (var k in out) out[k] = isFinite(out[k]) ? Math.round(out[k] * 60) : NaN
  return out
}

// ---------------------------------------------------------------------------
// Time zones: { id, base, steps: [{ at, off }] }, offsets in minutes east of
// UTC. `base` holds before the first step.

var ZONE_RE = /^(?:UTC|[A-Za-z][A-Za-z0-9_+-]{0,30}(?:\/[A-Za-z0-9_+-]{1,30}){1,2})$/

function validZoneId(id) { return typeof id === "string" && ZONE_RE.test(id) && id.indexOf("..") < 0 }

function fixedZone(hours, id) { return { id: id || "", base: Math.round(Number(hours) * 60) || 0, steps: [] } }

function asZone(z) {
  if (z && typeof z === "object" && isFinite(z.base) && Array.isArray(z.steps)) return z
  var n = Number(z)
  return fixedZone(isFinite(n) ? n : 0)
}

// "+05", "-0330", "+0545", "+053528" -> minutes (seconds dropped).
function parseOffset(s) {
  var m = /^([+-])(\d{2})(\d{2})?(\d{2})?$/.exec(String(s || ""))
  if (!m) return null
  var v = Number(m[2]) * 60 + Number(m[3] || 0)
  return v > 18 * 60 ? null : (m[1] === "-" ? -v : v)
}

// Output of `zdump -i -c FROM,TO <zone>`: a "-" line with the offset at the
// start of the range, then one line per change: the local date and time it
// takes effect (in the new offset) and the new offset.
function parseZoneDump(text, id) {
  var lines = String(text || "").slice(0, 200000).split("\n")
  var base = null, steps = []
  for (var i = 0; i < lines.length && steps.length < 500; i++) {
    var f = lines[i].split("\t")
    if (f.length < 3) continue
    var off = parseOffset(f[2])
    if (off === null) continue
    if (f[0] === "-") { if (base === null) base = off; continue }
    var d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(f[0])
    var t = /^(\d{2})(\d{2})?(\d{2})?$/.exec(f[1])
    if (!d || !t) continue
    var local = Date.UTC(+d[1], +d[2] - 1, +d[3], +t[1], +(t[2] || 0), +(t[3] || 0))
    steps.push({ at: local - off * MINUTE, off: off })
  }
  if (base === null) {
    if (!steps.length) return null
    base = steps[0].off
  }
  steps.sort(function(a, b) { return a.at - b.at })
  return { id: validZoneId(id) ? id : "", base: base, steps: steps }
}

function offsetAt(zone, ms) {
  var z = asZone(zone), off = z.base
  for (var i = 0; i < z.steps.length; i++) {
    if (ms >= z.steps[i].at) off = z.steps[i].off
    else break
  }
  return off
}

function pad2(n) { return (n < 10 ? "0" : "") + n }
function dateKey(y, m, d) { return y + "-" + pad2(m) + "-" + pad2(d) }

// A calendar date: { y, m, d, weekday (0 = Sunday), key }.
function mkDate(y, m, d) {
  var t = new Date(Date.UTC(y, m - 1, d))
  var Y = t.getUTCFullYear(), M = t.getUTCMonth() + 1, D = t.getUTCDate()
  return { y: Y, m: M, d: D, weekday: t.getUTCDay(), key: dateKey(Y, M, D) }
}
function addDays(date, n) { return mkDate(date.y, date.m, date.d + n) }
function parseDateKey(key) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key || ""))
  return m ? mkDate(+m[1], +m[2], +m[3]) : null
}

// The calendar date at a place for an instant.
function localDate(ms, zone) {
  var t = new Date(ms + offsetAt(zone, ms) * MINUTE)
  return mkDate(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate())
}

// Wall-clock hour and minute of an instant at a place.
function clock(ms, zone) {
  var t = new Date(ms + offsetAt(zone, ms) * MINUTE)
  return { h: t.getUTCHours(), m: t.getUTCMinutes() }
}

// The instant of `minutes` after local midnight on a date. In a DST overlap
// the earlier offset wins; a time in a gap moves forward by the gap.
function wallToMs(date, minutes, zone) {
  var local = Date.UTC(date.y, date.m - 1, date.d) + minutes * MINUTE
  var before = local - offsetAt(zone, local - DAY) * MINUTE
  if (before + offsetAt(zone, before) * MINUTE === local) return before
  var after = local - offsetAt(zone, local + DAY) * MINUTE
  if (after + offsetAt(zone, after) * MINUTE === local) return after
  return before
}

// ---------------------------------------------------------------------------
// The schedule at a place: { name, lat, lon, zone }.

// All six rows of a calendar date: { key, at (epoch ms or NaN), date, weekday }.
function dayRows(date, place, opts) {
  var tzHours = offsetAt(place.zone, wallToMs(date, 720, place.zone)) / 60
  var mins = compute(date.y, date.m, date.d, place.lat, place.lon, tzHours, opts)
  var rows = []
  for (var i = 0; i < ROWS.length; i++) {
    var k = ROWS[i]
    rows.push({ key: k, at: isFinite(mins[k]) ? wallToMs(date, mins[k], place.zone) : NaN, date: date.key, weekday: date.weekday })
  }
  return rows
}

// dayOffset counts days from the place's current date.
function day(ms, place, opts, dayOffset) {
  return dayRows(addDays(localDate(ms, place.zone), dayOffset || 0), place, opts)
}

function prayersOf(rows) { return rows.filter(function(r) { return r.key !== "sunrise" && isFinite(r.at) }) }

// The next prayer after ms, looking ahead past Isha.
function next(ms, place, opts) {
  for (var off = 0; off <= 2; off++) {
    var p = prayersOf(day(ms, place, opts, off))
    for (var i = 0; i < p.length; i++) if (p[i].at > ms) return p[i]
  }
  return null
}

// Every time with a value from yesterday to tomorrow, in order.
function around(ms, place, opts) {
  var out = []
  for (var off = -1; off <= 1; off++)
    out = out.concat(day(ms, place, opts, off).filter(function(r) { return isFinite(r.at) }))
  return out.sort(function(a, b) { return a.at - b.at })
}

// Where now sits between the time that last began (`current`, Sunrise
// included) and the next one (`target`). Until halfway after a prayer the
// counter counts up from it (since); from halfway it counts down to target.
// After Sunrise it counts down to Dhuhr straight away.
function phase(ms, place, opts) {
  var rows = around(ms, place, opts)
  for (var i = 1; i < rows.length; i++) {
    if (rows[i].at > ms) {
      var cur = rows[i - 1], tgt = rows[i]
      var since = cur.key !== "sunrise" && ms < cur.at + (tgt.at - cur.at) / 2
      return { current: cur, target: tgt, since: since, anchor: since ? cur : tgt }
    }
  }
  return null
}

// Signed counter for a phase: + elapsed (floored), − remaining (rounded up).
function counter(ms, ph, withSeconds) {
  if (!ph) return null
  var unit = withSeconds ? 1000 : MINUTE
  var n = ph.since ? Math.floor((ms - ph.current.at) / unit) : Math.ceil((ph.target.at - ms) / unit)
  n = Math.max(0, n)
  var s = withSeconds ? n % 60 : 0
  var mins = withSeconds ? Math.floor(n / 60) : n
  return { sign: ph.since ? "+" : "−", h: Math.floor(mins / 60), m: mins % 60, s: s }
}

// A prayer's time: from start until end (Fajr ends at sunrise, Dhuhr at Asr,
// Asr at Maghrib, Maghrib at Isha, Isha at the middle of the night). `ask`
// is when to ask "did you pray it?": leadMinutes before the end, but never
// before the prayer's halfway point.
function windows(date, place, opts, leadMinutes) {
  var rows = dayRows(date, place, opts)
  var t = {}
  for (var i = 0; i < rows.length; i++) t[rows[i].key] = rows[i].at
  var nextFajr = dayRows(addDays(date, 1), place, opts)[0].at
  var ends = { fajr: t.sunrise, dhuhr: t.asr, asr: t.maghrib, maghrib: t.isha, isha: t.maghrib + (nextFajr - t.maghrib) / 2 }
  var lead = Math.max(0, Number(leadMinutes) || 0) * MINUTE
  var out = []
  for (var j = 0; j < PRAYERS.length; j++) {
    var k = PRAYERS[j], start = t[k], end = ends[k]
    if (!isFinite(start) || !isFinite(end) || end <= start) continue
    out.push({ key: k, date: date.key, weekday: date.weekday, start: start, end: end,
      ask: Math.round(Math.max(end - lead, start + (end - start) / 2)) })
  }
  return out
}

// The prayer whose time ms is in, or the last one that began if between times.
function current(ms, place, opts) {
  var today = localDate(ms, place.zone)
  var all = windows(addDays(today, -1), place, opts, 0).concat(windows(today, place, opts, 0))
  var out = null
  for (var i = 0; i < all.length; i++) if (all[i].start <= ms) out = all[i]
  return out
}

// "Did you pray X?" questions due in (prevMs, nowMs].
function checkIns(prevMs, nowMs, place, opts, leadMinutes, staleMs) {
  var out = []
  if (!(nowMs > prevMs)) return out
  var stale = staleMs || 10 * MINUTE
  var today = localDate(nowMs, place.zone)
  for (var off = -1; off <= 1; off++) {
    var w = windows(addDays(today, off), place, opts, leadMinutes)
    for (var i = 0; i < w.length; i++)
      if (w[i].ask > prevMs && w[i].ask <= nowMs && nowMs - w[i].ask <= stale)
        out.push({ key: w[i].key, date: w[i].date, weekday: w[i].weekday, at: w[i].start, ask: w[i].ask })
  }
  return out
}

// ---------------------------------------------------------------------------
// Masjid jamaat: per prayer (and Jumu'ah) a fixed time "13:30" / "1:30 pm",
// or minutes after the azan "+15". Empty means none.

function parseJamaat(text) {
  var s = String(text === undefined || text === null ? "" : text).trim().toLowerCase()
  if (s === "") return null
  var a = /^\+\s*(\d{1,3})$/.exec(s)
  if (a) return Number(a[1]) <= 180 ? { after: Number(a[1]) } : null
  var t = /^(\d{1,2})[:.](\d{2})\s*(am|pm)?$/.exec(s)
  if (!t) return null
  var h = Number(t[1]), m = Number(t[2])
  if (m > 59) return null
  if (t[3]) {
    if (h < 1 || h > 12) return null
    h = h % 12 + (t[3] === "pm" ? 12 : 0)
  } else if (h > 23) return null
  return { minute: h * 60 + m }
}

function jamaatValid(text) { return String(text || "").trim() === "" || parseJamaat(text) !== null }

// A rule as text: "+15", "13:30", or with hour12 "1:30 pm". "" for none.
function jamaatText(rule, hour12) {
  if (!rule) return ""
  if (rule.after !== undefined) return "+" + rule.after
  var h = Math.floor(rule.minute / 60), m = pad2(rule.minute % 60)
  return hour12 ? ((h % 12) || 12) + ":" + m + (h < 12 ? " am" : " pm") : pad2(h) + ":" + m
}

// { fajr: "13:30", ... } from settings -> { fajr: rule, ... } (invalid dropped).
function jamaatRules(value) {
  var out = {}
  var src = value && typeof value === "object" && !Array.isArray(value) ? value : {}
  for (var i = 0; i < JAMAAT_KEYS.length; i++) {
    var r = parseJamaat(src[JAMAAT_KEYS[i]])
    if (r) out[JAMAAT_KEYS[i]] = r
  }
  return out
}

// Jumu'ah replaces Dhuhr on Fridays when it is set.
function jamaatKey(key, weekday, rules) {
  return key === "dhuhr" && weekday === 5 && rules.jumuah ? "jumuah" : key
}

// Jamaat instant for a prayer row, or NaN. A fixed time earlier than the
// azan (an old setting after the times moved) is not a jamaat to show.
function jamaatAt(row, rules, zone) {
  if (!row || !isFinite(row.at) || row.key === "sunrise") return NaN
  var rule = rules[jamaatKey(row.key, row.weekday, rules)]
  if (!rule) return NaN
  if (rule.after !== undefined) return row.at + rule.after * MINUTE
  var t = wallToMs(parseDateKey(row.date), rule.minute, zone)
  return t >= row.at ? t : NaN
}

// ---------------------------------------------------------------------------
// Events due in (prevMs, nowMs], oldest first:
//   start   a prayer began (azan: whether it rings for it)
//   began   a prayer began while the machine slept; a quiet note, only the
//           latest one, and only while its time hasn't ended
//   jamaat  remind jamaatLead minutes before jamaat; still due after sleep
//           as long as the jamaat hasn't begun
// cfg: { azan: { fajr: true, ... }, rules, jamaatLead, catchUpMs }
function due(prevMs, nowMs, place, opts, cfg) {
  var out = []
  if (!(nowMs > prevMs)) return out
  cfg = cfg || {}
  var azan = cfg.azan || {}
  var rules = cfg.rules || {}
  var lead = Math.max(0, Number(cfg.jamaatLead) || 0) * MINUTE
  var catchUp = cfg.catchUpMs !== undefined ? cfg.catchUpMs : 15 * MINUTE
  var today = localDate(nowMs, place.zone)
  var began = null
  for (var off = -1; off <= 1; off++) {
    var date = addDays(today, off)
    var rows = prayersOf(dayRows(date, place, opts))
    var w = windows(date, place, opts, 0)
    var ends = {}
    for (var k = 0; k < w.length; k++) ends[w[k].key] = w[k].end
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (r.at > prevMs && r.at <= nowMs) {
        if (nowMs - r.at <= catchUp)
          out.push({ kind: "start", key: r.key, at: r.at, date: r.date, weekday: r.weekday, azan: azan[r.key] === true, time: r.at })
        else if (isFinite(ends[r.key]) && nowMs < ends[r.key] && (!began || r.at > began.at))
          began = { kind: "began", key: r.key, at: r.at, date: r.date, weekday: r.weekday, azan: false, time: r.at }
      }
      var j = jamaatAt(r, rules, place.zone)
      if (isFinite(j)) {
        var remind = j - lead
        if (remind > prevMs && remind <= nowMs && nowMs < j)
          out.push({ kind: "jamaat", key: r.key, at: r.at, date: r.date, weekday: r.weekday, jamaat: j, time: remind })
      }
    }
  }
  if (began) out.push(began)
  return out.sort(function(a, b) { return a.time - b.time })
}

// Hijri date of a calendar date, moved by the user's adjustment (-2..2).
function hijriOf(date, offsetDays) {
  var d = addDays(date, Math.max(-2, Math.min(2, Math.round(Number(offsetDays) || 0))))
  return hijri(d.y, d.m, d.d)
}

// ---------------------------------------------------------------------------
// Location. Every source is validated: geo.omarchy.org, the Open-Meteo city
// search, the cache file, settings, and typed coordinates.

var MAX_NAME = 60

function cleanName(v) {
  var s = String(v === undefined || v === null ? "" : v).replace(/[\u0000-\u001f\u007f<>]/g, "").trim()
  return s.slice(0, MAX_NAME)
}

function num(v, lo, hi) {
  var n = typeof v === "string" ? Number(v.trim()) : v
  return typeof n === "number" && v !== "" && isFinite(n) && n >= lo && n <= hi ? n : NaN
}

// { name, lat, lon, zone (id or "") } or null.
function parsePlace(obj) {
  if (!obj || typeof obj !== "object") return null
  var lat = num(obj.lat !== undefined ? obj.lat : obj.latitude, -90, 90)
  var lon = num(obj.lon !== undefined ? obj.lon : obj.longitude, -180, 180)
  var zone = obj.zone !== undefined ? obj.zone : obj.timezone
  if (isNaN(lat) || isNaN(lon)) return null
  return {
    name: cleanName(obj.name) || (lat.toFixed(2) + ", " + lon.toFixed(2)),
    lat: lat, lon: lon,
    zone: validZoneId(zone) ? zone : ""
  }
}

function parsePlaceJson(text) {
  try { return parsePlace(JSON.parse(String(text || "").slice(0, 8192))) } catch (e) { return null }
}

// Open-Meteo geocoding -> [{ name, description, lat, lon, zone }].
function parseGeocoding(text) {
  var data
  try { data = JSON.parse(String(text || "").slice(0, 200000)) } catch (e) { return [] }
  var list = data && Array.isArray(data.results) ? data.results : []
  var out = []
  for (var i = 0; i < list.length && out.length < 8; i++) {
    var r = list[i]
    var p = parsePlace(r)
    if (!p || !p.zone) continue
    p.description = [r.admin1, r.country].filter(function(x) { return typeof x === "string" && x !== "" })
      .map(cleanName).join(", ")
    out.push(p)
  }
  return out
}

// "31.52, 74.35" typed into the search -> a place (zone filled in later).
function parseCoordinates(text) {
  var m = /^\s*(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)\s*$/.exec(String(text || ""))
  return m ? parsePlace({ lat: m[1], lon: m[2], name: "" }) : null
}

// ISO 6709 "+3132+07420" / "+313200+0742000" -> degrees.
function iso6709(s) {
  var m = /^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?$/.exec(s)
  if (!m) return null
  var lat = (+m[2] + +m[3] / 60 + +(m[4] || 0) / 3600) * (m[1] === "-" ? -1 : 1)
  var lon = (+m[6] + +m[7] / 60 + +(m[8] || 0) / 3600) * (m[5] === "-" ? -1 : 1)
  return { lat: lat, lon: lon }
}

// zone1970.tab -> { ids: sorted zone ids, coords: { id: { lat, lon } } }.
function parseZoneTab(text) {
  var lines = String(text || "").slice(0, 400000).split("\n")
  var ids = [], coords = {}
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].charAt(0) === "#") continue
    var f = lines[i].split("\t")
    if (f.length < 3 || !validZoneId(f[2])) continue
    var c = iso6709(f[1])
    if (!c) continue
    ids.push(f[2])
    coords[f[2]] = c
  }
  ids.sort()
  return { ids: ids, coords: coords }
}

// A rough place from the system time zone, used until a lookup answers:
// the zone's reference city ("Asia/Karachi" -> Karachi).
function zonePlace(tab, zoneId) {
  var c = tab && tab.coords ? tab.coords[zoneId] : null
  if (!c) return null
  var parts = zoneId.split("/")
  return { name: cleanName(parts[parts.length - 1].replace(/_/g, " ")), lat: c.lat, lon: c.lon, zone: zoneId, approximate: true }
}

function distanceKm(a, b) {
  if (!a || !b) return Infinity
  var dLat = (b.lat - a.lat) * DEG, dLon = (b.lon - a.lon) * DEG
  var h = Math.pow(Math.sin(dLat / 2), 2) + Math.cos(a.lat * DEG) * Math.cos(b.lat * DEG) * Math.pow(Math.sin(dLon / 2), 2)
  return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(h)))
}

// ---------------------------------------------------------------------------
// Prayer history: { days: { "YYYY-MM-DD": { fajr: "jamaat"|"alone"|"late"|"missed" } } }
// Written only by history.sh; read here and validated, since it is a file on
// disk anyone could have edited.

var STATUSES = ["jamaat", "alone", "late", "missed"]
var MAX_DAYS = 4000
var DATE_RE = /^\d{4}-\d{2}-\d{2}$/

function parseHistory(text) {
  var out = { days: {} }
  var raw
  try { raw = JSON.parse(String(text || "").slice(0, 4000000)) } catch (e) { return out }
  var days = raw && typeof raw === "object" && raw.days && typeof raw.days === "object" ? raw.days : {}
  var keys = Object.keys(days).filter(function(k) { return DATE_RE.test(k) }).sort().reverse().slice(0, MAX_DAYS)
  for (var i = 0; i < keys.length; i++) {
    var src = days[keys[i]]
    if (!src || typeof src !== "object") continue
    var d = {}, any = false
    for (var j = 0; j < PRAYERS.length; j++) {
      var v = src[PRAYERS[j]]
      if (STATUSES.indexOf(v) >= 0) { d[PRAYERS[j]] = v; any = true }
    }
    if (any) out.days[keys[i]] = d
  }
  return out
}

function statusOf(history, date, prayer) {
  var d = history && history.days ? history.days[date] : null
  return d && d[prayer] ? d[prayer] : ""
}

// Click order: not recorded -> jamaat -> alone -> late -> missed -> not recorded.
function nextStatus(s) {
  var i = STATUSES.indexOf(s)
  return i < 0 ? "jamaat" : i === STATUSES.length - 1 ? "" : STATUSES[i + 1]
}

// A copy of history with one entry changed, shown at once before history.sh
// has written the file.
function withStatus(history, date, prayer, status) {
  var out = { days: {} }
  for (var k in history.days) out.days[k] = history.days[k]
  var d = {}
  var cur = out.days[date] || {}
  for (var p in cur) d[p] = cur[p]
  if (status) d[prayer] = status; else delete d[prayer]
  if (Object.keys(d).length) out.days[date] = d; else delete out.days[date]
  return out
}

// `count` days ending `endOffset` days before today at a place, oldest first.
function graphDays(ms, zone, count, endOffset) {
  var today = localDate(ms, zone)
  var out = []
  for (var i = count - 1; i >= 0; i--) out.push(addDays(today, -(i + (endOffset || 0))))
  return out
}

function countStatuses(history, days) {
  var c = { jamaat: 0, alone: 0, late: 0, missed: 0 }
  for (var i = 0; i < days.length; i++) {
    var d = history.days[days[i].key]
    if (!d) continue
    for (var p in d) if (c[d[p]] !== undefined) c[d[p]]++
  }
  return c
}

// Percent of recorded prayers prayed with jamaat, or -1 when none recorded.
function jamaatShare(counts) {
  var all = counts.jamaat + counts.alone + counts.late + counts.missed
  return all ? Math.round(counts.jamaat * 100 / all) : -1
}

// ---------------------------------------------------------------------------
// Theme colours.

// Theme colour if its hue falls in [lo, hi] degrees and it isn't grey,
// otherwise the fallback. Some themes map "green" or "yellow" to other hues.
function hueColor(hex, lo, hi, fallback) {
  var m = /^#?([0-9a-fA-F]{6})$/.exec(String(hex || "").trim())
  if (!m) return fallback
  var n = parseInt(m[1], 16)
  var r = (n >> 16 & 255) / 255, g = (n >> 8 & 255) / 255, b = (n & 255) / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  if (d < 0.15) return fallback
  var h = max === r ? 60 * (((g - b) / d) % 6) : max === g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4)
  if (h < 0) h += 360
  return h >= lo && h <= hi ? "#" + m[1] : fallback
}

// The named colours in a theme's colors.toml (only plain "#rrggbb" values).
function parseThemeColors(text) {
  var out = {}
  var lines = String(text || "").slice(0, 65536).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var mm = /^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})["']?\s*(?:#.*)?$/.exec(lines[i])
    if (mm) out[mm[1]] = mm[2]
  }
  return out
}

function validHex(v) { return /^#[0-9A-Fa-f]{6}$/.test(String(v || "").trim()) ? String(v).trim() : "" }
