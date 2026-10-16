///|
/// Helpers over the dynamic YAML tree.
///
/// A Compose file is dynamic by nature: almost every field is optional, and
/// many accept two or three different shapes (`environment` is a map *or* a
/// list, `ports` is a list *or* a map, `build` is a string *or* a map). Rather
/// than mirror the whole spec in a typed tree, the model is kept as `Yaml` and
/// every access goes through one of these coercions.

///|
/// Lower-case ASCII only. MoonBit's core has no `String::to_lowercase`, and
/// env-var names and boolean literals are ASCII anyway.
pub fn ascii_lower(s : String) -> String {
  let out = StringBuilder(size_hint=s.length())
  for c in s {
    out.write_char(c.to_ascii_lowercase())
  }
  out.to_string()
}

///|
/// A scalar rendered as text. `None` for collections and nulls.
pub fn y_str(v : @yaml.Yaml) -> String? {
  match v {
    @yaml.Yaml::String(s) => Some(s)
    @yaml.Yaml::Boolean(b) => Some(if b { "true" } else { "false" })
    @yaml.Yaml::Integer(i) => Some(i.to_string())
    @yaml.Yaml::Real(_, repr~) => Some(repr)
    _ => None
  }
}

///|
/// A scalar rendered as text, or `fallback`.
pub fn y_str_or(v : @yaml.Yaml, fallback : String) -> String {
  match y_str(v) {
    Some(s) => s
    None => fallback
  }
}

///|
/// A boolean, accepting the spellings Compose and `podman` accept.
pub fn y_bool(v : @yaml.Yaml) -> Bool? {
  match v {
    @yaml.Yaml::Boolean(b) => Some(b)
    @yaml.Yaml::Integer(i) => Some(i != 0)
    @yaml.Yaml::String(s) =>
      match ascii_lower(s) {
        "true" | "yes" | "on" | "1" => Some(true)
        "false" | "no" | "off" | "0" => Some(false)
        _ => None
      }
    _ => None
  }
}

///|
/// Parse an integer, or `None` when the text is not one.
pub fn try_int_str(s : String) -> Int32? {
  Some(@string.parse_int(s.trim())) catch {
    _ => None
  }
}

///|
/// An integer, accepting ints, floats and numeric strings.
pub fn y_int(v : @yaml.Yaml) -> Int32? {
  match v {
    @yaml.Yaml::Integer(i) => Some(i.to_int())
    @yaml.Yaml::Real(d, ..) => Some(d.to_int())
    @yaml.Yaml::String(s) => try_int_str(s)
    _ => None
  }
}

///|
/// The map behind a `Yaml::Map`, if any.
pub fn y_map(v : @yaml.Yaml) -> Map[String, @yaml.Yaml]? {
  match v {
    @yaml.Yaml::Map(m) => Some(m)
    _ => None
  }
}

///|
/// The array behind a `Yaml::Array`, if any.
pub fn y_arr(v : @yaml.Yaml) -> Array[@yaml.Yaml]? {
  match v {
    @yaml.Yaml::Array(a) => Some(a)
    _ => None
  }
}

///|
/// Look a key up in a mapping value. `None` for a non-mapping or a missing key.
pub fn y_get(v : @yaml.Yaml, key : String) -> @yaml.Yaml? {
  match v {
    @yaml.Yaml::Map(m) => m.get(key)
    _ => None
  }
}

///|
/// The `norm_as_list` of the reference implementation: a scalar becomes a
/// one-element list, a map becomes `["k=v", "k2"]`, null becomes empty.
pub fn y_list(v : @yaml.Yaml) -> Array[@yaml.Yaml] {
  match v {
    @yaml.Yaml::Null | @yaml.Yaml::BadValue => []
    @yaml.Yaml::Array(a) => a
    @yaml.Yaml::Map(m) => {
      let out : Array[@yaml.Yaml] = []
      for entry in m {
        let (k, value) = entry
        match value {
          @yaml.Yaml::Null | @yaml.Yaml::BadValue => out.push(y_str_v(k))
          _ => out.push(y_str_v(k + "=" + y_str_or(value, "")))
        }
      }
      out
    }
    _ => [v]
  }
}

