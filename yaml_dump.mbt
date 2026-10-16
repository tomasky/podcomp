///|
/// Render a value as YAML the way the reference implementation prints it.
///
/// `config` prints `yaml.safe_dump(<merged compose>)`, so matching its output
/// means matching PyYAML's block emitter: keys sorted, indent 2, width 80,
/// ASCII only, flow style only for empty collections, and PyYAML's own rules
/// for when a scalar may stay unquoted. The code below ports that subset of
/// `yaml/emitter.py` plus the implicit resolvers of `yaml/resolver.py`, because
/// the quoting rules are subtle enough that examples alone get them wrong:
/// `12:30` is an int, `1.5e3` is not a float, `2024-1-1` is not a timestamp.
/// `scripts/check-yaml-dump.py` diffs this against PyYAML.
const YAML_INDENT : Int32 = 2

///|
/// PyYAML's `best_width`: the column past which it looks for a break point.
const YAML_WIDTH : Int32 = 80

///|
/// One document's worth of emitter state, mirroring PyYAML's `Emitter`.
///
/// `indent` is `-1` for PyYAML's `None` (nothing has opened a block yet).
/// `whitespace` and `indention` say whether the next token may be glued to the
/// previous one, which is what decides between `- - 1` and a line break.
priv struct PyYamlEmitter {
  out : StringBuilder
  mut indent : Int32
  mut column : Int32
  mut whitespace : Bool
  mut indention : Bool
  mut root_context : Bool
  mut open_ended : Bool
}

///|
fn PyYamlEmitter::new() -> PyYamlEmitter {
  {
    out: StringBuilder(),
    indent: -1,
    column: 0,
    whitespace: true,
    indention: true,
    root_context: false,
    open_ended: false,
  }
}

///|
/// Write text that is not an indicator: the column advances, the other flags
/// are left alone because the caller decides what the text means.
fn PyYamlEmitter::raw(self : PyYamlEmitter, text : String) -> Unit {
  self.out.write_string(text)
  self.column += text.char_length()
}

///|
fn PyYamlEmitter::raw_char(self : PyYamlEmitter, c : Char) -> Unit {
  self.out.write_char(c)
  self.column += 1
}

///|
/// Port of `Emitter.write_indicator`: inserts a separating space when the
/// previous token needs one, then records what the indicator implies.
fn PyYamlEmitter::indicator(
  self : PyYamlEmitter,
  text : String,
  need_whitespace : Bool,
  whitespace~ : Bool = false,
  indention~ : Bool = false,
) -> Unit {
  if self.whitespace || !need_whitespace {
    self.raw(text)
  } else {
    self.raw(" ")
    self.raw(text)
  }
  self.whitespace = whitespace
  self.indention = self.indention && indention
}

///|
/// Port of `Emitter.write_line_break`.
fn PyYamlEmitter::line_break(self : PyYamlEmitter) -> Unit {
  self.whitespace = true
  self.indention = true
  self.column = 0
  self.out.write_char('\n')
}

///|
/// Port of `Emitter.write_indent`: start a fresh line and pad to `indent` when
/// the current position is not already a valid start of a line.
fn PyYamlEmitter::indent_to(self : PyYamlEmitter) -> Unit {
  let indent = if self.indent < 0 { 0 } else { self.indent }
  if !self.indention ||
    self.column > indent ||
    (self.column == indent && !self.whitespace) {
    self.line_break()
  }
  if self.column < indent {
    self.whitespace = true
    while self.column < indent {
      self.raw(" ")
    }
  }
}

///|
/// Port of `Emitter.increase_indent`, returning the indent to restore later.
fn PyYamlEmitter::push_indent(
  self : PyYamlEmitter,
  flow~ : Bool = false,
  indentless~ : Bool = false,
) -> Int32 {
  let saved = self.indent
  if self.indent < 0 {
    self.indent = if flow { YAML_INDENT } else { 0 }
  } else if !indentless {
    self.indent += YAML_INDENT
  }
  saved
}

///|
/// The part of PyYAML's `ScalarAnalysis` the block emitter consults.
priv struct ScalarAnalysis {
  empty : Bool
  multiline : Bool
  allow_block_plain : Bool
  allow_single_quoted : Bool
}

