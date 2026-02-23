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

// Parse integer from string at given offset
fn parse_int_at(s : String, start : Int, len : Int) -> Int {
  let mut result = 0
  let mut i = start
  while i < start + len {
    result = result * 10 + (s[i].to_int() - 48)
    i = i + 1
  }
  result
}

// Convert ISO timestamp to local YYYYMMDD int
fn ts_to_date(ts : String) -> Int {
  if ts.length() < 19 {
    return 0
  }
  let y = parse_int_at(ts, 0, 4)
  let m = parse_int_at(ts, 5, 2)
  let d = parse_int_at(ts, 8, 2)
  let h = parse_int_at(ts, 11, 2)
  let mi = parse_int_at(ts, 14, 2)
  let sc = parse_int_at(ts, 17, 2)
  utc_to_local_date(y, m, d, h, mi, sc)
}

// Convert YYYYMMDD int to "YYYY-MM-DD" string
fn date_str(d : Int) -> String {
  let y = d / 10000
  let m = (d % 10000) / 100
  let day = d % 100
  let ms = if m < 10 { "0" + m.to_string() } else { m.to_string() }
  let ds = if day < 10 { "0" + day.to_string() } else { day.to_string() }
  y.to_string() + "-" + ms + "-" + ds
}

// Pricing per million tokens: (input, output, cache_create, cache_read)
fn pricing(model : String) -> (Double, Double, Double, Double) {
  if model.contains("opus") {
    (15.0, 75.0, 18.75, 1.5)
  } else if model.contains("sonnet") {
    (3.0, 15.0, 3.75, 0.3)
  } else if model.contains("haiku") {
    (0.8, 4.0, 1.0, 0.08)
  } else {
    (0.0, 0.0, 0.0, 0.0)
  }
}

fn calc_cost(
  model : String, inp : Int, out : Int, cc : Int, cr : Int
) -> Double {
  let (ir, or, ccr, crr) = pricing(model)
  (inp.to_double() * ir + out.to_double() * or + cc.to_double() * ccr + cr.to_double() * crr) /
  1000000.0
}

// JSON extraction helpers
fn jget(j : Json, k : String) -> Json? {
  match j {
    Object(m) => m.get(k)
    _ => None
  }
}

