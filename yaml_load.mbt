///|
/// Load YAML the way PyYAML's `safe_load` does.
///
/// The `yaml` package resolves plain scalars with MoonBit's `parse_int64` and
/// `parse_double`, which disagree with PyYAML about inputs that are common in
/// compose files (`yes`, `on`, `1_000`, `12:30`) and about ones that are not
/// (`08`, `0o7`, `1e3`, `1.0e16`). `config` prints `yaml.safe_dump` of the
/// loaded model, so the model has to agree with PyYAML's before the emitter
/// can.
///
/// The package exposes `Parser` and its events, so only the constructor — the
/// `Scalar` event to value step — is replaced here. The lexer, the parser and
/// the emitter of the package are still used as they are.
///
/// Three deliberate differences remain:
///
///   * an unquoted timestamp (`2024-01-01`) becomes a `datetime.date` in
///     PyYAML and then makes `podman-compose config` die in `json.dumps`, so
///     there is no output to match; we keep it a string;
///   * a non-string mapping key is an error here, since the compose schema
///     only has string keys;
///   * an integer beyond `Int64` keeps its exact digits but is a string in the
///     model, so the emitter quotes it (`'9223372036854775808'`) where
///     PyYAML's unbounded `int()` prints it plain. The digits are what matter
///     for a compose file; `Yaml` has no wider integer to hold them.

///|
/// Load every document in `source`, with PyYAML's scalar rules.
pub fn load_yaml_documents(
  source : StringView,
) -> Array[@yaml.Yaml] raise Error {
  let parser = @yaml.Parser::new(source)
  let receiver : PyYamlConstructor = {
    docs: [],
    stack: [],
    keys: [],
    anchors: Map([]),
    error: None,
  }
  parser.load(receiver, true) catch {
    e => raise fail("YAML parse error: \{error_text(e)}")
  }
  match receiver.error {
    Some(message) => raise fail(message)
    None => receiver.docs
  }
}

///|
/// What a plain `<<` key becomes in the constructed tree. PyYAML tags it
/// `tag:yaml.org,2002:merge` and expands it while constructing the mapping, but
/// a quoted `"<<"` is an ordinary key, and the tag is gone once a scalar has
/// become a `String`. Marking the key keeps the two apart; `merge.mbt`
/// consumes the marker, so it never reaches the emitter. A NUL byte cannot
/// appear in a YAML key, since the reader rejects control characters.
fn merge_key_marker() -> String {
  "\u{0}<<"
}

///|
/// Whether a scalar event carries PyYAML's merge tag: a plain, untagged `<<`.
fn is_merge_scalar(
  value : String,
  style : @yaml.TScalarStyle,
  tag : @yaml.Tag?,
) -> Bool {
  if value != "<<" || explicit_yaml_tag(tag) is Some(_) {
    return false
  }
  match style {
    @yaml.TScalarStyle::Plain => true
    _ => false
  }
}

///|
priv struct PyYamlConstructor {
  docs : Array[@yaml.Yaml]
  stack : Array[(@yaml.Yaml, Int32)]
  /// One slot per open mapping: `None` while the key is still expected, which
  /// is what lets an empty string be a key.
  keys : Array[String?]
  anchors : Map[Int32, @yaml.Yaml]
  mut error : String?
}

///|
impl @yaml.MarkedEventReceiver for PyYamlConstructor with fn on_event(
  self,
  event,
  mark,
) {
  if self.error is Some(_) {
    return
  }
  self.handle(event, mark) catch {
    e => self.error = Some(error_text(e))
  }
}

