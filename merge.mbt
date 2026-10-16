///|
/// Compose's merge rules: how several files, and several definitions of the
/// same service, combine into one model.
///
/// The rules that matter in practice are:
///   * a scalar or mapping in a later file replaces the earlier one;
///   * two mappings merge key by key;
///   * two sequences concatenate, except `volumes`, where a later mount with
///     the same container path replaces the earlier one;
///   * `command` and `entrypoint` are replaced, never concatenated.

///|
/// Merge `source` into `target` in place.
pub fn rec_merge(
  target : Map[String, @yaml.Yaml],
  source : Map[String, @yaml.Yaml],
) -> Unit raise Error {
  rec_merge_one(target, source)
}

///|
fn rec_merge_one(
  target : Map[String, @yaml.Yaml],
  source : Map[String, @yaml.Yaml],
) -> Unit raise Error {
  // Merge keys both sides define first, then copy the keys only the source
  // has. Copying first would make sequences look as if they appeared twice.
  let keys : Array[String] = []
  for entry in target {
    keys.push(entry.0)
  }
  for k in keys {
    if !source.contains(k) {
      continue
    }
    let mut tv = target[k]
    let mut sv = source[k]
    if k == "command" || k == "entrypoint" {
      target[k] = y_clone(sv)
      continue
    }
    // `vol_1:` followed by `vol_1: {driver: ...}` merges into a mapping.
    match tv {
      @yaml.Yaml::Null =>
        match sv {
          @yaml.Yaml::Map(_) => {
            target[k] = y_clone(sv)
            continue
          }
          _ => ()
        }
      _ => ()
    }
    if k == "depends_on" {
      tv = normalize_depends(tv)
      sv = normalize_depends(sv)
      target[k] = tv
    }
    match (tv, sv) {
      (@yaml.Yaml::Array(a), @yaml.Yaml::Array(b)) => {
        if k == "volumes" {
          remove_shadowed_mounts(a, b)
        }
        for item in b {
          a.push(y_clone(item))
        }
        target[k] = y_arr_v(a)
      }
      (@yaml.Yaml::Map(m1), @yaml.Yaml::Map(m2)) => {
        rec_merge_one(m1, m2)
        target[k] = y_map_v(m1)
      }
      _ => target[k] = y_clone(sv)
    }
  }
  for entry in source {
    let (k, v) = entry
    if !target.contains(k) {
      target[k] = y_clone(v)
    }
  }
}

///|
/// Bring `depends_on` to its mapping form so two files can merge it.
pub fn normalize_depends(v : @yaml.Yaml) -> @yaml.Yaml {
  match v {
    @yaml.Yaml::Array(a) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      for item in a {
        match y_str(item) {
          Some(s) => out[s] = started_condition()
          None => ()
        }
      }
      y_map_v(out)
    }
    @yaml.Yaml::String(s) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      out[s] = started_condition()
      y_map_v(out)
    }
    @yaml.Yaml::Map(m) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      for entry in m {
        let (k, value) = entry
        match y_map(value) {
          Some(dm) => {
            if !dm.contains("condition") {
              dm["condition"] = y_str_v("service_started")
            }
            out[k] = y_map_v(dm)
          }
          None => out[k] = started_condition()
        }
      }
      y_map_v(out)
    }
    _ => v
  }
}

///|
/// The default dependency condition, `{condition: service_started}`.
fn started_condition() -> @yaml.Yaml {
  y_obj([("condition", y_str_v("service_started"))])
}

///|
/// Drop target mounts whose container path also appears in source, so the
/// source definition wins.
fn remove_shadowed_mounts(
  target : Array[@yaml.Yaml],
  source : Array[@yaml.Yaml],
) -> Unit {
  let shadowed : Array[String] = []
  for item in source {
    match mount_target_of(item) {
      Some(t) => shadowed.push(t)
      None => ()
    }
  }
  if shadowed.length() == 0 {
    return
  }
  let mut i = 0
  while i < target.length() {
    let drop = match mount_target_of(target[i]) {
      Some(t) => shadowed.contains(t)
      None => false
    }
    if drop {
      ignore(target.remove(i))
    } else {
      i += 1
    }
  }
}

///|
/// The container path of a short or long mount description.
pub fn mount_target_of(item : @yaml.Yaml) -> String? {
  match item {
    @yaml.Yaml::String(s) => short_mount_target(s)
    @yaml.Yaml::Map(m) =>
      match m.get("target") {
        Some(t) => y_str(t)
        None => None
      }
    _ => None
  }
}

///|
/// The container path in a `SOURCE:TARGET[:OPTIONS]` string.
pub fn short_mount_target(spec : String) -> String? {
  let parts = spec.split(":").to_array()
  match parts.length() {
    1 => Some(spec)
    2 =>
      if parts[1].has_prefix("/") {
        Some(parts[1].to_owned())
      } else {
        Some(parts[0].to_owned())
      }
    _ => Some(parts[1].to_owned())
  }
}

///|
/// Resolve YAML merge keys (`<<: *anchor`) in place, bottom-up.
///
/// The loader marks a plain `<<` key with `merge_key_marker()`, so it is expanded
/// here: a single mapping, or a sequence of mappings, contributes the keys the
/// node does not already define, and the first source wins. The marker key is
/// removed afterwards. A quoted `"<<"` is an ordinary key and is left alone.
pub fn apply_merge_keys(v : @yaml.Yaml) -> @yaml.Yaml {
  match v {
    @yaml.Yaml::Map(m) => {
      let out : Map[String, @yaml.Yaml] = Map([])
      // Merge sources first so an explicit key below can override them.
      match m.get(merge_key_marker()) {
        Some(merge_value) => {
          let sources : Array[@yaml.Yaml] = match merge_value {
            @yaml.Yaml::Array(a) => a
            _ => [merge_value]
          }
          for src in sources {
            match apply_merge_keys(src) {
              @yaml.Yaml::Map(sm) =>
                for entry in sm {
                  let (k, value) = entry
                  if !out.contains(k) {
                    out[k] = value
                  }
                }
              _ => ()
            }
          }
        }
        None => ()
      }
      for entry in m {
        let (k, value) = entry
        if k == merge_key_marker() {
          continue
        }
        out[k] = apply_merge_keys(value)
      }
      y_map_v(out)
    }
    @yaml.Yaml::Array(a) => {
      let out : Array[@yaml.Yaml] = []
      for item in a {
        out.push(apply_merge_keys(item))
      }
      y_arr_v(out)
    }
    _ => v
  }
}
