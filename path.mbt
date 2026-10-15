///|
/// Minimal POSIX path handling. The Compose spec resolves every relative path
/// against the directory holding the compose file, so these are used a lot and
/// are kept independent of the process working directory.

///|
/// Expand a leading `~` into the user's home directory.
pub fn path_expand_home(path : String) -> String {
  if path == "~" {
    return home_dir()
  }
  if path.has_prefix("~/") {
    return home_dir() + "/" + path[2:].to_owned()
  }
  path
}

///|
/// The user's home directory, or an empty string.
pub fn home_dir() -> String {
  match @env.get_env_var("HOME") {
    Some(home) if home.length() > 0 => home
    _ =>
      match @env.get_env_var("USERPROFILE") {
        Some(profile) => profile
        None => ""
      }
  }
}

///|
/// Join two path fragments with a single separator.
pub fn path_join(a : String, b : String) -> String {
  if a.length() == 0 {
    return b
  }
  if b.length() == 0 {
    return a
  }
  if a.has_suffix("/") {
    return a + b
  }
  a + "/" + b
}

///|
/// Collapse `.` and `..` segments, preserving a leading `/`.
pub fn path_normalize(path : String) -> String {
  let absolute = path.has_prefix("/")
  let parts = path.split("/").to_array()
  let stack : Array[String] = []
  for part in parts {
    let seg = part.to_owned()
    if seg.length() == 0 || seg == "." {
      continue
    }
    if seg == ".." {
      if stack.length() > 0 && stack[stack.length() - 1] != ".." {
        ignore(stack.pop())
      } else if !absolute {
        stack.push("..")
      }
      continue
    }
    stack.push(seg)
  }
  let joined = stack.join("/")
  if absolute {
    "/" + joined
  } else if joined.length() == 0 {
    "."
  } else {
    joined
  }
}

///|
/// Resolve `path` against `base` when it is relative, then normalize.
pub fn path_abspath(base : String, path : String) -> String {
  let expanded = path_expand_home(path)
  if expanded.has_prefix("/") {
    path_normalize(expanded)
  } else {
    path_normalize(path_join(base, expanded))
  }
}

///|
/// The directory part of a path.
pub fn path_dirname(path : String) -> String {
  match path.rev_split_once("/") {
    Some(pair) => if pair.0.length() == 0 { "/" } else { pair.0.to_owned() }
    None => "."
  }
}

///|
/// The final component of a path.
pub fn path_basename(path : String) -> String {
  match path.rev_split_once("/") {
    Some(pair) => pair.1.to_owned()
    None => path
  }
}

///|
/// The process working directory, or `.` when it cannot be read.
pub fn current_dir() -> String {
  match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
}

///|
/// An absolute version of `path` relative to the current directory.
pub fn abspath(path : String) -> String {
  path_abspath(current_dir(), path)
}