///|
fn is_yaml_break(c : Char) -> Bool {
  match c {
    '\n' | '\u{85}' | '\u{2028}' | '\u{2029}' => true
    _ => false
  }
}

///|
fn is_yaml_blank(c : Char) -> Bool {
  match c {
    '\u{0}' | ' ' | '\t' | '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}' =>
      true
    _ => false
  }
}

///|
/// Indicators that make a plain scalar ambiguous when they come first.
fn is_leading_indicator(c : Char) -> Bool {
  match c {
    '#'
    | ','
    | '['
    | ']'
    | '{'
    | '}'
    | '&'
    | '*'
    | '!'
    | '|'
    | '>'
    | '\''
    | '"'
    | '%'
    | '@'
    | '`' => true
    _ => false
  }
}

///|
/// Port of `Emitter.analyze_scalar` reduced to the flags block style uses.
fn analyze_scalar(ch : Array[Char]) -> ScalarAnalysis {
  let n = ch.length()
  if n == 0 {
    return {
      empty: true,
      multiline: false,
      allow_block_plain: true,
      allow_single_quoted: true,
    }
  }
  let mut block_indicators = false
  let mut line_breaks = false
  let mut special_characters = false
  let mut leading_space = false
  let mut leading_break = false
  let mut trailing_space = false
  let mut trailing_break = false
  let mut break_space = false
  let mut space_break = false
  if (n >= 3 && ch[0] == '-' && ch[1] == '-' && ch[2] == '-') ||
    (n >= 3 && ch[0] == '.' && ch[1] == '.' && ch[2] == '.') {
    block_indicators = true
  }
  let mut preceded_by_whitespace = true
  let mut followed_by_whitespace = n == 1 || is_yaml_blank(ch[1])
  let mut previous_space = false
  let mut previous_break = false
  let mut index = 0
  while index < n {
    let c = ch[index]
    if index == 0 {
      if is_leading_indicator(c) {
        block_indicators = true
      }
      if (c == '?' || c == ':') && followed_by_whitespace {
        block_indicators = true
      }
      if c == '-' && followed_by_whitespace {
        block_indicators = true
      }
    } else {
      if c == ':' && followed_by_whitespace {
        block_indicators = true
      }
      if c == '#' && preceded_by_whitespace {
        block_indicators = true
      }
    }
    if is_yaml_break(c) {
      line_breaks = true
    }
    // `safe_dump` uses `allow_unicode=False`, so anything outside printable
    // ASCII has to be escaped, which rules out single quotes.
    if c != '\n' && !(c >= '\u{20}' && c <= '\u{7E}') {
      special_characters = true
    }
    if c == ' ' {
      if index == 0 {
        leading_space = true
      }
      if index == n - 1 {
        trailing_space = true
      }
      if previous_break {
        break_space = true
      }
      previous_space = true
      previous_break = false
    } else if is_yaml_break(c) {
      if index == 0 {
        leading_break = true
      }
      if index == n - 1 {
        trailing_break = true
      }
      if previous_space {
        space_break = true
      }
      previous_space = false
      previous_break = true
    } else {
      previous_space = false
      previous_break = false
    }
    index += 1
    preceded_by_whitespace = is_yaml_blank(c)
    followed_by_whitespace = index + 1 >= n || is_yaml_blank(ch[index + 1])
  }
  let mut allow_block_plain = true
  let mut allow_single_quoted = true
  if leading_space || leading_break || trailing_space || trailing_break {
    allow_block_plain = false
  }
  if break_space {
    allow_block_plain = false
    allow_single_quoted = false
  }
  if space_break || special_characters {
    allow_block_plain = false
    allow_single_quoted = false
  }
  if line_breaks {
    allow_block_plain = false
  }
  if block_indicators {
    allow_block_plain = false
  }
  {
    empty: false,
    multiline: line_breaks,
    allow_block_plain,
    allow_single_quoted,
  }
}