///|
fn PyYamlConstructor::handle(
  self : PyYamlConstructor,
  event : @yaml.Event,
  mark : @yaml.Marker,
) -> Unit raise Error {
  match event {
    @yaml.Event::StreamStart
    | @yaml.Event::StreamEnd
    | @yaml.Event::DocumentStart => ()
    @yaml.Event::DocumentEnd =>
      match self.stack.length() {
        0 => self.docs.push(@yaml.Yaml::BadValue)
        1 => self.docs.push(self.stack.pop().unwrap().0)
        _ => raise fail("unbalanced YAML document")
      }
    @yaml.Event::SequenceStart(id~, ..) =>
      self.stack.push((@yaml.Yaml::Array([]), id))
    @yaml.Event::SequenceEnd => {
      let node = self.stack.pop().unwrap()
      self.insert(node, mark)
    }
    @yaml.Event::MappingStart(id~, ..) => {
      self.stack.push((@yaml.Yaml::Map(Map([])), id))
      self.keys.push(None)
    }
    @yaml.Event::MappingEnd => {
      if self.keys.pop() is None {
        raise fail("unbalanced YAML mapping")
      }
      let node = self.stack.pop().unwrap()
      self.insert(node, mark)
    }
    @yaml.Event::Scalar(value~, style~, id~, tag~) => {
      let node = construct_yaml_scalar(value, style, tag)
      self.insert((node, id), mark, merge=is_merge_scalar(value, style, tag))
    }
    @yaml.Event::Alias(id~) =>
      match self.anchors.get(id) {
        Some(node) => self.insert((node, 0), mark)
        None => raise fail("unknown YAML anchor \{id}")
      }
  }
}

///|
fn PyYamlConstructor::insert(
  self : PyYamlConstructor,
  node : (@yaml.Yaml, Int32),
  mark : @yaml.Marker,
  merge~ : Bool = false,
) -> Unit raise Error {
  if node.1 > 0 {
    self.anchors[node.1] = node.0
  }
  if self.stack.is_empty() {
    self.stack.push(node)
    return
  }
  let parent = self.stack.last().unwrap()
  match parent {
    (@yaml.Yaml::Array(items), _) => items.push(node.0)
    (@yaml.Yaml::Map(m), _) => {
      let slot = self.keys.last().unwrap()
      match slot {
        None =>
          // This node is the key of the mapping.
          match node.0 {
            @yaml.Yaml::String(key) =>
              self.keys[self.keys.length() - 1] = Some(
                if merge {
                  merge_key_marker()
                } else {
                  key
                },
              )
            _ =>
              raise fail(
                "non-string mapping key at line \{mark.line + 1}, column \{mark.col + 1}",
              )
          }
        Some(key) => {
          self.keys[self.keys.length() - 1] = None
          // PyYAML's constructor keeps the last value for a repeated key.
          m[key] = node.0
        }
      }
    }
    _ => raise fail("malformed YAML document")
  }
}

///|
/// PyYAML's tag for the `yaml.org` implicit resolvers, when one is written out
/// explicitly (`!!int 5`).
fn explicit_yaml_tag(tag : @yaml.Tag?) -> String? {
  match tag {
    Some(t) if t.handle == "tag:yaml.org,2002:" => Some(t.suffix)
    _ => None
  }
}

///|
/// Port of the composer's `compose_scalar_node` plus the constructors
/// `SafeConstructor` dispatches to.
fn construct_yaml_scalar(
  value : String,
  style : @yaml.TScalarStyle,
  tag : @yaml.Tag?,
) -> @yaml.Yaml {
  match explicit_yaml_tag(tag) {
    Some("bool") => construct_yaml_bool(value)
    Some("int") => construct_yaml_int(value)
    Some("float") => construct_yaml_float(value)
    Some("null") => @yaml.Yaml::Null
    Some(_) => @yaml.Yaml::String(value)
    // No explicit tag: only a plain scalar is resolved, a quoted one is
    // always a string.
    None =>
      match style {
        @yaml.TScalarStyle::Plain => resolve_plain_scalar(value)
        _ => @yaml.Yaml::String(value)
      }
  }
}

///|
/// The implicit resolver table from `yaml/resolver.py`, in the order PyYAML
/// registers the resolvers. The tags are disjoint for these patterns, so the
/// order only matters for readability.
fn resolve_plain_scalar(value : String) -> @yaml.Yaml {
  let ch = value.to_array()
  if matches_yaml_bool(ch) {
    construct_yaml_bool(value)
  } else if matches_yaml_int(ch) {
    construct_yaml_int(value)
  } else if matches_yaml_float(ch) {
    construct_yaml_float(value)
  } else if matches_yaml_null(ch) {
    @yaml.Yaml::Null
  } else {
    // `<<`, `=`, a timestamp, or an ordinary string. PyYAML turns `<<` into a
    // merge and a timestamp into a `datetime`, which `merge.mbt` and the note
    // at the top of this file cover.
    @yaml.Yaml::String(value)
  }
}

