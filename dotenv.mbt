///|
/// A small `.env` reader, following the same rules as python-dotenv, which the
/// reference implementation uses.
///
/// Supported: blank lines, `#` comments, an optional `export` prefix,
/// `KEY=VALUE` and bare `KEY`, single-quoted (literal) and double-quoted
/// (escape-aware) values, inline comments after unquoted values, and `$VAR` /
/// `${VAR}` expansion against the variables seen so far.

///|
/// Parse `.env` text. Later definitions override earlier ones; expansion sees
/// the accumulated map.
pub fn parse_dotenv(text : String) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for raw_line in text.split("\n") {
    let line = strip_dotenv_line(raw_line.to_owned())
    if line.length() == 0 {
      continue
    }
    let (key, value) = match line.split_once("=") {
      Some(pair) => (pair.0.to_owned(), pair.1.to_owned())
      None => (line, "")
    }
    let key = key.trim().to_owned()
    if key.length() == 0 {
      continue
    }
    out[key] = expand_dotenv_value(unquote_dotenv_value(value), out)
  }
  out
}

///|
/// Read and parse a `.env` file, returning an empty map when it does not exist.
pub fn dotenv_to_dict(path : String) -> Map[String, String] {
  if !@fs.path_exists(path) {
    return Map([])
  }
  let text = @fs.read_file_to_string(path) catch { _ => return Map([]) }
  parse_dotenv(text)
}

///|
/// Trim a raw line: drop leading whitespace, an `export ` prefix, trailing
/// whitespace, and a trailing comment that is outside quotes.
fn strip_dotenv_line(raw : String) -> String {
  let mut line = raw.trim_start(chars=" \t").to_owned()
  if line.has_prefix("export ") {
    line = line[7:].to_owned()
  } else if line.has_prefix("export\t") {
    line = line[7:].to_owned()
  }
  line = strip_inline_comment(line).trim_end(chars=" \t").to_owned()
  line
}

///|
/// Drop a ` # comment` tail, unless it is inside quotes.
fn strip_inline_comment(line : String) -> String {
  let chars = line.to_array()
  let mut in_single = false
  let mut in_double = false
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\'' && !in_double {
      in_single = !in_single
    } else if c == '"' && !in_single {
      in_double = !in_double
    } else if c == '#' && !in_single && !in_double {
      if i == 0 || chars[i - 1] == ' ' || chars[i - 1] == '\t' {
        return line[:i].to_owned()
      }
    }
    i += 1
  }
  line
}

///|
/// Remove surrounding quotes from a value, honouring backslash escapes inside
/// double quotes.
fn unquote_dotenv_value(raw : String) -> String {
  let value = raw.trim_start(chars=" \t").to_owned()
  if value.length() >= 2 && value[0] == '"' && value[value.length() - 1] == '"' {
    let inner = value[1:value.length() - 1].to_owned()
    return unescape_double(inner)
  }
  if value.length() >= 2 &&
    value[0] == '\'' &&
    value[value.length() - 1] == '\'' {
    return value[1:value.length() - 1].to_owned()
  }
  value.trim_end(chars=" \t").to_owned()
}

///|
/// Resolve `\n`, `\t`, `\"`, `\\` and `\$` inside a double-quoted value.
fn unescape_double(s : String) -> String {
  let out = StringBuilder(size_hint=s.length())
  let chars = s.to_array()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '\\' && i + 1 < chars.length() {
      let n = chars[i + 1]
      match n {
        'n' => out.write_char('\n')
        'r' => out.write_char('\r')
        't' => out.write_char('\t')
        '"' => out.write_char('"')
        '\\' => out.write_char('\\')
        '$' => out.write_char('$')
        _ => {
          out.write_char('\\')
          out.write_char(n)
        }
      }
      i += 2
      continue
    }
    out.write_char(chars[i])
    i += 1
  }
  out.to_string()
}

///|
/// Expand `$VAR` and `${VAR}` in a `.env` value against the variables parsed so
/// far. An unknown variable expands to the empty string, matching
/// python-dotenv's default.
fn expand_dotenv_value(value : String, known : Map[String, String]) -> String {
  if !value.contains_char('$') {
    return value
  }
  let out = StringBuilder(size_hint=value.length())
  let chars = value.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c != '$' {
      out.write_char(c)
      i += 1
      continue
    }
    if i + 1 >= chars.length() {
      out.write_char('$')
      i += 1
      continue
    }
    let next = chars[i + 1]
    if next == '$' {
      out.write_char('$')
      i += 2
      continue
    }
    if next == '{' {
      let mut j = i + 2
      let name = StringBuilder()
      while j < chars.length() && chars[j] != '}' {
        name.write_char(chars[j])
        j += 1
      }
      if j < chars.length() {
        out.write_string(known.get(name.to_string()).unwrap_or(""))
        i = j + 1
      } else {
        out.write_char('$')
        i += 1
      }
      continue
    }
    if dotenv_var_start(next) {
      let mut j = i + 1
      let name = StringBuilder()
      while j < chars.length() && dotenv_var_char(chars[j]) {
        name.write_char(chars[j])
        j += 1
      }
      out.write_string(known.get(name.to_string()).unwrap_or(""))
      i = j
      continue
    }
    out.write_char('$')
    i += 1
  }
  out.to_string()
}

///|
fn dotenv_var_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
fn dotenv_var_char(c : Char) -> Bool {
  dotenv_var_start(c) || (c >= '0' && c <= '9')
}