///|
fn is_ascii_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_hex_digit(c : Char) -> Bool {
  is_ascii_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
/// Digits and underscores, as used by PyYAML's int and float patterns.
fn is_int_char(c : Char) -> Bool {
  is_ascii_digit(c) || c == '_'
}

///|
/// Match `[-+]?` and return the index after it.
fn skip_sign(ch : Array[Char], from : Int32) -> Int32 {
  if from < ch.length() && (ch[from] == '+' || ch[from] == '-') {
    from + 1
  } else {
    from
  }
}

///|
/// Match `[0-9]{1,max}` at `from`, returning the index after it.
fn match_digits(ch : Array[Char], from : Int32, max : Int32) -> Int32? {
  let mut index = from
  while index < ch.length() && index - from < max && is_ascii_digit(ch[index]) {
    index += 1
  }
  if index > from {
    Some(index)
  } else {
    None
  }
}

///|
/// Match one `[0-5]?[0-9]` sexagesimal group at `from`.
fn match_sexagesimal(ch : Array[Char], from : Int32) -> Int32? {
  let n = ch.length()
  if from < n &&
    ch[from] >= '0' &&
    ch[from] <= '5' &&
    from + 1 < n &&
    is_ascii_digit(ch[from + 1]) {
    Some(from + 2)
  } else if from < n && is_ascii_digit(ch[from]) {
    Some(from + 1)
  } else {
    None
  }
}

///|
/// Match `(:[0-5]?[0-9])+` at `from`, returning the index after the last group.
fn match_sexagesimal_groups(ch : Array[Char], from : Int32) -> Int32? {
  let mut index = from
  let mut groups = 0
  while index < ch.length() && ch[index] == ':' {
    match match_sexagesimal(ch, index + 1) {
      Some(next) => {
        index = next
        groups += 1
      }
      None => return None
    }
  }
  if groups > 0 {
    Some(index)
  } else {
    None
  }
}

///|
/// The `tag:yaml.org,2002:int` resolver.
fn matches_yaml_int(ch : Array[Char]) -> Bool {
  let n = ch.length()
  let start = skip_sign(ch, 0)
  if start >= n {
    return false
  }
  let head = ch[start]
  if head == '0' && start + 1 < n && ch[start + 1] == 'b' {
    let mut index = start + 2
    if index >= n {
      return false
    }
    while index < n &&
          (ch[index] == '0' || ch[index] == '1' || ch[index] == '_') {
      index += 1
    }
    return index == n
  }
  if head == '0' && start + 1 < n && ch[start + 1] == 'x' {
    let mut index = start + 2
    if index >= n {
      return false
    }
    while index < n && (is_hex_digit(ch[index]) || ch[index] == '_') {
      index += 1
    }
    return index == n
  }
  if head == '0' {
    // `[-+]?0[0-7_]+`, plus the bare `0` from `[-+]?(0|[1-9][0-9_]*)`.
    let mut index = start + 1
    while index < n &&
          ((ch[index] >= '0' && ch[index] <= '7') || ch[index] == '_') {
      index += 1
    }
    return index == n
  }
  if head < '1' || head > '9' {
    return false
  }
  let mut index = start + 1
  while index < n && is_int_char(ch[index]) {
    index += 1
  }
  if index == n {
    return true
  }
  match match_sexagesimal_groups(ch, index) {
    Some(end) => end == n
    None => false
  }
}

///|
/// Match `(?:[eE][-+][0-9]+)?` and return the index after it. PyYAML's float
/// pattern demands the sign, which is why `1.5e3` stays a string.
fn match_float_exponent(ch : Array[Char], from : Int32) -> Int32 {
  let n = ch.length()
  if from >= n || (ch[from] != 'e' && ch[from] != 'E') {
    return from
  }
  if from + 1 >= n || (ch[from + 1] != '-' && ch[from + 1] != '+') {
    return from
  }
  let mut index = from + 2
  if index >= n || !is_ascii_digit(ch[index]) {
    return from
  }
  while index < n && is_ascii_digit(ch[index]) {
    index += 1
  }
  index
}

///|
/// Match one of `words` (`.inf`/`.Inf`/`.INF`, `.nan`/`.NaN`/`.NAN`).
fn match_yaml_word(
  ch : Array[Char],
  from : Int32,
  words : Array[String],
) -> Bool {
  let n = ch.length()
  if from >= n {
    return false
  }
  let word = String::from_array(ch.exact_view(start=from, end=n))
  for candidate in words {
    if word == candidate {
      return true
    }
  }
  false
}

///|
/// The `tag:yaml.org,2002:float` resolver.
fn matches_yaml_float(ch : Array[Char]) -> Bool {
  let n = ch.length()
  if n == 0 {
    return false
  }
  if ch[0] == '.' {
    // `\.(?:nan|NaN|NAN)`, `[-+]?\.(?:inf|Inf|INF)`, or
    // `\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?`
    if match_yaml_word(ch, 0, [".nan", ".NaN", ".NAN"]) {
      return true
    }
    if match_yaml_word(ch, 0, [".inf", ".Inf", ".INF"]) {
      return true
    }
    let mut index = 1
    if index < n && is_ascii_digit(ch[index]) {
      index += 1
      while index < n && is_int_char(ch[index]) {
        index += 1
      }
      return match_float_exponent(ch, index) == n
    }
    return false
  }
  let start = skip_sign(ch, 0)
  if start >= n {
    return false
  }
  if ch[start] == '.' {
    // `[-+]?\.(?:inf|Inf|INF)`
    return match_yaml_word(ch, start, [".inf", ".Inf", ".INF"])
  }
  if !is_ascii_digit(ch[start]) {
    return false
  }
  let mut index = start
  while index < n && is_int_char(ch[index]) {
    index += 1
  }
  if index < n && ch[index] == '.' {
    // `[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+][0-9]+)?`
    index += 1
    while index < n && is_int_char(ch[index]) {
      index += 1
    }
    return match_float_exponent(ch, index) == n
  }
  // `[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*`
  match match_sexagesimal_groups(ch, index) {
    Some(end) =>
      if end < n && ch[end] == '.' {
        let mut tail = end + 1
        while tail < n && is_int_char(ch[tail]) {
          tail += 1
        }
        tail == n
      } else {
        false
      }
    None => false
  }
}

///|
/// The `tag:yaml.org,2002:bool` resolver.
fn matches_yaml_bool(ch : Array[Char]) -> Bool {
  let word = String::from_array(ch[:])
  match word {
    "yes"
    | "Yes"
    | "YES"
    | "no"
    | "No"
    | "NO"
    | "true"
    | "True"
    | "TRUE"
    | "false"
    | "False"
    | "FALSE"
    | "on"
    | "On"
    | "ON"
    | "off"
    | "Off"
    | "OFF" => true
    _ => false
  }
}

///|
/// The `tag:yaml.org,2002:null` resolver (`~`, `null`, `Null`, `NULL`, empty).
fn matches_yaml_null(ch : Array[Char]) -> Bool {
  let word = String::from_array(ch[:])
  word.length() == 0 ||
  word == "~" ||
  word == "null" ||
  word == "Null" ||
  word == "NULL"
}

///|
/// `[0-9][0-9][0-9][0-9]` at the start.
fn match_date_year(ch : Array[Char]) -> Bool {
  if ch.length() < 4 {
    return false
  }
  for index in 0..<4 {
    if !is_ascii_digit(ch[index]) {
      return false
    }
  }
  true
}

///|
/// `[0-9]{4}-[0-9]{2}-[0-9]{2}` starting at `from`.
fn match_date(ch : Array[Char], from : Int32) -> Bool {
  if from + 10 > ch.length() {
    return false
  }
  for offset in 0..<10 {
    let c = ch[from + offset]
    if offset == 4 || offset == 7 {
      if c != '-' {
        return false
      }
    } else if !is_ascii_digit(c) {
      return false
    }
  }
  true
}

///|
/// The `tag:yaml.org,2002:timestamp` resolver.
fn matches_yaml_timestamp(ch : Array[Char]) -> Bool {
  let n = ch.length()
  if match_date(ch, 0) && n == 10 {
    return true
  }
  // `[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt]|[ \t]+)...`
  if !match_date_year(ch) {
    return false
  }
  let mut index = 4
  if index >= n || ch[index] != '-' {
    return false
  }
  match match_digits(ch, index + 1, 2) {
    Some(next) => index = next
    None => return false
  }
  if index >= n || ch[index] != '-' {
    return false
  }
  match match_digits(ch, index + 1, 2) {
    Some(next) => index = next
    None => return false
  }
  if index < n && (ch[index] == 'T' || ch[index] == 't') {
    index += 1
  } else {
    let mut blanks = index
    while blanks < n && (ch[blanks] == ' ' || ch[blanks] == '\t') {
      blanks += 1
    }
    if blanks == index {
      return false
    }
    index = blanks
  }
  match match_digits(ch, index, 2) {
    Some(next) => index = next
    None => return false
  }
  if index >= n || ch[index] != ':' {
    return false
  }
  match match_digits(ch, index + 1, 2) {
    Some(next) => index = next
    None => return false
  }
  if index >= n || ch[index] != ':' {
    return false
  }
  match match_digits(ch, index + 1, 2) {
    Some(next) => index = next
    None => return false
  }
  if index < n && ch[index] == '.' {
    let mut tail = index + 1
    while tail < n && is_ascii_digit(ch[tail]) {
      tail += 1
    }
    index = tail
  }
  let mut blanks = index
  while blanks < n && (ch[blanks] == ' ' || ch[blanks] == '\t') {
    blanks += 1
  }
  if blanks == n {
    return true
  }
  if ch[blanks] == 'Z' {
    return blanks + 1 == n
  }
  if ch[blanks] != '-' && ch[blanks] != '+' {
    return false
  }
  match match_digits(ch, blanks + 1, 2) {
    Some(next) =>
      if next == n {
        true
      } else if ch[next] == ':' {
        match match_digits(ch, next + 1, 2) {
          Some(end) => end == n
          None => false
        }
      } else {
        false
      }
    None => false
  }
}

///|
/// Whether a plain scalar would be read back as a string, which is what lets
/// PyYAML leave it unquoted. Mirrors `Resolver.resolve` for the `str` tag.
fn plain_is_string(ch : Array[Char]) -> Bool {
  if matches_yaml_null(ch) ||
    matches_yaml_bool(ch) ||
    matches_yaml_int(ch) ||
    matches_yaml_float(ch) ||
    matches_yaml_timestamp(ch) {
    return false
  }
  let word = String::from_array(ch[:])
  word != "<<" && word != "="
}

///|
fn hex_digit(value : Int32) -> Char {
  if value < 10 {
    (value + 48).unsafe_to_char()
  } else {
    (value + 55).unsafe_to_char()
  }
}

///|
fn hex_pad(value : Int32, width : Int32) -> String {
  let mut out = ""
  let mut shift = (width - 1) * 4
  while shift >= 0 {
    out += hex_digit((value >> shift) & 0xF).to_string()
    shift -= 4
  }
  out
}

///|
/// Escape one character for a double-quoted scalar: PyYAML's
/// `ESCAPE_REPLACEMENTS`, then `\xNN` / `\uNNNN` / `\UNNNNNNNN`.
fn escape_yaml_char(c : Char) -> String {
  match c {
    '\u{0}' => "\\0"
    '\u{7}' => "\\a"
    '\u{8}' => "\\b"
    '\t' => "\\t"
    '\n' => "\\n"
    '\u{B}' => "\\v"
    '\u{C}' => "\\f"
    '\r' => "\\r"
    '\u{1B}' => "\\e"
    '"' => "\\\""
    '\\' => "\\\\"
    '\u{85}' => "\\N"
    '\u{A0}' => "\\_"
    '\u{2028}' => "\\L"
    '\u{2029}' => "\\P"
    _ => {
      let code = c.to_int()
      if code <= 0xFF {
        "\\x" + hex_pad(code, 2)
      } else if code <= 0xFFFF {
        "\\u" + hex_pad(code, 4)
      } else {
        "\\U" + hex_pad(code, 8)
      }
    }
  }
}

///|
fn yaml_slice(ch : Array[Char], start : Int32, end : Int32) -> String {
  String::from_array(ch.exact_view(start~, end~))
}

///|
/// Port of `Emitter.write_plain`.
fn PyYamlEmitter::write_plain(
  self : PyYamlEmitter,
  ch : Array[Char],
  split : Bool,
) -> Unit {
  let n = ch.length()
  if n == 0 {
    return
  }
  if !self.whitespace {
    self.raw(" ")
  }
  self.whitespace = false
  self.indention = false
  let mut spaces = false
  let mut start = 0
  let mut end = 0
  while end <= n {
    let current : Char? = if end < n { Some(ch[end]) } else { None }
    if spaces {
      if current != Some(' ') {
        if start + 1 == end && self.column > YAML_WIDTH && split {
          self.indent_to()
          self.whitespace = false
          self.indention = false
        } else {
          self.raw(yaml_slice(ch, start, end))
        }
        start = end
      }
    } else if current == None || current == Some(' ') {
      if start < end {
        self.raw(yaml_slice(ch, start, end))
      }
      start = end
    }
    if current != None {
      spaces = current == Some(' ')
    }
    end += 1
  }
  // A plain scalar as a whole document would need `...` to end it.
  if self.root_context {
    self.open_ended = true
  }
}

///|
/// Port of `Emitter.write_single_quoted`, including its habit of writing one
/// line break per input break and then another one for the run itself.
fn PyYamlEmitter::write_single_quoted(
  self : PyYamlEmitter,
  ch : Array[Char],
  split : Bool,
) -> Unit {
  let n = ch.length()
  self.indicator("'", true)
  let mut spaces = false
  let mut breaks = false
  let mut start = 0
  let mut end = 0
  while end <= n {
    let current : Char? = if end < n { Some(ch[end]) } else { None }
    let is_current_break = match current {
      Some(c) => is_yaml_break(c)
      None => false
    }
    if spaces {
      if current != Some(' ') {
        if start + 1 == end &&
          self.column > YAML_WIDTH &&
          split &&
          start != 0 &&
          end != n {
          self.indent_to()
        } else {
          self.raw(yaml_slice(ch, start, end))
        }
        start = end
      }
    } else if breaks {
      if !is_current_break {
        if ch[start] == '\n' {
          self.line_break()
        }
        for index in start..<end {
          if ch[index] == '\n' {
            self.line_break()
          } else {
            self.whitespace = true
            self.indention = true
            self.column = 0
            self.raw_char(ch[index])
          }
        }
        self.indent_to()
        start = end
      }
    } else if current == None ||
      current == Some(' ') ||
      is_current_break ||
      current == Some('\'') {
      if start < end {
        self.raw(yaml_slice(ch, start, end))
        start = end
      }
    }
    if current == Some('\'') {
      self.raw("''")
      start = end + 1
    }
    if current != None {
      spaces = current == Some(' ')
      breaks = is_current_break
    }
    end += 1
  }
  self.indicator("'", false)
}

///|
/// Port of `Emitter.write_double_quoted`.
fn PyYamlEmitter::write_double_quoted(
  self : PyYamlEmitter,
  ch : Array[Char],
  split : Bool,
) -> Unit {
  let n = ch.length()
  self.indicator("\"", true)
  let mut start = 0
  let mut end = 0
  while end <= n {
    let current : Char? = if end < n { Some(ch[end]) } else { None }
    let must_escape = match current {
      None => true
      Some(c) =>
        c == '"' ||
        c == '\\' ||
        c == '\u{85}' ||
        c == '\u{2028}' ||
        c == '\u{2029}' ||
        c == '\u{FEFF}' ||
        !(c >= '\u{20}' && c <= '\u{7E}')
    }
    if must_escape {
      if start < end {
        self.raw(yaml_slice(ch, start, end))
        start = end
      }
      match current {
        Some(c) => {
          self.raw(escape_yaml_char(c))
          start = end + 1
        }
        None => ()
      }
    }
    if 0 < end &&
      end < n - 1 &&
      (current == Some(' ') || start >= end) &&
      self.column + (end - start) > YAML_WIDTH &&
      split {
      let data = yaml_slice(ch, start, end) + "\\"
      if start < end {
        start = end
      }
      self.raw(data)
      self.indent_to()
      self.whitespace = false
      self.indention = false
      if ch[start] == ' ' {
        self.raw("\\")
      }
    }
    end += 1
  }
  self.indicator("\"", false)
}

///|
/// Which quoting PyYAML picks for a scalar with no explicit style.
priv enum ScalarStyle {
  Plain
  Single
  Double
}

///|
/// Port of `Emitter.choose_scalar_style` for `style is None`, plus the indent
/// bump and restore that `expect_scalar` does around writing a value.
fn PyYamlEmitter::write_scalar(
  self : PyYamlEmitter,
  ch : Array[Char],
  plain_ok : Bool,
  simple_key_context : Bool,
) -> Unit {
  let analysis = analyze_scalar(ch)
  let style = if plain_ok &&
    !(simple_key_context && (analysis.empty || analysis.multiline)) &&
    analysis.allow_block_plain {
    Plain
  } else if analysis.allow_single_quoted &&
    !(simple_key_context && analysis.multiline) {
    Single
  } else {
    Double
  }
  let split = !simple_key_context
  let saved = self.push_indent(flow=true)
  match style {
    Plain => self.write_plain(ch, split)
    Single => self.write_single_quoted(ch, split)
    Double => self.write_double_quoted(ch, split)
  }
  self.indent = saved
}

///|
/// PyYAML writes floats as `repr(value)`, lowercased, with `.0` inserted when
/// the exponent carries no decimal point of its own.
fn yaml_float_repr(value : Double) -> String {
  if value.is_nan() {
    return ".nan"
  }
  if value.is_pos_inf() {
    return ".inf"
  }
  if value.is_neg_inf() {
    return "-.inf"
  }
  if value == 0.0 {
    // MoonBit prints `-0.0` as `0`; Python keeps the sign in `repr`.
    return if value.reinterpret_as_uint64() >> 63 == 1 { "-0.0" } else { "0.0" }
  }
  let raw = value.to_string()
  let mut text = ""
  let mut has_dot = false
  let mut has_exponent = false
  let mut exponent_at = -1
  for c in raw {
    if c == '.' {
      has_dot = true
    }
    if c == 'e' || c == 'E' {
      has_exponent = true
      exponent_at = text.length()
    }
    if c >= 'A' && c <= 'Z' {
      text += (c.to_int() + 32).unsafe_to_char().to_string()
    } else {
      text += c.to_string()
    }
  }
  let mut mantissa = text
  let mut exponent = ""
  if has_exponent {
    mantissa = text[:exponent_at].to_owned()
    exponent = text[exponent_at:].to_owned()
  }
  if !has_dot {
    mantissa += ".0"
  }
  if !has_exponent {
    return mantissa
  }
  // Python pads the exponent to two digits and always writes its sign.
  let digits = exponent[1:].to_owned()
  let sign = if digits.length() > 0 && (digits[0] == '-' || digits[0] == '+') {
    digits[:1].to_owned()
  } else {
    "+"
  }
  let number = if sign == "+" { digits } else { digits[1:].to_owned() }
  let padded = if number.length() < 2 { "0" + number } else { number }
  mantissa + "e" + sign + padded
}

///|
/// The text PyYAML writes for a scalar, plus whether the plain form would read
/// back as the same tag (PyYAML's `event.implicit[0]`).
fn scalar_text(v : @yaml.Yaml) -> (Array[Char], Bool) {
  match v {
    @yaml.Yaml::String(s) => {
      let ch = s.to_array()
      (ch, plain_is_string(ch))
    }
    @yaml.Yaml::Integer(i) => {
      let ch = i.to_string().to_array()
      (ch, !plain_is_string(ch))
    }
    @yaml.Yaml::Boolean(b) => {
      let ch = (if b { "true" } else { "false" }).to_array()
      (ch, !plain_is_string(ch))
    }
    @yaml.Yaml::Real(d, ..) => {
      let ch = yaml_float_repr(d).to_array()
      (ch, !plain_is_string(ch))
    }
    @yaml.Yaml::Null | @yaml.Yaml::BadValue => {
      let ch = "null".to_array()
      (ch, !plain_is_string(ch))
    }
    _ => {
      let ch = "null".to_array()
      (ch, !plain_is_string(ch))
    }
  }
}

///|
fn PyYamlEmitter::dump_scalar(
  self : PyYamlEmitter,
  v : @yaml.Yaml,
  simple_key_context : Bool,
) -> Unit {
  let (ch, plain_ok) = scalar_text(v)
  self.write_scalar(ch, plain_ok, simple_key_context)
}

///|
/// Port of `Emitter.check_simple_key`: a key needs the explicit `?` form when
/// it spans lines or is longer than 128 characters.
fn is_simple_yaml_key(ch : Array[Char]) -> Bool {
  !analyze_scalar(ch).multiline && ch.length() <= 128
}

///|
/// Port of `Emitter.expect_flow_sequence`/`expect_flow_mapping` for the only
/// flow-style nodes PyYAML emits with `default_flow_style=False`: empty ones.
fn PyYamlEmitter::dump_empty_flow(
  self : PyYamlEmitter,
  open_ : String,
  close : String,
) -> Unit {
  self.indicator(open_, true, whitespace=true)
  self.indicator(close, false)
}

///|
/// Port of `Emitter.expect_block_sequence`.
fn PyYamlEmitter::dump_sequence(
  self : PyYamlEmitter,
  items : Array[@yaml.Yaml],
  mapping_context : Bool,
) -> Unit {
  let indentless = mapping_context && !self.indention
  let saved = self.push_indent(indentless~)
  for item in items {
    self.indent_to()
    self.indicator("-", true, indention=true)
    self.dump_node(item, false)
  }
  self.indent = saved
}

///|
/// Keys in the order `yaml.safe_dump` writes them. `lexical_compare` compares
/// UTF-16 code units, which matches Python's code point order for the ASCII
/// keys compose files use.
fn sorted_yaml_keys(m : Map[String, @yaml.Yaml]) -> Array[String] {
  let keys : Array[String] = []
  for key in m.keys() {
    keys.push(key)
  }
  keys.sort_by(fn(a, b) { a.lexical_compare(b) })
  keys
}

///|
/// Port of `Emitter.expect_block_mapping`.
fn PyYamlEmitter::dump_mapping(
  self : PyYamlEmitter,
  m : Map[String, @yaml.Yaml],
) -> Unit {
  let saved = self.push_indent()
  for key in sorted_yaml_keys(m) {
    let key_ch = key.to_array()
    // `expect_block_mapping_key` calls `expect_node(simple_key=True)`, which
    // clears `root_context`; a key is never the document root.
    self.root_context = false
    self.indent_to()
    if is_simple_yaml_key(key_ch) {
      self.write_scalar(key_ch, plain_is_string(key_ch), true)
      self.indicator(":", false)
    } else {
      self.indicator("?", true, indention=true)
      self.write_scalar(key_ch, plain_is_string(key_ch), true)
      self.indent_to()
      self.indicator(":", true, indention=true)
    }
    match m.get(key) {
      Some(value) => self.dump_node(value, true)
      None => self.dump_scalar(@yaml.Yaml::Null, false)
    }
  }
  self.indent = saved
}

///|
/// Port of `Emitter.expect_node` for the block styles.
fn PyYamlEmitter::dump_node(
  self : PyYamlEmitter,
  v : @yaml.Yaml,
  mapping_context : Bool,
  root~ : Bool = false,
) -> Unit {
  self.root_context = root
  match v {
    @yaml.Yaml::Map(m) =>
      if m.length() == 0 {
        self.dump_empty_flow("{", "}")
      } else {
        self.dump_mapping(m)
      }
    @yaml.Yaml::Array(items) =>
      if items.length() == 0 {
        self.dump_empty_flow("[", "]")
      } else {
        self.dump_sequence(items, mapping_context)
      }
    _ => self.dump_scalar(v, false)
  }
}

///|
/// Render a value the way `yaml.safe_dump` does, trailing newline included.
///
/// `config` prints the result with `println`, which adds the second newline
/// the reference's `print(compose.merged_yaml)` also produces.
pub fn y_dump(v : @yaml.Yaml) -> String {
  let emitter = PyYamlEmitter::new()
  emitter.dump_node(v, false, root=true)
  emitter.indent_to()
  if emitter.open_ended {
    emitter.indicator("...", true)
    emitter.indent_to()
  }
  emitter.out.to_string()
}
