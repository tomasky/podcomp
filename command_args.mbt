///|
/// The options a subcommand accepts. A single flat struct keeps the parser
/// small; each command reads only the fields it documents.

///|
pub struct CommandArgs {
  services : Array[String]
  mut detach : Bool
  mut no_deps : Bool
  mut no_build : Bool
  mut build : Bool
  mut force_recreate : Bool
  mut no_recreate : Bool
  mut no_start : Bool
  mut volumes : Bool
  mut remove_orphans : Bool
  mut rmi : String?
  mut timeout : Int32?
  mut follow : Bool
  mut tail : String?
  mut since : String?
  mut until : String?
  mut timestamps : Bool
  mut names : Bool
  mut no_color : Bool
  mut no_log_prefix : Bool
  mut quiet : Bool
  mut format : String?
  mut short : Bool
  mut signal : String?
  mut all : Bool
  mut index : Int32
  mut protocol : String
  mut private_port : Int32
  mut no_cache : Bool
  mut pull : String?
  build_arg : Array[String]
  mut quiet_pull : Bool
  mut wait : Bool
  mut wait_timeout : Int32?
  mut name : String?
  mut entrypoint : String?
  env : Array[String]
  mut user : String?
  mut workdir : String?
  mut rm : Bool
  publish : Array[String]
  mut service_ports : Bool
  volume : Array[String]
  mut no_tty : Bool
  mut privileged : Bool
  mut force_local : Bool
  mut services_flag : Bool
  mut no_normalize : Bool
  pull_always : Bool
  mut abort_on_container_exit : Bool
  mut abort_on_container_failure : Bool
  mut exit_code_from : String?
  no_attach : Array[String]
  mut scale : String?
  mut renew_anon_volumes : Bool
  mut no_hosts : Bool
  cnt_command : Array[String]
}

///|
pub fn new_command_args() -> CommandArgs {
  {
    services: [],
    detach: false,
    no_deps: false,
    no_build: false,
    build: false,
    force_recreate: false,
    no_recreate: false,
    no_start: false,
    volumes: false,
    remove_orphans: false,
    rmi: None,
    timeout: None,
    follow: false,
    tail: None,
    since: None,
    until: None,
    timestamps: false,
    names: false,
    no_color: false,
    no_log_prefix: false,
    quiet: false,
    format: None,
    short: false,
    signal: None,
    all: false,
    index: 1,
    protocol: "tcp",
    private_port: 0,
    no_cache: false,
    pull: None,
    build_arg: [],
    quiet_pull: false,
    wait: false,
    wait_timeout: None,
    name: None,
    entrypoint: None,
    env: [],
    user: None,
    workdir: None,
    rm: false,
    publish: [],
    service_ports: false,
    volume: [],
    no_tty: false,
    privileged: false,
    force_local: false,
    services_flag: false,
    no_normalize: false,
    pull_always: false,
    abort_on_container_exit: false,
    abort_on_container_failure: false,
    exit_code_from: None,
    no_attach: [],
    scale: None,
    renew_anon_volumes: false,
    no_hosts: false,
    cnt_command: [],
  }
}