///|
fn construct_yaml_bool(value : String) -> @yaml.Yaml {
  match value {
    "yes" | "Yes" | "YES" | "true" | "True" | "TRUE" | "on" | "On" | "ON" =>
      @yaml.Yaml::Boolean(true)
    _ => @yaml.Yaml::Boolean(false)
  }
}

///|
/// Parse a signed integer in `base`, or `None` when it does not fit.
fn parse_yaml_int(text : StringView, base : Int32) -> Int64? {
  Some(@string.parse_int64(text, base~)) catch {
    _ => None
  }
}

///|
/// A non-negative integer as base 10^9 limbs, little-endian.
///
/// PyYAML's `int()` is unbounded, so an integer literal too large for an
/// `Int64` still has to print as the decimal text `yaml.safe_dump` produces.
/// The limbs keep every intermediate product below 2^63.
priv struct BigInt {
  limbs : Array[Int64]
}

///|
const BIGINT_BASE : Int64 = 1000000000

///|
fn BigInt::new() -> BigInt {
  { limbs: [0], }
}

///|
/// `self = self * mul + add`.
fn BigInt::mul_add(self : BigInt, mul : Int64, add : Int64) -> Unit {
  let mut carry = add
  for i in 0..<self.limbs.length() {
    let product = self.limbs[i] * mul + carry
    self.limbs[i] = product % BIGINT_BASE
    carry = product / BIGINT_BASE
  }
  while carry > 0 {
    self.limbs.push(carry % BIGINT_BASE)
    carry /= BIGINT_BASE
  }
}

///|
/// `self = self + other`.
fn BigInt::add(self : BigInt, other : BigInt) -> Unit {
  let mut carry : Int64 = 0
  let mut index = 0
  while index < other.limbs.length() {
    if index >= self.limbs.length() {
      self.limbs.push(0)
    }
    let sum = self.limbs[index] + other.limbs[index] + carry
    self.limbs[index] = sum % BIGINT_BASE
    carry = sum / BIGINT_BASE
    index += 1
  }
  while carry > 0 {
    if index >= self.limbs.length() {
      self.limbs.push(0)
    }
    let sum = self.limbs[index] + carry
    self.limbs[index] = sum % BIGINT_BASE
    carry = sum / BIGINT_BASE
    index += 1
  }
}

///|
/// The value of a digit of any base PyYAML accepts. The resolver patterns
/// guarantee a valid digit, so anything else counts as zero.
fn yaml_digit_value(c : Char) -> Int64 {
  if c >= '0' && c <= '9' {
    (c.to_int() - 48).to_int64()
  } else if c >= 'a' && c <= 'f' {
    (c.to_int() - 87).to_int64()
  } else if c >= 'A' && c <= 'F' {
    (c.to_int() - 55).to_int64()
  } else {
    0
  }
}

///|
fn BigInt::from_digits(text : StringView, base : Int64) -> BigInt {
  let out = BigInt::new()
  for c in text {
    out.mul_add(base, yaml_digit_value(c))
  }
  out
}

///|
fn BigInt::to_decimal(self : BigInt) -> String {
  let mut end = self.limbs.length()
  while end > 1 && self.limbs[end - 1] == 0 {
    end -= 1
  }
  let out = StringBuilder()
  out.write_string(self.limbs[end - 1].to_string())
  let mut index = end - 1
  while index > 0 {
    index -= 1
    let text = self.limbs[index].to_string()
    out.write_string(String::make(9 - text.length(), '0'))
    out.write_string(text)
  }
  out.to_string()
}

///|
/// `parse_double` rejects a value outside the range of a `Double`, while
/// Python's `float()` rounds it to infinity (`1.8e+308` is `.inf`) or to zero
/// (`1e-999`). Rebuild the value digit by digit in that case, so the overflow
/// happens in the arithmetic. Values in range never reach this path.
fn parse_yaml_float(text : StringView) -> Double {
  @string.parse_double(text) catch {
    _ => decimal_to_double(text)
  }
}

