package tag

import "core:fmt"
import "core:os"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:mem"
import "core:strings"

Source_Loc :: struct {
    file: string,
    line: int,
    column: int,
    offset: int
}

Tag_Info :: struct {
    value: string,
    decl: string,
    decl_kind: string,
    tag_loc: Source_Loc,
    target_loc: Source_Loc,
    target_end_loc: Source_Loc
}

loc_from_pos :: proc(pos: tokenizer.Pos) -> Source_Loc {
    return {
        file = strings.clone(pos.file, context.temp_allocator),
        line = pos.line + 1,
        column = pos.column,
        offset = pos.offset
    }
}

extract_tags :: proc(
    attrs: []^ast.Attribute,
    decl: string,
    decl_kind: string,
    target_pos: tokenizer.Pos,
    target_end: tokenizer.Pos,
    results: ^[dynamic]Tag_Info
) {
    for attr in attrs {
        if attr == nil do continue

        for elem in attr.elems {
            if elem == nil do continue

            field_value, is_field := elem.derived_expr.(^ast.Field_Value)
            if !is_field do continue

            if field_value.field == nil || field_value.value == nil {
                continue
            }

            ident, is_ident := field_value.field.derived_expr.(^ast.Ident)
            if !is_ident || ident.name != "tag" {
                continue
            }

            lit, is_lit := field_value.value.derived_expr.(^ast.Basic_Lit)
            if !is_lit || lit.tok.kind != .String {
                continue
            }

            raw := lit.tok.text

            if len(raw) < 2 do continue

            value := raw[1:len(raw)-1]

            append(results, Tag_Info{
                value = strings.clone(value, context.temp_allocator),
                decl = strings.clone(decl, context.temp_allocator),
                decl_kind = decl_kind, // always a string literal
                tag_loc = loc_from_pos(ident.pos),
                target_loc = loc_from_pos(target_pos),
                target_end_loc = loc_from_pos(target_end)
            })
        }
    }
}

Scanner :: struct {
    results: [dynamic]Tag_Info,
}

scanner_init :: proc(self: ^Scanner, allocator := context.allocator) -> (err: mem.Allocator_Error) {
    self.results = make([dynamic]Tag_Info, allocator=allocator) or_return
    return
}

make_scanner :: proc(allocator := context.allocator) -> (self: Scanner, err: mem.Allocator_Error) #optional_allocator_error {
    scanner_init(&self, allocator=allocator) or_return
    return
}

delete_scanner :: proc(self: ^Scanner) -> (err: mem.Allocator_Error) {
    delete(self.results) or_return
    return
}

visit_node :: proc(
    visitor: ^ast.Visitor,
    node: ^ast.Node
) -> ^ast.Visitor {
    if node == nil do return visitor

    scanner := cast(^Scanner)visitor.data

    #partial switch n in node.derived {
        case ^ast.Value_Decl:
            for name_expr in n.names {
                if name_expr == nil do continue

                ident, ok := name_expr.derived_expr.(^ast.Ident)
                if !ok do continue

                kind := "value"

                if !n.is_mutable {
                    kind = "constant"
                }

                if len(n.values) > 0 {
                    value := n.values[0]

                    if value != nil {
                        #partial switch _ in value.derived_expr {
                            case ^ast.Struct_Type:
                                kind = "struct"
                            case ^ast.Union_Type:
                                kind = "union"
                            case ^ast.Enum_Type:
                                kind = "enum"
                            case ^ast.Proc_Lit:
                                kind = "procedure"
                            case:
                        }
                    }
                }

                extract_tags(n.attributes[:], ident.name, kind, ident.pos, n.end, &scanner.results)
            }

        case ^ast.Foreign_Block_Decl:
            extract_tags(n.attributes[:], "<foreign block>", "foreign_block", n.pos, n.end, &scanner.results)

        case ^ast.Foreign_Import_Decl:
            name := "<foreign import>"
            target_pos := n.pos
            target_end := n.end

            if n.name != nil {
                name = n.name.name
                target_pos = n.name.pos
                target_end = n.name.end
            }

            extract_tags(n.attributes[:], name, "foreign_import", target_pos, target_end, &scanner.results)

        case:
    }

    return visitor
}

General_Scanner_Error :: enum u8 {
    None,
    Failed_To_Parse_File
}

Scanner_Error :: union #shared_nil {
    os.Error,
    General_Scanner_Error
}

scan_file_obj_with_path :: proc(file: ^os.File, path: string, scanner: ^Scanner) -> (err: Scanner_Error) {
    allocator := context.allocator
    data := os.read_entire_file(file, allocator) or_return
    defer delete(data, allocator)

    // AST nodes are only needed during this scan; tags are cloned out of them
    context.allocator = context.temp_allocator

    file := ast.File{ fullpath=path, src=string(data) }

    p := parser.default_parser()
    if !parser.parse_file(&p, &file) {
        return .Failed_To_Parse_File
    }

    visitor := ast.Visitor{
        visit=visit_node,
        data=rawptr(scanner)
    }

    for stmt in file.decls {
        if stmt == nil do continue
        ast.walk(&visitor, &stmt.stmt_base)
    }

    return
}

DEFAULT_SUFFIX :: ".odin"

scan_dir_path :: proc(dir: string, scanner: ^Scanner, suffix := DEFAULT_SUFFIX) -> (err: Scanner_Error) {
    infos := os.read_all_directory_by_path(dir, context.allocator) or_return
    defer os.file_info_slice_delete(infos, context.allocator)

    for info in infos {
        if info.type == .Directory {
            scan_dir_path(info.fullpath, scanner, suffix) or_return
        } else if strings.has_suffix(info.name, suffix) {
            file := os.open(info.fullpath) or_return
            defer os.close(file)
            scan_file_obj_with_path(file, info.fullpath, scanner) or_return
        }
    }
    return
}

scan_file_or_dir_obj :: proc(file: ^os.File, scanner: ^Scanner, suffix := DEFAULT_SUFFIX) -> (err: Scanner_Error) {
    fi := os.fstat(file, context.allocator) or_return
    defer os.file_info_delete(fi, context.allocator)

    if fi.type == .Directory {
        return scan_dir_path(fi.fullpath, scanner, suffix)
    }
    return scan_file_obj_with_path(file, fi.fullpath, scanner)
}

// An explicitly named file is scanned regardless of suffix; the suffix filters directory contents.
scan_file_or_dir_path :: proc(p: string, scanner: ^Scanner, suffix := DEFAULT_SUFFIX) -> (err: Scanner_Error) {
    if os.is_dir(p) {
        return scan_dir_path(p, scanner, suffix)
    }
    file := os.open(p) or_return
    defer os.close(file)
    return scan_file_or_dir_obj(file, scanner, suffix)
}

scan_file_or_dir :: proc{
    scan_file_or_dir_obj,
    scan_file_or_dir_path
}
