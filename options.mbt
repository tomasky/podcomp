///|
/// The global options every command accepts, before the subcommand name.
/// `podcomp` mirrors the reference implementation's flag set so an existing
/// `docker-compose`/`podman-compose` invocation keeps working.

///|
pub struct GlobalOptions {
  files : Array[String]
  mut project_name : String?
  profiles : Array[String]
  env_files : Array[String]
  mut podman_path : String
  mut dry_run : Bool
  mut verbose : Bool
  mut no_ansi : Bool
  mut no_cleanup : Bool
  mut in_pod : String?
  mut pod_args : String?
  podman_args : Array[String]
  podman_cmd_args : Map[String, Array[String]]
}

///|
pub fn new_global_options() -> GlobalOptions {
  {
    files: [],
    project_name: None,
    profiles: [],
    env_files: [],
    podman_path: "podman",
    dry_run: false,
    verbose: false,
    no_ansi: false,
    no_cleanup: false,
    in_pod: None,
    pod_args: None,
    podman_args: [],
    podman_cmd_args: Map([]),
  }
}
