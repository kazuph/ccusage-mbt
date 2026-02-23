// C FFI for timezone conversion
extern "C" fn utc_to_local_date(
  year : Int, month : Int, day : Int,
  hour : Int, minute : Int, second : Int
) -> Int = "utc_to_local_date"

// C FFI for streaming line-by-line file reading
#borrow(path)
extern "C" fn c_open_file(path : String, path_len : Int) -> Int = "c_open_file"

extern "C" fn c_read_line_ffi() -> String = "c_read_line_ffi"

extern "C" fn c_is_eof() -> Int = "c_is_eof"

#borrow(path)
extern "C" fn c_file_mtime_date(
  path : String, path_len : Int
) -> Int = "c_file_mtime_date"

extern "C" fn c_day_of_week(yyyymmdd : Int) -> Int = "c_day_of_week"

#borrow(s)
extern "C" fn c_substring(s : String, start : Int, end_ : Int) -> String = "c_substring"

fn parse_int_at(s : String, start : Int, len : Int) -> Int {
  let mut result = 0
  let mut i = start
  while i < start + len {
    result = result * 10 + (s[i].to_int() - 48)
    i = i + 1
  }
  result
}

fn ts_to_date(ts : String) -> Int {
  if ts.length() < 19 { return 0 }
  let y = parse_int_at(ts, 0, 4)
  let m = parse_int_at(ts, 5, 2)
  let d = parse_int_at(ts, 8, 2)
  let h = parse_int_at(ts, 11, 2)
  let mi = parse_int_at(ts, 14, 2)
  let sc = parse_int_at(ts, 17, 2)
  utc_to_local_date(y, m, d, h, mi, sc)
}

fn date_str(d : Int) -> String {
  let y = d / 10000
  let m = (d % 10000) / 100
  let day = d % 100
  let ms = if m < 10 { "0" + m.to_string() } else { m.to_string() }
  let ds = if day < 10 { "0" + day.to_string() } else { day.to_string() }
  y.to_string() + "-" + ms + "-" + ds
}

fn month_str(d : Int) -> String {
  let y = d / 10000
  let m = (d % 10000) / 100
  let ms = if m < 10 { "0" + m.to_string() } else { m.to_string() }
  y.to_string() + "-" + ms
}