///|
fn decimal_to_double(text : StringView) -> Double {
  let ch = text.to_array()
  let mut index = 0
  let mut negative = false
  if index < ch.length() && (ch[index] == '+' || ch[index] == '-') {
    negative = ch[index] == '-'
    index += 1
  }
  let mut mantissa = 0.0
  let mut exponent = 0
  let mut seen_dot = false
  while index < ch.length() && ch[index] != 'e' && ch[index] != 'E' {
    let c = ch[index]
    if c >= '0' && c <= '9' {
      mantissa = mantissa * 10.0 + (c.to_int() - 48).to_double()
      if seen_dot {
        exponent -= 1
      }
    } else if c == '.' {
      seen_dot = true
    } else if c != '_' {
      // Not a number at all.
      return 0.0
    }
    index += 1
  }
  if index < ch.length() {
    index += 1
    let mut exp_negative = false
    if index < ch.length() && (ch[index] == '+' || ch[index] == '-') {
      exp_negative = ch[index] == '-'
      index += 1
    }
    let mut magnitude = 0
    while index < ch.length() {
      let c = ch[index]
      if c < '0' || c > '9' {
        return 0.0
      }
      magnitude = magnitude * 10 + (c.to_int() - 48)
      index += 1
    }
    // A huge exponent only has to reach the overflow point, so the loop is cut
    // short once the value can no longer change.
    if magnitude > 100000 {
      magnitude = 100000
    }
    exponent += if exp_negative { -magnitude } else { magnitude }
  }
  let mut remaining = if exponent < 0 { -exponent } else { exponent }
  while remaining > 0 &&
        !mantissa.is_inf() &&
        !mantissa.is_nan() &&
        mantissa != 0.0 {
    if exponent > 0 {
      mantissa *= 10.0
    } else {
      mantissa /= 10.0
    }
    remaining -= 1
  }
  if negative {
    -mantissa
  } else {
    mantissa
  }
}

///|
/// Port of `SafeConstructor.construct_yaml_int`: the base prefixes and the
/// sexagesimal form PyYAML accepts but YAML 1.2 does not.
///
/// PyYAML parses through Python's unbounded `int()`. An integer that does not
/// fit in an `Int64` becomes its exact decimal text instead, which the emitter
/// writes back unquoted, so `config` still matches.
fn construct_yaml_int(value : String) -> @yaml.Yaml {
  let cleaned = value.replace_all(old="_", new="")
  let mut text = cleaned
  let mut negative = false
  if text.length() > 0 && (text[0] == '+' || text[0] == '-') {
    negative = text[0] == '-'
    text = text[1:].to_owned()
  }
  let magnitude = if text.contains(":") {
    let total = BigInt::new()
    for part in text.split(":") {
      total.mul_add(60, 0)
      total.add(BigInt::from_digits(part, 10))
    }
    total
  } else if text.has_prefix("0b") {
    BigInt::from_digits(text[2:], 2)
  } else if text.has_prefix("0x") {
    BigInt::from_digits(text[2:], 16)
  } else if text.length() > 0 && text[0] == '0' {
    BigInt::from_digits(text, 8)
  } else {
    BigInt::from_digits(text, 10)
  }
  let decimal = magnitude.to_decimal()
  let signed = if negative { "-" + decimal } else { decimal }
  match parse_yaml_int(signed, 10) {
    Some(number) => @yaml.Yaml::Integer(number)
    None => @yaml.Yaml::String(signed)
  }
}

///|
/// Port of `SafeConstructor.construct_yaml_float`. The `repr` keeps the source
/// text, like the package's own loader, but the emitter formats from the value.
fn construct_yaml_float(value : String) -> @yaml.Yaml {
  let cleaned = ascii_lower(value.replace_all(old="_", new=""))
  let mut text = cleaned
  let mut negative = false
  if text.length() > 0 && (text[0] == '+' || text[0] == '-') {
    negative = text[0] == '-'
    text = text[1:].to_owned()
  }
  let magnitude : Double = if text == ".inf" {
    @double.infinity
  } else if text == ".nan" {
    @double.not_a_number
  } else if text.contains(":") {
    let parts = text.split(":").to_array()
    let mut total : Double = 0.0
    let mut base : Double = 1.0
    for index in 0..<parts.length() {
      total += parse_yaml_float(parts[parts.length() - 1 - index]) * base
      base *= 60.0
    }
    total
  } else {
    parse_yaml_float(text)
  }
  @yaml.Yaml::Real(if negative { -magnitude } else { magnitude }, repr=value)
}
