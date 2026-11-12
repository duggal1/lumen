#!/usr/bin/env python3
"""Generate lenient Decodable initialisers for tool input and script types.

Swift's synthesised decoder treats every non-optional property as required,
even when it has a default value. An agent omits the arguments it does not
care about, so every tool input has to tolerate missing keys. This script
rewrites the affected structs with an explicit `init(from:)` that decodes
each property with `decodeIfPresent(...) ?? default`, plus snake_case
coding keys.
"""
import re
import sys

DEFAULT_TYPE = {
    "String": "String.self",
    "Int": "Int.self",
    "Double": "Double.self",
    "Bool": "Bool.self",
    "[String]": "[String].self",
    "[String: Bool]": "[String: Bool].self",
    "PatchOp": "PatchOp.self",
    "[PatchOp]": "[PatchOp].self",

    "DemoScript": "DemoScript.self",
    "DemoScript.Target": "DemoScript.Target.self",
    "[DemoScript.Action]": "[DemoScript.Action].self",
    "TargetRef": "TargetRef.self",
}


def snake(name):
    out = ""
    for index, character in enumerate(name):
        if character.isupper():
            if index > 0 and not name[index - 1].isupper():
                out += "_"
            out += character.lower()
        else:
            out += character
    return out


def parse_structs(source):
    """Returns [(name, indent, start, end, body)] for every public struct."""
    structs = []
    pattern = re.compile(r"( *)public struct (\w+)\s*:\s*([^{\n]+)\{")
    for match in pattern.finditer(source):
        index = match.end()
        depth = 1
        while index < len(source) and depth > 0:
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
            index += 1
        structs.append((match.group(2), match.group(1), match.start(), index,
                        source[match.end():index - 1], match.group(3),
                        source[match.start():match.end() - 1]))
    return structs


def properties(body):
    """Direct properties only: nested types have their own properties."""
    found = []
    depth = 0
    for line in body.split("\n"):
        match = re.match(r"\s*public var (\w+)\s*:\s*([^=]+?)\s*(?:=\s*(.+))?$", line)
        if match and depth == 0:
            name, kind, default = match.group(1), match.group(2).strip(), match.group(3)
            found.append((name, kind, default))
        depth += line.count("{") - line.count("}")
    return found


def process(path):
    source = open(path).read()
    # One struct at a time: rewriting shifts every later offset.
    while True:
        structs = parse_structs(source)
        target = None
        # The last one first: rewriting shifts every later offset.
        for name, indent, start, end, body, declaration, header in reversed(structs):
            if "init(from decoder" in body:
                continue
            if "Codable" not in declaration and "ToolInput" not in declaration:
                continue
            if not properties(body):
                continue
            target = (name, indent, start, end, body, declaration, header)
            break
        if target is None:
            break
        name, indent, start, end, body, declaration, header = target
        props = properties(body)
        lines = []
        keys = []
        for prop, kind, default in props:
            snake_name = snake(prop)
            keys.append(f"{indent}    case {prop}" + (f' = "{snake_name}"' if snake_name != prop else ""))
            decoded = kind
            optional = decoded.endswith("?")
            base = decoded[:-1] if optional else decoded
            swift_type = DEFAULT_TYPE.get(base)
            if swift_type is None:
                swift_type = "AnyCodableValue.self"  # unsupported, flagged below
            fallback = "nil" if optional else (default if default else "nil")
            if optional:
                lines.append(f"{indent}    self.{prop} = try c.decodeIfPresent({swift_type}, forKey: .{prop})")
            else:
                lines.append(f"{indent}    self.{prop} = try c.decodeIfPresent({swift_type}, forKey: .{prop}) ?? {fallback}")
        coding = []
        if "enum CodingKeys" not in body:
            coding = [f"{indent}    enum CodingKeys: String, CodingKey {{"] + keys + [f"{indent}    }}"]
        init_lines = [f"{indent}    public init(from decoder: Decoder) throws {{",
                      f"{indent}        let c = try decoder.container(keyedBy: CodingKeys.self)"] + lines + \
                     [f"{indent}    }}"]
        new_body = body.rstrip() + "\n\n" + "\n".join(coding + init_lines) + "\n"
        source = source[:start] + header + "{" + new_body + source[end - 1:]
    open(path, "w").write(source)
    print("rewrote", path)


for target in sys.argv[1:]:
    process(target)