fn is_leap_year(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn days_in_month(y : Int, m : Int) -> Int {
  match m {
    1 => 31; 2 => if is_leap_year(y) { 29 } else { 28 }
    3 => 31; 4 => 30; 5 => 31; 6 => 30
    7 => 31; 8 => 31; 9 => 30; 10 => 31; 11 => 30; 12 => 31; _ => 30
  }
}

fn sub_days(d : Int, n : Int) -> Int {
  let mut y = d / 10000
  let mut m = (d % 10000) / 100
  let mut day = d % 100
  let mut remaining = n
  while remaining > 0 {
    if day > remaining {
      day = day - remaining
      remaining = 0
    } else {
      remaining = remaining - day
      m = m - 1
      if m < 1 { m = 12; y = y - 1 }
      day = days_in_month(y, m)
    }
  }
  y * 10000 + m * 100 + day
}

fn week_start(d : Int) -> Int {
  let dow = c_day_of_week(d)
  if dow == 0 { d } else { sub_days(d, dow) }
}

fn pricing(model : String) -> (Double, Double, Double, Double) {
  if model.contains("opus") { (15.0, 75.0, 18.75, 1.5) }
  else if model.contains("sonnet") { (3.0, 15.0, 3.75, 0.3) }
  else if model.contains("haiku") { (0.8, 4.0, 1.0, 0.08) }
  else { (0.0, 0.0, 0.0, 0.0) }
}

fn calc_cost(model : String, inp : Int, out : Int, cc : Int, cr : Int) -> Double {
  let (ir, or, ccr, crr) = pricing(model)
  (inp.to_double() * ir + out.to_double() * or + cc.to_double() * ccr + cr.to_double() * crr) / 1000000.0
}

fn jget(j : Json, k : String) -> Json? {
  match j { Object(m) => m.get(k); _ => None }
}

fn jint(j : Json, k : String) -> Int {
  match jget(j, k) { Some(Number(n, ..)) => n.to_int(); _ => 0 }
}

fn jstr(j : Json, k : String) -> String {
  match jget(j, k) { Some(String(s)) => s; _ => "" }
}

fn jnum_i64(n : Int64) -> Json {
  Json::number(n.to_double(), repr=n.to_string())
}

fn jnum_f64(n : Double) -> Json {
  Json::number(n)
}

// All accumulators use Int64 to avoid overflow on large monthly totals
struct ModelAcc {
  mut inp : Int64
  mut out : Int64
  mut cc : Int64
  mut cr : Int64
  mut cost : Double
}

struct BucketAcc {
  mut inp : Int64
  mut out : Int64
  mut cc : Int64
  mut cr : Int64
  mut cost : Double
  models : Map[String, ModelAcc]
}

fn new_bucket() -> BucketAcc {
  { inp: 0L, out: 0L, cc: 0L, cr: 0L, cost: 0.0, models: Map::new() }
}

fn acc_add(acc : BucketAcc, model : String, inp : Int, out : Int, cc : Int, cr : Int, cost : Double) -> Unit {
  acc.inp = acc.inp + inp.to_int64()
  acc.out = acc.out + out.to_int64()
  acc.cc = acc.cc + cc.to_int64()
  acc.cr = acc.cr + cr.to_int64()
  acc.cost = acc.cost + cost
  let ma = match acc.models.get(model) {
    Some(a) => a
    None => { let a : ModelAcc = { inp: 0L, out: 0L, cc: 0L, cr: 0L, cost: 0.0 }; acc.models[model] = a; a }
  }
  ma.inp = ma.inp + inp.to_int64()
  ma.out = ma.out + out.to_int64()
  ma.cc = ma.cc + cc.to_int64()
  ma.cr = ma.cr + cr.to_int64()
  ma.cost = ma.cost + cost
}

struct SessionAcc {
  mut inp : Int64
  mut out : Int64
  mut cc : Int64
  mut cr : Int64
  mut cost : Double
  models : Map[String, ModelAcc]
  mut last_date : Int
  project_path : String
  session_id : String
}

fn extract_project(path : String, projects_dir : String) -> String {
  let prefix_len = projects_dir.length() + 1
  if path.length() <= prefix_len { return "unknown" }
  let mut i = prefix_len
  while i < path.length() {
    if path[i] == '/' {
      return c_substring(path, prefix_len, i)
    }
    i = i + 1
  }
  "unknown"
}

fn extract_session_key(path : String, projects_dir : String) -> (String, String) {
  let prefix_len = projects_dir.length() + 1
  if path.length() <= prefix_len { return ("unknown", "unknown") }
  // Find all slash positions in relative path
  let slashes : Array[Int] = []
  let mut i = prefix_len
  while i < path.length() {
    if path[i] == '/' { slashes.push(i) }
    i = i + 1
  }
  // segments are: path[prefix_len..slashes[0]], path[slashes[0]+1..slashes[1]], ..., path[slashes[n-1]+1..end]
  let n_seg = slashes.length() + 1
  if n_seg >= 2 {
    // sessionId = second-to-last segment
    let sid_start = if slashes.length() >= 2 { slashes[slashes.length() - 2] + 1 } else { prefix_len }
    let sid_end = slashes[slashes.length() - 1]
    let sid = c_substring(path, sid_start, sid_end)
    // projectPath = everything before sessionId segment
    let pp = if sid_start > prefix_len + 1 {
      c_substring(path, prefix_len, sid_start - 1)
    } else { "Unknown Project" }
    (pp, sid)
  } else { ("Unknown Project", "unknown") }
}

fn process_line(line : String, since : Int, until : Int, seen : Map[String, Unit]) -> (String, Int, Int, Int, Int, Int, String)? {
  let json = try { @json.parse(line) } catch { _ => return None }
  let ts = jstr(json, "timestamp")
  if ts == "" { return None }
  let message = match jget(json, "message") { Some(m) => m; None => return None }
  let usage = match jget(message, "usage") { Some(u) => u; None => return None }
  let mid = jstr(message, "id")
  let rid = jstr(json, "requestId")
  if mid != "" || rid != "" {
    let key = mid + ":" + rid
    match seen.get(key) { Some(_) => return None; None => seen[key] = () }
  }
  let model = jstr(message, "model")
  if model == "" { return None }
  let inp = jint(usage, "input_tokens")
  let out = jint(usage, "output_tokens")
  let cc = jint(usage, "cache_creation_input_tokens")
  let cr = jint(usage, "cache_read_input_tokens")
  let date = ts_to_date(ts)
  if date == 0 || date < since || date > until { return None }
  Some((model, date, inp, out, cc, cr, ts))
}

fn process_file_daily(path : String, buckets : Map[Int, BucketAcc], since : Int, until : Int, seen : Map[String, Unit]) -> Unit {
  let mtime = c_file_mtime_date(path, path.length())
  if mtime > 0 && mtime < since { return }
  if c_open_file(path, path.length()) == 0 { return }
  while c_is_eof() == 0 {
    let line = c_read_line_ffi()
    if line.is_empty() { continue }
    match process_line(line, since, until, seen) {
      Some((model, date, inp, out, cc, cr, _ts)) => {
        let cost = calc_cost(model, inp, out, cc, cr)
        let bucket = match buckets.get(date) { Some(b) => b; None => { let b = new_bucket(); buckets[date] = b; b } }
        acc_add(bucket, model, inp, out, cc, cr, cost)
      }
      None => ()
    }
  }
}

fn process_file_monthly(path : String, buckets : Map[String, BucketAcc], since : Int, until : Int, seen : Map[String, Unit]) -> Unit {
  let mtime = c_file_mtime_date(path, path.length())
  if mtime > 0 && mtime < since { return }
  if c_open_file(path, path.length()) == 0 { return }
  while c_is_eof() == 0 {
    let line = c_read_line_ffi()
    if line.is_empty() { continue }
    match process_line(line, since, until, seen) {
      Some((model, date, inp, out, cc, cr, _ts)) => {
        let cost = calc_cost(model, inp, out, cc, cr)
        let key = month_str(date)
        let bucket = match buckets.get(key) { Some(b) => b; None => { let b = new_bucket(); buckets[key] = b; b } }
        acc_add(bucket, model, inp, out, cc, cr, cost)
      }
      None => ()
    }
  }
}

fn process_file_weekly(path : String, buckets : Map[String, BucketAcc], since : Int, until : Int, seen : Map[String, Unit]) -> Unit {
  let mtime = c_file_mtime_date(path, path.length())
  if mtime > 0 && mtime < since { return }
  if c_open_file(path, path.length()) == 0 { return }
  while c_is_eof() == 0 {
    let line = c_read_line_ffi()
    if line.is_empty() { continue }
    match process_line(line, since, until, seen) {
      Some((model, date, inp, out, cc, cr, _ts)) => {
        let cost = calc_cost(model, inp, out, cc, cr)
        let ws = week_start(date)
        let key = date_str(ws)
        let bucket = match buckets.get(key) { Some(b) => b; None => { let b = new_bucket(); buckets[key] = b; b } }
        acc_add(bucket, model, inp, out, cc, cr, cost)
      }
      None => ()
    }
  }
}

// process_line variant without date filtering (for session mode)
fn process_line_nodate(line : String, seen : Map[String, Unit]) -> (String, Int, Int, Int, Int, Int, String)? {
  let json = try { @json.parse(line) } catch { _ => return None }
  let ts = jstr(json, "timestamp")
  if ts == "" { return None }
  let message = match jget(json, "message") { Some(m) => m; None => return None }
  let usage = match jget(message, "usage") { Some(u) => u; None => return None }
  let mid = jstr(message, "id")
  let rid = jstr(json, "requestId")
  if mid != "" || rid != "" {
    let key = mid + ":" + rid
    match seen.get(key) { Some(_) => return None; None => seen[key] = () }
  }
  let model = jstr(message, "model")
  if model == "" { return None }
  let inp = jint(usage, "input_tokens")
  let out = jint(usage, "output_tokens")
  let cc = jint(usage, "cache_creation_input_tokens")
  let cr = jint(usage, "cache_read_input_tokens")
  let date = ts_to_date(ts)
  Some((model, date, inp, out, cc, cr, ts))
}

fn process_file_session(path : String, sessions : Map[String, SessionAcc], projects_dir : String, _since : Int, _until : Int, seen : Map[String, Unit]) -> Unit {
  // No mtime skip for session mode — we need lifetime totals
  let (project_path, session_id) = extract_session_key(path, projects_dir)
  let session_key = project_path + "/" + session_id
  if c_open_file(path, path.length()) == 0 { return }
  while c_is_eof() == 0 {
    let line = c_read_line_ffi()
    if line.is_empty() { continue }
    match process_line_nodate(line, seen) {
      Some((model, date, inp, out, cc, cr, _ts)) => {
        let cost = calc_cost(model, inp, out, cc, cr)
        let sess = match sessions.get(session_key) {
          Some(s) => s
          None => {
            let s : SessionAcc = { inp: 0L, out: 0L, cc: 0L, cr: 0L, cost: 0.0, models: Map::new(), last_date: 0, project_path, session_id }
            sessions[session_key] = s; s
          }
        }
        sess.inp = sess.inp + inp.to_int64()
        sess.out = sess.out + out.to_int64()
        sess.cc = sess.cc + cc.to_int64()
        sess.cr = sess.cr + cr.to_int64()
        sess.cost = sess.cost + cost
        if date > sess.last_date { sess.last_date = date }
        let ma = match sess.models.get(model) {
          Some(a) => a
          None => { let a : ModelAcc = { inp: 0L, out: 0L, cc: 0L, cr: 0L, cost: 0.0 }; sess.models[model] = a; a }
        }
        ma.inp = ma.inp + inp.to_int64()
        ma.out = ma.out + out.to_int64()
        ma.cc = ma.cc + cc.to_int64()
        ma.cr = ma.cr + cr.to_int64()
        ma.cost = ma.cost + cost
      }
      None => ()
    }
  }
}

fn process_file_instances(path : String, project_days : Map[String, Map[Int, BucketAcc]], projects_dir : String, since : Int, until : Int, seen : Map[String, Unit]) -> Unit {
  let mtime = c_file_mtime_date(path, path.length())
  if mtime > 0 && mtime < since { return }
  let project = extract_project(path, projects_dir)
  if c_open_file(path, path.length()) == 0 { return }
  while c_is_eof() == 0 {
    let line = c_read_line_ffi()
    if line.is_empty() { continue }
    match process_line(line, since, until, seen) {
      Some((model, date, inp, out, cc, cr, _ts)) => {
        let cost = calc_cost(model, inp, out, cc, cr)
        let days = match project_days.get(project) { Some(d) => d; None => { let d : Map[Int, BucketAcc] = Map::new(); project_days[project] = d; d } }
        let bucket = match days.get(date) { Some(b) => b; None => { let b = new_bucket(); days[date] = b; b } }
        acc_add(bucket, model, inp, out, cc, cr, cost)
      }
      None => ()
    }
  }
}

fn scan_dir_generic(dir : String, projects_dir : String, project_filter : String, handler : (String) -> Unit) -> Unit {
  let entries = try { @fs.read_dir(dir) } catch { _ => return }
  let mut i = 0
  while i < entries.length() {
    let path = dir + "/" + entries[i]
    let is_dir = try { @fs.is_dir(path) } catch { _ => false }
    if is_dir {
      scan_dir_generic(path, projects_dir, project_filter, handler)
    } else if entries[i].has_suffix(".jsonl") {
      if project_filter != "" {
        let proj = extract_project(path, projects_dir)
        if proj != project_filter { i = i + 1; continue }
      }
      handler(path)
    }
    i = i + 1
  }
}

fn build_breakdowns_json(models : Map[String, ModelAcc]) -> (Array[Json], Array[Json]) {
  let models_used : Array[Json] = []
  let breakdowns : Array[Json] = []
  models.each(fn(mn, ma) {
    models_used.push(Json::string(mn))
    let bm : Map[String, Json] = Map::new()
    bm["modelName"] = Json::string(mn)
    bm["inputTokens"] = jnum_i64(ma.inp)
    bm["outputTokens"] = jnum_i64(ma.out)
    bm["cacheCreationTokens"] = jnum_i64(ma.cc)
    bm["cacheReadTokens"] = jnum_i64(ma.cr)
    bm["cost"] = jnum_f64(ma.cost)
    breakdowns.push(Json::object(bm))
  })
  (models_used, breakdowns)
}

fn build_totals_json(t_inp : Int64, t_out : Int64, t_cc : Int64, t_cr : Int64, t_cost : Double) -> Json {
  let t_tok = t_inp + t_out + t_cc + t_cr
  let tm : Map[String, Json] = Map::new()
  tm["inputTokens"] = jnum_i64(t_inp)
  tm["outputTokens"] = jnum_i64(t_out)
  tm["cacheCreationTokens"] = jnum_i64(t_cc)
  tm["cacheReadTokens"] = jnum_i64(t_cr)
  tm["totalCost"] = jnum_f64(t_cost)
  tm["totalTokens"] = jnum_i64(t_tok)
  Json::object(tm)
}

fn sorted_int_keys(m : Map[Int, BucketAcc], order : String) -> Array[Int] {
  let keys : Array[Int] = []
  m.each(fn(k, _v) { keys.push(k) })
  keys.sort()
  if order == "desc" {
    let mut l = 0; let mut r = keys.length() - 1
    while l < r { let t = keys[l]; keys[l] = keys[r]; keys[r] = t; l = l + 1; r = r - 1 }
  }
  keys
}

fn sorted_str_keys(m : Map[String, BucketAcc], order : String) -> Array[String] {
  let keys : Array[String] = []
  m.each(fn(k, _v) { keys.push(k) })
  keys.sort()
  if order == "desc" {
    let mut l = 0; let mut r = keys.length() - 1
    while l < r { let t = keys[l]; keys[l] = keys[r]; keys[r] = t; l = l + 1; r = r - 1 }
  }
  keys
}

fn build_bucket_entry(label_key : String, label_val : String, b : BucketAcc) -> Json {
  let (models_used, breakdowns) = build_breakdowns_json(b.models)
  let total_tok = b.inp + b.out + b.cc + b.cr
  let dm : Map[String, Json] = Map::new()
  dm[label_key] = Json::string(label_val)
  dm["inputTokens"] = jnum_i64(b.inp)
  dm["outputTokens"] = jnum_i64(b.out)
  dm["cacheCreationTokens"] = jnum_i64(b.cc)
  dm["cacheReadTokens"] = jnum_i64(b.cr)
  dm["totalTokens"] = jnum_i64(total_tok)
  dm["totalCost"] = jnum_f64(b.cost)
  dm["modelsUsed"] = Json::array(models_used)
  dm["modelBreakdowns"] = Json::array(breakdowns)
  Json::object(dm)
}

fn build_daily_json(buckets : Map[Int, BucketAcc], order : String) -> Json {
  let keys = sorted_int_keys(buckets, order)
  let arr : Array[Json] = []
  let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
  let mut ki = 0
  while ki < keys.length() {
    let dk = keys[ki]
    let day = match buckets.get(dk) { Some(d) => d; None => { ki = ki + 1; continue } }
    t_inp = t_inp + day.inp; t_out = t_out + day.out; t_cc = t_cc + day.cc; t_cr = t_cr + day.cr; t_cost = t_cost + day.cost
    arr.push(build_bucket_entry("date", date_str(dk), day))
    ki = ki + 1
  }
  let root : Map[String, Json] = Map::new()
  root["daily"] = Json::array(arr)
  root["totals"] = build_totals_json(t_inp, t_out, t_cc, t_cr, t_cost)
  Json::object(root)
}

fn build_monthly_json(buckets : Map[String, BucketAcc], order : String) -> Json {
  let keys = sorted_str_keys(buckets, order)
  let arr : Array[Json] = []
  let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
  let mut ki = 0
  while ki < keys.length() {
    let mk = keys[ki]
    let b = match buckets.get(mk) { Some(d) => d; None => { ki = ki + 1; continue } }
    t_inp = t_inp + b.inp; t_out = t_out + b.out; t_cc = t_cc + b.cc; t_cr = t_cr + b.cr; t_cost = t_cost + b.cost
    arr.push(build_bucket_entry("month", mk, b))
    ki = ki + 1
  }
  let root : Map[String, Json] = Map::new()
  root["monthly"] = Json::array(arr)
  root["totals"] = build_totals_json(t_inp, t_out, t_cc, t_cr, t_cost)
  Json::object(root)
}

fn build_weekly_json(buckets : Map[String, BucketAcc], order : String) -> Json {
  let keys = sorted_str_keys(buckets, order)
  let arr : Array[Json] = []
  let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
  let mut ki = 0
  while ki < keys.length() {
    let wk = keys[ki]
    let b = match buckets.get(wk) { Some(d) => d; None => { ki = ki + 1; continue } }
    t_inp = t_inp + b.inp; t_out = t_out + b.out; t_cc = t_cc + b.cc; t_cr = t_cr + b.cr; t_cost = t_cost + b.cost
    arr.push(build_bucket_entry("week", wk, b))
    ki = ki + 1
  }
  let root : Map[String, Json] = Map::new()
  root["weekly"] = Json::array(arr)
  root["totals"] = build_totals_json(t_inp, t_out, t_cc, t_cr, t_cost)
  Json::object(root)
}

fn build_session_json(sessions : Map[String, SessionAcc], order : String, since : Int, until : Int) -> Json {
  let entries : Array[(String, SessionAcc)] = []
  // ccusage filters sessions by lastActivity (latest entry date) being in [since, until]
  sessions.each(fn(k, v) { if v.last_date >= since && v.last_date <= until { entries.push((k, v)) } })
  entries.sort_by(fn(a, b) {
    let (_, sa) = a; let (_, sb) = b
    if sa.last_date < sb.last_date { -1 } else if sa.last_date > sb.last_date { 1 } else { 0 }
  })
  if order == "desc" {
    let mut l = 0; let mut r = entries.length() - 1
    while l < r { let t = entries[l]; entries[l] = entries[r]; entries[r] = t; l = l + 1; r = r - 1 }
  }
  let arr : Array[Json] = []
  let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
  let mut ki = 0
  while ki < entries.length() {
    let (_key, sess) = entries[ki]
    t_inp = t_inp + sess.inp; t_out = t_out + sess.out; t_cc = t_cc + sess.cc; t_cr = t_cr + sess.cr; t_cost = t_cost + sess.cost
    let (models_used, breakdowns) = build_breakdowns_json(sess.models)
    let total_tok = sess.inp + sess.out + sess.cc + sess.cr
    let dm : Map[String, Json] = Map::new()
    dm["sessionId"] = Json::string(sess.session_id)
    dm["inputTokens"] = jnum_i64(sess.inp)
    dm["outputTokens"] = jnum_i64(sess.out)
    dm["cacheCreationTokens"] = jnum_i64(sess.cc)
    dm["cacheReadTokens"] = jnum_i64(sess.cr)
    dm["totalTokens"] = jnum_i64(total_tok)
    dm["totalCost"] = jnum_f64(sess.cost)
    dm["lastActivity"] = Json::string(date_str(sess.last_date))
    dm["modelsUsed"] = Json::array(models_used)
    dm["modelBreakdowns"] = Json::array(breakdowns)
    dm["projectPath"] = Json::string(sess.project_path)
    arr.push(Json::object(dm))
    ki = ki + 1
  }
  let root : Map[String, Json] = Map::new()
  root["sessions"] = Json::array(arr)
  root["totals"] = build_totals_json(t_inp, t_out, t_cc, t_cr, t_cost)
  Json::object(root)
}

fn build_instances_json(project_days : Map[String, Map[Int, BucketAcc]], order : String) -> Json {
  let projects_json : Map[String, Json] = Map::new()
  let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
  project_days.each(fn(proj, days) {
    let keys = sorted_int_keys(days, order)
    let arr : Array[Json] = []
    let mut ki = 0
    while ki < keys.length() {
      let dk = keys[ki]
      let day = match days.get(dk) { Some(d) => d; None => { ki = ki + 1; continue } }
      t_inp = t_inp + day.inp; t_out = t_out + day.out; t_cc = t_cc + day.cc; t_cr = t_cr + day.cr; t_cost = t_cost + day.cost
      arr.push(build_bucket_entry("date", date_str(dk), day))
      ki = ki + 1
    }
    projects_json[proj] = Json::array(arr)
  })
  let root : Map[String, Json] = Map::new()
  root["projects"] = Json::object(projects_json)
  root["totals"] = build_totals_json(t_inp, t_out, t_cc, t_cr, t_cost)
  Json::object(root)
}

// Number formatting with commas (for Int64)
fn fmt_i64(n : Int64) -> String {
  let s = n.to_string()
  let len = s.length()
  if len <= 3 { return s }
  let first_group = len % 3
  let mut result = ""
  let mut i = 0
  if first_group == 0 {
    result = c_substring(s, 0, 3)
    i = 3
  } else {
    result = c_substring(s, 0, first_group)
    i = first_group
  }
  while i < len {
    result = result + "," + c_substring(s, i, i + 3)
    i = i + 3
  }
  result
}

fn lpad(s : String, w : Int) -> String {
  let mut result = ""
  let mut i = s.length()
  while i < w { result = result + " "; i = i + 1 }
  result + s
}

fn fmt_cost(c : Double) -> String {
  let cents = (c * 100.0 + 0.5).to_int()
  let dollars = cents / 100
  let rem = cents % 100
  let rs = if rem < 10 { "0" + rem.to_string() } else { rem.to_string() }
  "$" + dollars.to_string() + "." + rs
}

fn print_table_header() -> Unit {
  println(lpad("Date", 12) + " | " + lpad("Input", 12) + " | " + lpad("Output", 12) + " | " + lpad("Cache Create", 14) + " | " + lpad("Cache Read", 14) + " | " + lpad("Total Tokens", 14) + " | " + lpad("Cost", 12))
  println("-------------+--------------+--------------+----------------+----------------+----------------+--------------")
}

fn print_bucket_row(label : String, b : BucketAcc) -> Unit {
  let total_tok = b.inp + b.out + b.cc + b.cr
  println(lpad(label, 12) + " | " + lpad(fmt_i64(b.inp), 12) + " | " + lpad(fmt_i64(b.out), 12) + " | " + lpad(fmt_i64(b.cc), 14) + " | " + lpad(fmt_i64(b.cr), 14) + " | " + lpad(fmt_i64(total_tok), 14) + " | " + lpad(fmt_cost(b.cost), 12))
}

fn print_model_row(mn : String, ma : ModelAcc) -> Unit {
  let mtok = ma.inp + ma.out + ma.cc + ma.cr
  println(lpad("  " + mn, 12) + " | " + lpad(fmt_i64(ma.inp), 12) + " | " + lpad(fmt_i64(ma.out), 12) + " | " + lpad(fmt_i64(ma.cc), 14) + " | " + lpad(fmt_i64(ma.cr), 14) + " | " + lpad(fmt_i64(mtok), 14) + " | " + lpad(fmt_cost(ma.cost), 12))
}

fn print_totals_row(t_inp : Int64, t_out : Int64, t_cc : Int64, t_cr : Int64, t_cost : Double) -> Unit {
  let t_tok = t_inp + t_out + t_cc + t_cr
  println("-------------+--------------+--------------+----------------+----------------+----------------+--------------")
  println(lpad("Total", 12) + " | " + lpad(fmt_i64(t_inp), 12) + " | " + lpad(fmt_i64(t_out), 12) + " | " + lpad(fmt_i64(t_cc), 14) + " | " + lpad(fmt_i64(t_cr), 14) + " | " + lpad(fmt_i64(t_tok), 14) + " | " + lpad(fmt_cost(t_cost), 12))
}

fn main {
  let args = @sys.get_cli_args()
  let mut since = 0
  let mut until = 99991231
  let mut order = "asc"
  let mut subcmd = "daily"
  let mut json_mode = false
  let mut project_filter = ""
  let mut instances = false
  let mut breakdown = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--since" && i + 1 < args.length() { i = i + 1; since = parse_int_at(args[i], 0, 8) }
    else if arg == "--until" && i + 1 < args.length() { i = i + 1; until = parse_int_at(args[i], 0, 8) }
    else if arg == "--order" && i + 1 < args.length() { i = i + 1; order = args[i] }
    else if arg == "--json" { json_mode = true }
    else if arg == "--project" && i + 1 < args.length() { i = i + 1; project_filter = args[i] }
    else if arg == "--instances" || arg == "-i" { instances = true }
    else if arg == "--breakdown" || arg == "-b" { breakdown = true }
    else if arg[0] != '-' { subcmd = arg }
    i = i + 1
  }
  let home = match @sys.get_env_var("HOME") { Some(h) => h; None => { println("Error: HOME not set"); @sys.exit(1); "" } }
  let projects_dir = home + "/.claude/projects"
  let seen : Map[String, Unit] = Map::new()
  if subcmd == "daily" {
    if instances {
      let project_days : Map[String, Map[Int, BucketAcc]] = Map::new()
      scan_dir_generic(projects_dir, projects_dir, project_filter, fn(path) { process_file_instances(path, project_days, projects_dir, since, until, seen) })
      if json_mode { println(build_instances_json(project_days, order).stringify(indent=2)) }
      else {
        project_days.each(fn(proj, days) {
          println("Project: " + proj); print_table_header()
          let keys = sorted_int_keys(days, order)
          let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
          let mut ki = 0
          while ki < keys.length() {
            let dk = keys[ki]
            let day = match days.get(dk) { Some(d) => d; None => { ki = ki + 1; continue } }
            t_inp = t_inp + day.inp; t_out = t_out + day.out; t_cc = t_cc + day.cc; t_cr = t_cr + day.cr; t_cost = t_cost + day.cost
            print_bucket_row(date_str(dk), day)
            if breakdown { day.models.each(fn(mn, ma) { print_model_row(mn, ma) }) }
            ki = ki + 1
          }
          print_totals_row(t_inp, t_out, t_cc, t_cr, t_cost); println("")
        })
      }
    } else {
      let buckets : Map[Int, BucketAcc] = Map::new()
      scan_dir_generic(projects_dir, projects_dir, project_filter, fn(path) { process_file_daily(path, buckets, since, until, seen) })
      if json_mode { println(build_daily_json(buckets, order).stringify(indent=2)) }
      else {
        print_table_header()
        let keys = sorted_int_keys(buckets, order)
        let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
        let mut ki = 0
        while ki < keys.length() {
          let dk = keys[ki]
          let day = match buckets.get(dk) { Some(d) => d; None => { ki = ki + 1; continue } }
          t_inp = t_inp + day.inp; t_out = t_out + day.out; t_cc = t_cc + day.cc; t_cr = t_cr + day.cr; t_cost = t_cost + day.cost
          print_bucket_row(date_str(dk), day)
          if breakdown { day.models.each(fn(mn, ma) { print_model_row(mn, ma) }) }
          ki = ki + 1
        }
        print_totals_row(t_inp, t_out, t_cc, t_cr, t_cost)
      }
    }
  } else if subcmd == "monthly" {
    let buckets : Map[String, BucketAcc] = Map::new()
    scan_dir_generic(projects_dir, projects_dir, project_filter, fn(path) { process_file_monthly(path, buckets, since, until, seen) })
    if json_mode { println(build_monthly_json(buckets, order).stringify(indent=2)) }
    else {
      print_table_header()
      let keys = sorted_str_keys(buckets, order)
      let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
      let mut ki = 0
      while ki < keys.length() {
        let mk = keys[ki]
        let b = match buckets.get(mk) { Some(d) => d; None => { ki = ki + 1; continue } }
        t_inp = t_inp + b.inp; t_out = t_out + b.out; t_cc = t_cc + b.cc; t_cr = t_cr + b.cr; t_cost = t_cost + b.cost
        print_bucket_row(mk, b)
        if breakdown { b.models.each(fn(mn, ma) { print_model_row(mn, ma) }) }
        ki = ki + 1
      }
      print_totals_row(t_inp, t_out, t_cc, t_cr, t_cost)
    }
  } else if subcmd == "weekly" {
    let buckets : Map[String, BucketAcc] = Map::new()
    scan_dir_generic(projects_dir, projects_dir, project_filter, fn(path) { process_file_weekly(path, buckets, since, until, seen) })
    if json_mode { println(build_weekly_json(buckets, order).stringify(indent=2)) }
    else {
      print_table_header()
      let keys = sorted_str_keys(buckets, order)
      let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
      let mut ki = 0
      while ki < keys.length() {
        let wk = keys[ki]
        let b = match buckets.get(wk) { Some(d) => d; None => { ki = ki + 1; continue } }
        t_inp = t_inp + b.inp; t_out = t_out + b.out; t_cc = t_cc + b.cc; t_cr = t_cr + b.cr; t_cost = t_cost + b.cost
        print_bucket_row(wk, b)
        if breakdown { b.models.each(fn(mn, ma) { print_model_row(mn, ma) }) }
        ki = ki + 1
      }
      print_totals_row(t_inp, t_out, t_cc, t_cr, t_cost)
    }
  } else if subcmd == "session" {
    let sessions : Map[String, SessionAcc] = Map::new()
    scan_dir_generic(projects_dir, projects_dir, project_filter, fn(path) { process_file_session(path, sessions, projects_dir, since, until, seen) })
    if json_mode { println(build_session_json(sessions, order, since, until).stringify(indent=2)) }
    else {
      println(lpad("Session", 30) + " | " + lpad("Project", 30) + " | " + lpad("Last Activity", 14) + " | " + lpad("Total Tokens", 14) + " | " + lpad("Cost", 12))
      sessions.each(fn(_k, sess) {
        if sess.last_date >= since && sess.last_date <= until {
          let total_tok = sess.inp + sess.out + sess.cc + sess.cr
          println(lpad(sess.session_id, 30) + " | " + lpad(sess.project_path, 30) + " | " + lpad(date_str(sess.last_date), 14) + " | " + lpad(fmt_i64(total_tok), 14) + " | " + lpad(fmt_cost(sess.cost), 12))
        }
      })
    }
  } else if subcmd == "blocks" {
    let buckets : Map[Int, BucketAcc] = Map::new()
    scan_dir_generic(projects_dir, projects_dir, project_filter, fn(path) { process_file_daily(path, buckets, since, until, seen) })
    if json_mode { println(build_daily_json(buckets, order).stringify(indent=2)) }
    else {
      print_table_header()
      let keys = sorted_int_keys(buckets, order)
      let mut t_inp = 0L; let mut t_out = 0L; let mut t_cc = 0L; let mut t_cr = 0L; let mut t_cost = 0.0
      let mut ki = 0
      while ki < keys.length() {
        let dk = keys[ki]
        let day = match buckets.get(dk) { Some(d) => d; None => { ki = ki + 1; continue } }
        t_inp = t_inp + day.inp; t_out = t_out + day.out; t_cc = t_cc + day.cc; t_cr = t_cr + day.cr; t_cost = t_cost + day.cost
        print_bucket_row(date_str(dk), day)
        ki = ki + 1
      }
      print_totals_row(t_inp, t_out, t_cc, t_cr, t_cost)
    }
  } else {
    println("Unknown subcommand: " + subcmd)
    println("Usage: ccusage-mbt [daily|monthly|weekly|session|blocks] [options]")
    @sys.exit(1)
  }
}
