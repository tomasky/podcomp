// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "interp_str substitutes plain variables" {
  let env : Map[String, String] = Map([("WHO", "world")])
  assert_eq(interp_str("hello $WHO", env), "hello world")
  assert_eq(interp_str("hello ${WHO}!", env), "hello world!")
}

///|
test "interp_str keeps an unknown variable empty" {
  let env : Map[String, String] = Map([])
  assert_eq(interp_str("[$MISSING]", env), "[]")
}

///|
test "interp_str honours the default operators" {
  let env : Map[String, String] = Map([("SET", "yes"), ("EMPTY", "")])
  assert_eq(interp_str("${MISSING:-fallback}", env), "fallback")
  assert_eq(interp_str("${EMPTY:-fallback}", env), "fallback")
  assert_eq(interp_str("${EMPTY-fallback}", env), "")
  assert_eq(interp_str("${SET:-fallback}", env), "yes")
  assert_eq(interp_str("${SET:+alt}", env), "alt")
  assert_eq(interp_str("${MISSING:+alt}", env), "")
}

///|
test "interp_str treats $$ as a literal dollar" {
  let env : Map[String, String] = Map([])
  assert_eq(interp_str("cost: $$5", env), "cost: $5")
}

///|
test "parse_short_mount unpacks source, target and options" {
  let m = parse_short_mount("./html:/usr/share/nginx/html:ro", "/srv/app")
  assert_eq(m.kind, "bind")
  assert_eq(m.source, Some("/srv/app/html"))
  assert_eq(m.target, "/usr/share/nginx/html")
  assert_eq(m.options, ["ro"])
}

///|
test "parse_short_mount treats a bare path as an anonymous volume" {
  let m = parse_short_mount("/data", "/srv/app")
  assert_eq(m.kind, "volume")
  assert_eq(m.source, None)
  assert_eq(m.target, "/data")
}

///|
test "str_to_seconds understands compose durations" {
  assert_eq(str_to_seconds("90s"), Some(90))
  assert_eq(str_to_seconds("1m30s"), Some(90))
  assert_eq(str_to_seconds("2h"), Some(7200))
  assert_eq(str_to_seconds("500ms"), Some(0))
  assert_eq(str_to_seconds("15"), Some(15))
  assert_eq(str_to_seconds("nonsense"), None)
}

///|
test "version_at_least compares dotted versions" {
  assert_true(version_at_least("5.6.0", "5.6.0"))
  assert_true(version_at_least("5.7.1", "5.6.0"))
  assert_true(version_at_least("6.0.0", "5.6.0"))
  assert_false(version_at_least("5.5.9", "5.6.0"))
  assert_false(version_at_least("4.9.3", "5.6.0"))
}

///|
test "rec_merge concatenates sequences without duplicating them" {
  let target = y_obj([("ports", y_arr_v([y_str_v("8080:80")]))])
  let source = y_obj([("ports", y_arr_v([y_str_v("9090:90")]))])
  let tm = y_map(target).unwrap()
  let sm = y_map(source).unwrap()
  rec_merge(tm, sm)
  assert_eq(y_list_str(y_get(y_map_v(tm), "ports").unwrap()), [
    "8080:80", "9090:90",
  ])
}

///|
test "rec_merge replaces command instead of concatenating" {
  let target = y_obj([("command", y_arr_v([y_str_v("a")]))])
  let source = y_obj([("command", y_arr_v([y_str_v("b")]))])
  let tm = y_map(target).unwrap()
  let sm = y_map(source).unwrap()
  rec_merge(tm, sm)
  assert_eq(y_list_str(y_get(y_map_v(tm), "command").unwrap()), ["b"])
}

///|
test "normalize_depends expands the shorthand list" {
  let v = normalize_depends(y_arr_v([y_str_v("db")]))
  let m = y_map(v).unwrap()
  assert_true(m.contains("db"))
  assert_eq(
    y_str(y_get(y_get(y_map_v(m), "db").unwrap(), "condition").unwrap()),
    Some("service_started"),
  )
}

///|
test "normalize_project_name keeps only the accepted characters" {
  assert_eq(normalize_project_name("My App!"), "MyApp")
  assert_eq(normalize_project_name("a_b-c.d"), "a_b-c.d")
}

///|
test "container_mounts parses every volumes entry" {
  let compose = new_compose()
  compose.dirname = "/srv/app"
  let cnt = y_obj([
    (
      "volumes",
      y_arr_v([
        y_str_v("./html:/usr/share/nginx/html:ro"),
        y_str_v("pgdata:/var/lib/data"),
        y_str_v("/data"),
      ]),
    ),
  ])
  let mounts = container_mounts(compose, cnt)
  assert_eq(mounts.length(), 3)
  assert_eq(mounts[0].kind, "bind")
  assert_eq(mounts[0].source, Some("/srv/app/html"))
  assert_eq(mounts[1].kind, "volume")
  assert_eq(mounts[1].source, Some("pgdata"))
  assert_eq(mounts[2].kind, "volume")
  assert_eq(mounts[2].source, None)
}

///|
test "compose_env_file reads each path once" {
  let path = "/tmp/podcomp_env_cache_test.env"
  @fs.write_string_to_file(path, "A=1\n") catch {
    _ => return
  }
  let compose = new_compose()
  assert_eq(compose_env_file(compose, path).get("A"), Some("1"))
  // The parsed map is cached, so rewriting the file is not observed.
  @fs.write_string_to_file(path, "A=2\n") catch {
    _ => ()
  }
  assert_eq(compose_env_file(compose, path).get("A"), Some("1"))
  @fs.remove_file(path) catch {
    _ => ()
  }
}
