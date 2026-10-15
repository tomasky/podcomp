///|
/// Bash-style variable substitution, as Compose specifies it.
///
/// Supported forms: `$VAR`, `${VAR}`, `${VAR:-default}` (default when unset or
/// empty), `${VAR-default}` (default when unset), `${VAR:?err}` / `${VAR?err}`
/// (fail when unset), `${VAR:+alt}` / `${VAR+alt}` (alternate when set), and
/// `$$` for a literal `$`.

///|
/// Substitute every variable reference in one string.
pub fn interp_str(
  value : String,
  env : Map[String, String],
) -> String raise Error {
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
      let closing = find_closing_brace(chars, i + 1)
      if closing < 0 {
        raise fail(
          "no closing brace found for variable interpolation in \"\{value}\"",
        )
      }
      let content = String::from_array(chars[i + 2:closing])
      out.write_string(resolve_brace(content, env))
      i = closing + 1
      continue
    }
    if is_var_start(next) {
      let mut j = i + 1
      let name = StringBuilder()
      while j < chars.length() && is_var_char(chars[j]) {
        name.write_char(chars[j])
        j += 1
      }
      out.write_string(env.get(name.to_string()).unwrap_or(""))
      i = j
      continue
    }
    out.write_char('$')
    i += 1
  }
  out.to_string()
}

///|
/// The index of the `}` matching the `{` at `open`, or -1.
fn find_closing_brace(chars : Array[Char], open : Int) -> Int {
  let mut level = 0
  let mut i = open
  while i < chars.length() {
    if chars[i] == '{' {
      level += 1
    } else if chars[i] == '}' {
      level -= 1
      if level == 0 {
        return i
      }
    }
    i += 1
  }
  -1
}

///|
/// Resolve the inside of a `${...}` reference.
fn resolve_brace(
  content : String,
  env : Map[String, String],
) -> String raise Error {
  let chars = content.to_array()
  if chars.length() == 0 || !is_var_start(chars[0]) {
    raise fail(
      "invalid interpolation format: $\{" + content + "} (escape a literal $ as $$)",
    )
  }
  let mut i = 0
  let name = StringBuilder()
  while i < chars.length() && is_var_char(chars[i]) {
    name.write_char(chars[i])
    i += 1
  }
  let key = name.to_string()
  if i >= chars.length() {
    return env.get(key).unwrap_or("")
  }
  let rest = content[i:].to_owned()
  let (op, operand) = if rest.has_prefix(":-") {
    (":-", rest[2:].to_owned())
  } else if rest.has_prefix(":?") {
    (":?", rest[2:].to_owned())
  } else if rest.has_prefix(":+") {
    (":+", rest[2:].to_owned())
  } else if rest.has_prefix("-") {
    ("-", rest[1:].to_owned())
  } else if rest.has_prefix("?") {
    ("?", rest[1:].to_owned())
  } else if rest.has_prefix("+") {
    ("+", rest[1:].to_owned())
  } else {
    raise fail("invalid variable interpolation syntax: $\{" + content + "}")
  }
  apply_operator(key, op, operand, env)
}

///|
/// The operator semantics, matching the Compose spec.
fn apply_operator(
  name : String,
  op : String,
  operand : String,
  env : Map[String, String],
) -> String raise Error {
  let value = env.get(name)
  match op {
    ":-" =>
      match value {
        Some(v) if v.length() > 0 => v
        _ => interp_str(operand, env)
      }
    "-" =>
      match value {
        Some(v) => v
        None => interp_str(operand, env)
      }
    ":?" =>
      match value {
        Some(v) if v.length() > 0 => v
        _ => {
          let detail = if operand.length() > 0 {
            interp_str(operand, env)
          } else {
            ""
          }
          raise fail("required variable \{name} is missing a value: \{detail}")
        }
      }
    "?" =>
      match value {
        Some(v) => v
        None => {
          let detail = if operand.length() > 0 {
            interp_str(operand, env)
          } else {
            ""
          }
          raise fail("required variable \{name} is missing a value: \{detail}")
        }
      }
    ":+" =>
      match value {
        Some(v) if v.length() > 0 => interp_str(operand, env)
        _ => ""
      }
    "+" =>
      match value {
        Some(_) => interp_str(operand, env)
        None => ""
      }
    _ => raise fail("unknown operator \{op} in variable interpolation")
  }
}

///|
fn is_var_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
fn is_var_char(c : Char) -> Bool {
  is_var_start(c) || (c >= '0' && c <= '9')
}

///|
/// Interpolate every string in a value tree.
///
/// Within a service mapping, the service's own `environment` entries are added
/// to the substitution scope first, so `command: "$${PORT}"` can see a `PORT`
/// the service sets. Variables already in `env` win, matching the reference
/// implementation.
pub fn rec_subs(
  v : @yaml.Yaml,
  env : Map[String, String],
) -> @yaml.Yaml raise Error {
  match v {
    @yaml.Yaml::String(s) => y_str_v(interp_str(s, env))
    @yaml.Yaml::Array(a) => {
      let out : Array[@yaml.Yaml] = []
      for item in a {
        out.push(rec_subs(item, env))
      }
      y_arr_v(out)
    }
    @yaml.Yaml::Map(m) => {
      let scope = service_scope(m, env)
      let out : Map[String, @yaml.Yaml] = Map([])
      for entry in m {
        let (k, value) = entry
        out[interp_str(k, scope)] = rec_subs(value, scope)
      }
      y_map_v(out)
    }
    _ => v
  }
}

///|
/// Build the substitution scope for a mapping: the ambient environment plus any
/// `environment` entries the mapping defines that the ambient one lacks.
fn service_scope(
  m : Map[String, @yaml.Yaml],
  env : Map[String, String],
) -> Map[String, String] raise Error {
  let scope : Map[String, String] = Map([])
  for entry in env {
    let (k, value) = entry
    scope[k] = value
  }
  match m.get("environment") {
    Some(env_value) =>
      match y_map(env_value) {
        Some(em) =>
          for entry in em {
            let (k, value) = entry
            if !scope.contains(k) {
              match y_str(value) {
                Some(s) => scope[k] = interp_str(s, scope)
                None => ()
              }
            }
          }
        None => ()
      }
    None => ()
  }
  scope
}