fn jint(j : Json, k : String) -> Int {
  match jget(j, k) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

fn jstr(j : Json, k : String) -> String {
  match jget(j, k) {
    Some(String(s)) => s
    _ => ""
  }
}

// JSON number helpers
fn jnum_int(n : Int) -> Json {
  Json::number(n.to_double(), repr=n.to_string())
}

fn jnum_f64(n : Double) -> Json {
  Json::number(n)
}

// Accumulator types
struct ModelAcc {
  mut inp : Int
  mut out : Int
  mut cc : Int
  mut cr : Int
  mut cost : Double
} derive(Default)

struct DayAcc {
  mut inp : Int
  mut out : Int
  mut cc : Int
  mut cr : Int
  mut cost : Double
  models : Map[String, ModelAcc]
}

fn process_line(
  line : String,
  days : Map[Int, DayAcc],
  since : Int,
  until : Int,
  seen : Map[String, Unit]
) -> Unit {
  let json = try {
    @json.parse(line)
  } catch {
    _ => return
  }
  let ts = jstr(json, "timestamp")
  if ts == "" {
    return
  }
  let message = match jget(json, "message") {
    Some(m) => m
    None => return
  }
  let usage = match jget(message, "usage") {
    Some(u) => u
    None => return
  }
  // Dedup by message.id:requestId (matches ccusage behavior)
  let mid = jstr(message, "id")
  let rid = jstr(json, "requestId")
  if mid != "" || rid != "" {
    let key = mid + ":" + rid
    match seen.get(key) {
      Some(_) => return
      None => seen[key] = ()
    }
  }
  let model = jstr(message, "model")
  if model == "" {
    return
  }
  let inp = jint(usage, "input_tokens")
  let out = jint(usage, "output_tokens")
  let cc = jint(usage, "cache_creation_input_tokens")
  let cr = jint(usage, "cache_read_input_tokens")
  let date = ts_to_date(ts)
  if date == 0 || date < since || date > until {
    return
  }
  let c = calc_cost(model, inp, out, cc, cr)
  let day = match days.get(date) {
    Some(d) => d
    None => {
      let d : DayAcc = {
        inp: 0,
        out: 0,
        cc: 0,
        cr: 0,
        cost: 0.0,
        models: Map::new(),
      }
      days[date] = d
      d
    }
  }
  day.inp = day.inp + inp
  day.out = day.out + out
  day.cc = day.cc + cc
  day.cr = day.cr + cr
  day.cost = day.cost + c
  let ma = match day.models.get(model) {
    Some(a) => a
    None => {
      let a : ModelAcc = { inp: 0, out: 0, cc: 0, cr: 0, cost: 0.0 }
      day.models[model] = a
      a
    }
  }
  ma.inp = ma.inp + inp
  ma.out = ma.out + out
  ma.cc = ma.cc + cc
  ma.cr = ma.cr + cr
  ma.cost = ma.cost + c
}

fn process_file(
  path : String,
  days : Map[Int, DayAcc],
  since : Int,
  until : Int,
  seen : Map[String, Unit]
) -> Unit {
  // Skip files not modified since our date range
  let mtime = c_file_mtime_date(path, path.length())
  if mtime > 0 && mtime < since {
    return
  }
  if c_open_file(path, path.length()) == 0 {
    return
  }
  while c_is_eof() == 0 {
    let line = c_read_line_ffi()
    if line.is_empty() {
      continue
    }
    process_line(line, days, since, until, seen)
  }
}

// Recursively scan directory for .jsonl files
fn scan_dir(
  dir : String,
  days : Map[Int, DayAcc],
  since : Int,
  until : Int,
  seen : Map[String, Unit]
) -> Unit {
  let entries = try {
    @fs.read_dir(dir)
  } catch {
    _ => return
  }
  let mut i = 0
  while i < entries.length() {
    let path = dir + "/" + entries[i]
    let is_dir = try {
      @fs.is_dir(path)
    } catch {
      _ => false
    }
    if is_dir {
      scan_dir(path, days, since, until, seen)
    } else if entries[i].has_suffix(".jsonl") {
      process_file(path, days, since, until, seen)
    }
    i = i + 1
  }
}

fn build_json(days : Map[Int, DayAcc], order : String) -> Json {
  let date_keys : Array[Int] = []
  days.each(fn(k, _v) { date_keys.push(k) })
  date_keys.sort()
  if order == "desc" {
    let mut l = 0
    let mut r = date_keys.length() - 1
    while l < r {
      let t = date_keys[l]
      date_keys[l] = date_keys[r]
      date_keys[r] = t
      l = l + 1
      r = r - 1
    }
  }
  let daily_arr : Array[Json] = []
  let mut t_inp = 0
  let mut t_out = 0
  let mut t_cc = 0
  let mut t_cr = 0
  let mut t_cost = 0.0
  let mut ki = 0
  while ki < date_keys.length() {
    let dk = date_keys[ki]
    let day = match days.get(dk) {
      Some(d) => d
      None => { ki = ki + 1; continue }
    }
    t_inp = t_inp + day.inp
    t_out = t_out + day.out
    t_cc = t_cc + day.cc
    t_cr = t_cr + day.cr
    t_cost = t_cost + day.cost
    let models_used : Array[Json] = []
    let breakdowns : Array[Json] = []
    day.models.each(fn(mn, ma) {
      models_used.push(Json::string(mn))
      let bm : Map[String, Json] = Map::new()
      bm["modelName"] = Json::string(mn)
      bm["inputTokens"] = jnum_int(ma.inp)
      bm["outputTokens"] = jnum_int(ma.out)
      bm["cacheCreationTokens"] = jnum_int(ma.cc)
      bm["cacheReadTokens"] = jnum_int(ma.cr)
      bm["cost"] = jnum_f64(ma.cost)
      breakdowns.push(Json::object(bm))
    })
    let total_tok = day.inp + day.out + day.cc + day.cr
    let dm : Map[String, Json] = Map::new()
    dm["date"] = Json::string(date_str(dk))
    dm["inputTokens"] = jnum_int(day.inp)
    dm["outputTokens"] = jnum_int(day.out)
    dm["cacheCreationTokens"] = jnum_int(day.cc)
    dm["cacheReadTokens"] = jnum_int(day.cr)
    dm["totalTokens"] = jnum_int(total_tok)
    dm["totalCost"] = jnum_f64(day.cost)
    dm["modelsUsed"] = Json::array(models_used)
    dm["modelBreakdowns"] = Json::array(breakdowns)
    daily_arr.push(Json::object(dm))
    ki = ki + 1
  }
  let t_tok = t_inp + t_out + t_cc + t_cr
  let tm : Map[String, Json] = Map::new()
  tm["inputTokens"] = jnum_int(t_inp)
  tm["outputTokens"] = jnum_int(t_out)
  tm["cacheCreationTokens"] = jnum_int(t_cc)
  tm["cacheReadTokens"] = jnum_int(t_cr)
  tm["totalCost"] = jnum_f64(t_cost)
  tm["totalTokens"] = jnum_int(t_tok)
  let root : Map[String, Json] = Map::new()
  root["daily"] = Json::array(daily_arr)
  root["totals"] = Json::object(tm)
  Json::object(root)
}

fn main {
  let args = @sys.get_cli_args()
  let mut since = 0
  let mut until = 99991231
  let mut order = "asc"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--since" && i + 1 < args.length() {
      i = i + 1
      since = parse_int_at(args[i], 0, 8)
    } else if arg == "--until" && i + 1 < args.length() {
      i = i + 1
      until = parse_int_at(args[i], 0, 8)
    } else if arg == "--order" && i + 1 < args.length() {
      i = i + 1
      order = args[i]
    }
    i = i + 1
  }
  let home = match @sys.get_env_var("HOME") {
    Some(h) => h
    None => {
      println("Error: HOME not set")
      @sys.exit(1)
      ""
    }
  }
  let projects_dir = home + "/.claude/projects"
  let days : Map[Int, DayAcc] = Map::new()
  let seen : Map[String, Unit] = Map::new()
  scan_dir(projects_dir, days, since, until, seen)
  let output = build_json(days, order)
  println(output.stringify(indent=2))
}