///|
/// `y_list`, keeping only the scalars.
pub fn y_list_str(v : @yaml.Yaml) -> Array[String] {
  let out : Array[String] = []
  for item in y_list(v) {
    match y_str(item) {
      Some(s) => out.push(s)
      None => ()
    }
  }
  out
}

///|
/// The `norm_as_dict` of the reference implementation: `["k=v", "k2"]` becomes
/// `{k: v, k2: null}`. Bare keys keep a `Yaml::Null` value so the original
/// spelling survives a round-trip.
pub fn y_dict(v : @yaml.Yaml) -> Map[String, @yaml.Yaml] {
  match v {
    @yaml.Yaml::Null | @yaml.Yaml::BadValue => Map([])
    @yaml.Yaml::Map(m) => m
    @yaml.Yaml::Array(a) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      for item in a {
        match y_str(item) {
          Some(s) =>
            match s.split_once("=") {
              Some(pair) => out[pair.0.to_owned()] = y_str_v(pair.1.to_owned())
              None => out[s] = @yaml.Yaml::Null
            }
          None => ()
        }
      }
      out
    }
    @yaml.Yaml::String(s) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      match s.split_once("=") {
        Some(pair) => out[pair.0.to_owned()] = y_str_v(pair.1.to_owned())
        None => out[s] = @yaml.Yaml::Null
      }
      out
    }
    _ => Map([])
  }
}

///|
/// Turn a mapping into a list of `k=v` (or bare `k`) strings. This is the
/// `norm_as_list(norm_as_dict(x))` shape `container_to_args` wants.
pub fn y_env_list(v : @yaml.Yaml) -> Array[String] {
  let out : Array[String] = []
  for entry in y_dict(v) {
    let (k, value) = entry
    match value {
      @yaml.Yaml::Null | @yaml.Yaml::BadValue => out.push(k)
      _ => out.push(k + "=" + y_str_or(value, ""))
    }
  }
  out
}

///|
pub fn y_str_v(s : String) -> @yaml.Yaml {
  @yaml.Yaml::String(s)
}

///|
pub fn y_int_v(i : Int32) -> @yaml.Yaml {
  @yaml.Yaml::Integer(i.to_int64())
}

///|
pub fn y_bool_v(b : Bool) -> @yaml.Yaml {
  @yaml.Yaml::Boolean(b)
}

///|
pub fn y_null() -> @yaml.Yaml {
  @yaml.Yaml::Null
}

///|
pub fn y_arr_v(a : Array[@yaml.Yaml]) -> @yaml.Yaml {
  @yaml.Yaml::Array(a)
}

///|
pub fn y_map_v(m : Map[String, @yaml.Yaml]) -> @yaml.Yaml {
  @yaml.Yaml::Map(m)
}

///|
/// Build a mapping value from key/value pairs.
pub fn y_obj(pairs : Array[(String, @yaml.Yaml)]) -> @yaml.Yaml {
  let m : Map[String, @yaml.Yaml] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  @yaml.Yaml::Map(m)
}

///|
/// Deep copy. Merge mutates its target, so every value copied in must be owned.
pub fn y_clone(v : @yaml.Yaml) -> @yaml.Yaml {
  match v {
    @yaml.Yaml::Map(m) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      for entry in m {
        let (k, value) = entry
        out[k] = y_clone(value)
      }
      @yaml.Yaml::Map(out)
    }
    @yaml.Yaml::Array(a) => {
      let out : Array[@yaml.Yaml] = []
      for item in a {
        out.push(y_clone(item))
      }
      @yaml.Yaml::Array(out)
    }
    _ => v
  }
}

// `y_dump` lives in `yaml_dump.mbt`, which ports PyYAML's block emitter.
