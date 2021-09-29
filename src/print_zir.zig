const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ast = std.zig.Ast;

const Zir = @import("Zir.zig");
const Module = @import("Module.zig");
const LazySrcLoc = Module.LazySrcLoc;

/// Write human-readable, debug formatted ZIR code to a file.
pub fn renderAsTextToFile(
    gpa: *Allocator,
    scope_file: *Module.Scope.File,
    fs_file: std.fs.File,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var writer: Writer = .{
        .gpa = gpa,
        .arena = &arena.allocator,
        .file = scope_file,
        .code = scope_file.zir,
        .indent = 0,
        .parent_decl_node = 0,
    };

    const main_struct_inst = Zir.main_struct_inst;
    try fs_file.writer().print("%{d} ", .{main_struct_inst});
    try writer.writeInstToStream(fs_file.writer(), main_struct_inst);
    try fs_file.writeAll("\n");
    const imports_index = scope_file.zir.extra[@enumToInt(Zir.ExtraIndex.imports)];
    if (imports_index != 0) {
        try fs_file.writeAll("Imports:\n");

        const extra = scope_file.zir.extraData(Zir.Inst.Imports, imports_index);
        var import_i: u32 = 0;
        var extra_index = extra.end;

        while (import_i < extra.data.imports_len) : (import_i += 1) {
            const item = scope_file.zir.extraData(Zir.Inst.Imports.Item, extra_index);
            extra_index = item.end;

            const src: LazySrcLoc = .{ .token_abs = item.data.token };
            const import_path = scope_file.zir.nullTerminatedString(item.data.name);
            try fs_file.writer().print("  @import(\"{}\") ", .{
                std.zig.fmtEscapes(import_path),
            });
            try writer.writeSrc(fs_file.writer(), src);
            try fs_file.writer().writeAll("\n");
        }
    }
}

const Writer = struct {
    gpa: *Allocator,
    arena: *Allocator,
    file: *Module.Scope.File,
    code: Zir,
    indent: u32,
    parent_decl_node: u32,

    fn relativeToNodeIndex(self: *Writer, offset: i32) Ast.Node.Index {
        return @bitCast(Ast.Node.Index, offset + @bitCast(i32, self.parent_decl_node));
    }

    fn writeInstToStream(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const tags = self.code.instructions.items(.tag);
        const tag = tags[inst];
        try stream.print("= {s}(", .{@tagName(tags[inst])});
        switch (tag) {
            .array_type,
            .as,
            .coerce_result_ptr,
            .elem_ptr,
            .elem_val,
            .store,
            .store_to_block_ptr,
            .store_to_inferred_ptr,
            .field_ptr_type,
            => try self.writeBin(stream, inst),

            .alloc,
            .alloc_mut,
            .alloc_comptime,
            .indexable_ptr_len,
            .anyframe_type,
            .bit_not,
            .bool_not,
            .negate,
            .negate_wrap,
            .load,
            .ensure_result_used,
            .ensure_result_non_error,
            .ret_node,
            .ret_load,
            .resolve_inferred_alloc,
            .optional_type,
            .optional_payload_safe,
            .optional_payload_unsafe,
            .optional_payload_safe_ptr,
            .optional_payload_unsafe_ptr,
            .err_union_payload_safe,
            .err_union_payload_unsafe,
            .err_union_payload_safe_ptr,
            .err_union_payload_unsafe_ptr,
            .err_union_code,
            .err_union_code_ptr,
            .is_non_null,
            .is_non_null_ptr,
            .is_non_err,
            .is_non_err_ptr,
            .typeof,
            .typeof_elem,
            .struct_init_empty,
            .type_info,
            .size_of,
            .bit_size_of,
            .typeof_log2_int_type,
            .log2_int_type,
            .ptr_to_int,
            .error_to_int,
            .int_to_error,
            .compile_error,
            .set_eval_branch_quota,
            .enum_to_int,
            .align_of,
            .bool_to_int,
            .embed_file,
            .error_name,
            .panic,
            .set_align_stack,
            .set_cold,
            .set_float_mode,
            .set_runtime_safety,
            .sqrt,
            .sin,
            .cos,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .fabs,
            .floor,
            .ceil,
            .trunc,
            .round,
            .tag_name,
            .reify,
            .type_name,
            .frame_type,
            .frame_size,
            .clz,
            .ctz,
            .pop_count,
            .byte_swap,
            .bit_reverse,
            .elem_type,
            .@"resume",
            .@"await",
            .await_nosuspend,
            .fence,
            => try self.writeUnNode(stream, inst),

            .ref,
            .ret_coerce,
            .ensure_err_payload_void,
            .closure_capture,
            => try self.writeUnTok(stream, inst),

            .bool_br_and,
            .bool_br_or,
            => try self.writeBoolBr(stream, inst),

            .array_type_sentinel => try self.writeArrayTypeSentinel(stream, inst),
            .ptr_type_simple => try self.writePtrTypeSimple(stream, inst),
            .ptr_type => try self.writePtrType(stream, inst),
            .int => try self.writeInt(stream, inst),
            .int_big => try self.writeIntBig(stream, inst),
            .float => try self.writeFloat(stream, inst),
            .float128 => try self.writeFloat128(stream, inst),
            .str => try self.writeStr(stream, inst),
            .int_type => try self.writeIntType(stream, inst),

            .@"break",
            .break_inline,
            => try self.writeBreak(stream, inst),

            .elem_ptr_node,
            .elem_val_node,
            .slice_start,
            .slice_end,
            .slice_sentinel,
            .array_init,
            .array_init_anon,
            .array_init_ref,
            .array_init_anon_ref,
            .union_init_ptr,
            .shuffle,
            .select,
            .mul_add,
            .builtin_call,
            .field_parent_ptr,
            .builtin_async_call,
            => try self.writePlNode(stream, inst),

            .struct_init,
            .struct_init_ref,
            => try self.writeStructInit(stream, inst),

            .cmpxchg_strong, .cmpxchg_weak => try self.writeCmpxchg(stream, inst),
            .atomic_store => try self.writeAtomicStore(stream, inst),
            .atomic_rmw => try self.writeAtomicRmw(stream, inst),
            .memcpy => try self.writeMemcpy(stream, inst),
            .memset => try self.writeMemset(stream, inst),

            .struct_init_anon,
            .struct_init_anon_ref,
            => try self.writeStructInitAnon(stream, inst),

            .field_type => try self.writeFieldType(stream, inst),
            .field_type_ref => try self.writeFieldTypeRef(stream, inst),

            .add,
            .addwrap,
            .add_sat,
            .array_cat,
            .array_mul,
            .mul,
            .mulwrap,
            .mul_sat,
            .sub,
            .subwrap,
            .sub_sat,
            .cmp_lt,
            .cmp_lte,
            .cmp_eq,
            .cmp_gte,
            .cmp_gt,
            .cmp_neq,
            .div,
            .has_decl,
            .has_field,
            .mod_rem,
            .shl,
            .shl_exact,
            .shl_sat,
            .shr,
            .shr_exact,
            .xor,
            .store_node,
            .error_union_type,
            .merge_error_sets,
            .bit_and,
            .bit_or,
            .float_to_int,
            .int_to_float,
            .int_to_ptr,
            .int_to_enum,
            .float_cast,
            .int_cast,
            .err_set_cast,
            .ptr_cast,
            .truncate,
            .align_cast,
            .div_exact,
            .div_floor,
            .div_trunc,
            .mod,
            .rem,
            .bit_offset_of,
            .offset_of,
            .splat,
            .reduce,
            .atomic_load,
            .bitcast,
            .bitcast_result_ptr,
            .vector_type,
            .maximum,
            .minimum,
            => try self.writePlNodeBin(stream, inst),

            .@"export" => try self.writePlNodeExport(stream, inst),
            .export_value => try self.writePlNodeExportValue(stream, inst),

            .call => try self.writePlNodeCall(stream, inst),

            .block,
            .block_inline,
            .suspend_block,
            .loop,
            .validate_struct_init_ptr,
            .validate_array_init_ptr,
            .c_import,
            => try self.writePlNodeBlock(stream, inst),

            .condbr,
            .condbr_inline,
            => try self.writePlNodeCondBr(stream, inst),

            .error_set_decl => try self.writeErrorSetDecl(stream, inst, .parent),
            .error_set_decl_anon => try self.writeErrorSetDecl(stream, inst, .anon),
            .error_set_decl_func => try self.writeErrorSetDecl(stream, inst, .func),

            .switch_block => try self.writePlNodeSwitchBr(stream, inst, .none),
            .switch_block_else => try self.writePlNodeSwitchBr(stream, inst, .@"else"),
            .switch_block_under => try self.writePlNodeSwitchBr(stream, inst, .under),
            .switch_block_ref => try self.writePlNodeSwitchBr(stream, inst, .none),
            .switch_block_ref_else => try self.writePlNodeSwitchBr(stream, inst, .@"else"),
            .switch_block_ref_under => try self.writePlNodeSwitchBr(stream, inst, .under),

            .switch_block_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .none),
            .switch_block_else_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .@"else"),
            .switch_block_under_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .under),
            .switch_block_ref_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .none),
            .switch_block_ref_else_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .@"else"),
            .switch_block_ref_under_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .under),

            .field_ptr,
            .field_val,
            .field_call_bind,
            => try self.writePlNodeField(stream, inst),

            .field_ptr_named,
            .field_val_named,
            .field_call_bind_named,
            => try self.writePlNodeFieldNamed(stream, inst),

            .as_node => try self.writeAs(stream, inst),

            .breakpoint,
            .repeat,
            .repeat_inline,
            .alloc_inferred,
            .alloc_inferred_mut,
            .alloc_inferred_comptime,
            => try self.writeNode(stream, inst),

            .error_value,
            .enum_literal,
            .decl_ref,
            .decl_val,
            .import,
            .ret_err_value,
            .ret_err_value_code,
            .param_anytype,
            .param_anytype_comptime,
            => try self.writeStrTok(stream, inst),

            .param, .param_comptime => try self.writeParam(stream, inst),

            .func => try self.writeFunc(stream, inst, false),
            .func_inferred => try self.writeFunc(stream, inst, true),

            .@"unreachable" => try self.writeUnreachable(stream, inst),

            .switch_capture,
            .switch_capture_ref,
            .switch_capture_multi,
            .switch_capture_multi_ref,
            .switch_capture_else,
            .switch_capture_else_ref,
            => try self.writeSwitchCapture(stream, inst),

            .dbg_stmt => try self.writeDbgStmt(stream, inst),

            .closure_get => try self.writeInstNode(stream, inst),

            .extended => try self.writeExtended(stream, inst),
        }
    }

    fn writeExtended(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const extended = self.code.instructions.items(.data)[inst].extended;
        try stream.print("{s}(", .{@tagName(extended.opcode)});
        switch (extended.opcode) {
            .ret_ptr,
            .ret_type,
            .this,
            .ret_addr,
            .error_return_trace,
            .frame,
            .frame_address,
            .builtin_src,
            => try self.writeExtNode(stream, extended),

            .@"asm" => try self.writeAsm(stream, extended),
            .func => try self.writeFuncExtended(stream, extended),
            .variable => try self.writeVarExtended(stream, extended),

            .compile_log,
            .typeof_peer,
            => try self.writeNodeMultiOp(stream, extended),

            .add_with_overflow,
            .sub_with_overflow,
            .mul_with_overflow,
            .shl_with_overflow,
            => try self.writeOverflowArithmetic(stream, extended),

            .struct_decl => try self.writeStructDecl(stream, extended),
            .union_decl => try self.writeUnionDecl(stream, extended),
            .enum_decl => try self.writeEnumDecl(stream, extended),
            .opaque_decl => try self.writeOpaqueDecl(stream, extended),

            .c_undef, .c_include => {
                const inst_data = self.code.extraData(Zir.Inst.UnNode, extended.operand).data;
                try self.writeInstRef(stream, inst_data.operand);
                try stream.writeAll(") ");
            },

            .c_define => {
                const inst_data = self.code.extraData(Zir.Inst.BinNode, extended.operand).data;
                try self.writeInstRef(stream, inst_data.lhs);
                try stream.writeAll(", ");
                try self.writeInstRef(stream, inst_data.rhs);
                try stream.writeByte(')');
            },

            .alloc,
            .builtin_extern,
            .wasm_memory_size,
            .wasm_memory_grow,
            => try stream.writeAll("TODO))"),
        }
    }

    fn writeExtNode(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writeBin(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].bin;
        try self.writeInstRef(stream, inst_data.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, inst_data.rhs);
        try stream.writeByte(')');
    }

    fn writeUnNode(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].un_node;
        try self.writeInstRef(stream, inst_data.operand);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeUnTok(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].un_tok;
        try self.writeInstRef(stream, inst_data.operand);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeArrayTypeSentinel(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].array_type_sentinel;
        _ = inst_data;
        try stream.writeAll("TODO)");
    }

    fn writePtrTypeSimple(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].ptr_type_simple;
        const str_allowzero = if (inst_data.is_allowzero) "allowzero, " else "";
        const str_const = if (!inst_data.is_mutable) "const, " else "";
        const str_volatile = if (inst_data.is_volatile) "volatile, " else "";
        try self.writeInstRef(stream, inst_data.elem_type);
        try stream.print(", {s}{s}{s}{s})", .{
            str_allowzero,
            str_const,
            str_volatile,
            @tagName(inst_data.size),
        });
    }

    fn writePtrType(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].ptr_type;
        _ = inst_data;
        try stream.writeAll("TODO)");
    }

    fn writeInt(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].int;
        try stream.print("{d})", .{inst_data});
    }

    fn writeIntBig(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].str;
        const byte_count = inst_data.len * @sizeOf(std.math.big.Limb);
        const limb_bytes = self.code.string_bytes[inst_data.start..][0..byte_count];
        // limb_bytes is not aligned properly; we must allocate and copy the bytes
        // in order to accomplish this.
        const limbs = try self.gpa.alloc(std.math.big.Limb, inst_data.len);
        defer self.gpa.free(limbs);

        mem.copy(u8, mem.sliceAsBytes(limbs), limb_bytes);
        const big_int: std.math.big.int.Const = .{
            .limbs = limbs,
            .positive = true,
        };
        const as_string = try big_int.toStringAlloc(self.gpa, 10, .lower);
        defer self.gpa.free(as_string);
        try stream.print("{s})", .{as_string});
    }

    fn writeFloat(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const number = self.code.instructions.items(.data)[inst].float;
        try stream.print("{d})", .{number});
    }

    fn writeFloat128(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Float128, inst_data.payload_index).data;
        const src = inst_data.src();
        const number = extra.get();
        // TODO improve std.format to be able to print f128 values
        try stream.print("{d}) ", .{@floatCast(f64, number)});
        try self.writeSrc(stream, src);
    }

    fn writeStr(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].str;
        const str = inst_data.get(self.code);
        try stream.print("\"{}\")", .{std.zig.fmtEscapes(str)});
    }

    fn writePlNode(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        try stream.writeAll("TODO) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeParam(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_tok;
        const extra = self.code.extraData(Zir.Inst.Param, inst_data.payload_index);
        const body = self.code.extra[extra.end..][0..extra.data.body_len];
        try stream.print("\"{}\", ", .{
            std.zig.fmtEscapes(self.code.nullTerminatedString(extra.data.name)),
        });
        try stream.writeAll("{\n");
        self.indent += 2;
        try self.writeBody(stream, body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeBin(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.rhs);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeExport(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Export, inst_data.payload_index).data;
        const decl_name = self.code.nullTerminatedString(extra.decl_name);

        try self.writeInstRef(stream, extra.namespace);
        try stream.print(", {}, ", .{std.zig.fmtId(decl_name)});
        try self.writeInstRef(stream, extra.options);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeExportValue(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.ExportValue, inst_data.payload_index).data;

        try self.writeInstRef(stream, extra.operand);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.options);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeStructInit(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.StructInit, inst_data.payload_index);
        var field_i: u32 = 0;
        var extra_index = extra.end;

        while (field_i < extra.data.fields_len) : (field_i += 1) {
            const item = self.code.extraData(Zir.Inst.StructInit.Item, extra_index);
            extra_index = item.end;

            if (field_i != 0) {
                try stream.writeAll(", [");
            } else {
                try stream.writeAll("[");
            }
            try self.writeInstIndex(stream, item.data.field_type);
            try stream.writeAll(", ");
            try self.writeInstRef(stream, item.data.init);
            try stream.writeAll("]");
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeCmpxchg(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Cmpxchg, inst_data.payload_index).data;

        try self.writeInstRef(stream, extra.ptr);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.expected_value);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.new_value);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.success_order);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.failure_order);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeAtomicStore(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.AtomicStore, inst_data.payload_index).data;

        try self.writeInstRef(stream, extra.ptr);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.operand);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.ordering);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeAtomicRmw(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.AtomicRmw, inst_data.payload_index).data;

        try self.writeInstRef(stream, extra.ptr);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.operation);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.operand);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.ordering);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeMemcpy(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Memcpy, inst_data.payload_index).data;

        try self.writeInstRef(stream, extra.dest);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.source);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.byte_count);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeMemset(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Memset, inst_data.payload_index).data;

        try self.writeInstRef(stream, extra.dest);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.byte);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.byte_count);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeStructInitAnon(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.StructInitAnon, inst_data.payload_index);
        var field_i: u32 = 0;
        var extra_index = extra.end;

        while (field_i < extra.data.fields_len) : (field_i += 1) {
            const item = self.code.extraData(Zir.Inst.StructInitAnon.Item, extra_index);
            extra_index = item.end;

            const field_name = self.code.nullTerminatedString(item.data.field_name);

            const prefix = if (field_i != 0) ", [" else "[";
            try stream.print("{s}[{s}=", .{ prefix, field_name });
            try self.writeInstRef(stream, item.data.init);
            try stream.writeAll("]");
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFieldType(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.FieldType, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.container_type);
        const field_name = self.code.nullTerminatedString(extra.name_start);
        try stream.print(", {s}) ", .{field_name});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFieldTypeRef(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.FieldTypeRef, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.container_type);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.field_name);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeNodeMultiOp(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Zir.Inst.NodeMultiOp, extended.operand);
        const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
        const operands = self.code.refSlice(extra.end, extended.small);

        for (operands) |operand, i| {
            if (i != 0) try stream.writeAll(", ");
            try self.writeInstRef(stream, operand);
        }
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writeInstNode(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].inst_node;
        try self.writeInstIndex(stream, inst_data.inst);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeAsm(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Zir.Inst.Asm, extended.operand);
        const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
        const outputs_len = @truncate(u5, extended.small);
        const inputs_len = @truncate(u5, extended.small >> 5);
        const clobbers_len = @truncate(u5, extended.small >> 10);
        const is_volatile = @truncate(u1, extended.small >> 15) != 0;
        const asm_source = self.code.nullTerminatedString(extra.data.asm_source);

        try self.writeFlag(stream, "volatile, ", is_volatile);
        try stream.print("\"{}\", ", .{std.zig.fmtEscapes(asm_source)});
        try stream.writeAll(", ");

        var extra_i: usize = extra.end;
        var output_type_bits = extra.data.output_type_bits;
        {
            var i: usize = 0;
            while (i < outputs_len) : (i += 1) {
                const output = self.code.extraData(Zir.Inst.Asm.Output, extra_i);
                extra_i = output.end;

                const is_type = @truncate(u1, output_type_bits) != 0;
                output_type_bits >>= 1;

                const name = self.code.nullTerminatedString(output.data.name);
                const constraint = self.code.nullTerminatedString(output.data.constraint);
                try stream.print("output({}, \"{}\", ", .{
                    std.zig.fmtId(name), std.zig.fmtEscapes(constraint),
                });
                try self.writeFlag(stream, "->", is_type);
                try self.writeInstRef(stream, output.data.operand);
                try stream.writeAll(")");
                if (i + 1 < outputs_len) {
                    try stream.writeAll("), ");
                }
            }
        }
        {
            var i: usize = 0;
            while (i < inputs_len) : (i += 1) {
                const input = self.code.extraData(Zir.Inst.Asm.Input, extra_i);
                extra_i = input.end;

                const name = self.code.nullTerminatedString(input.data.name);
                const constraint = self.code.nullTerminatedString(input.data.constraint);
                try stream.print("input({}, \"{}\", ", .{
                    std.zig.fmtId(name), std.zig.fmtEscapes(constraint),
                });
                try self.writeInstRef(stream, input.data.operand);
                try stream.writeAll(")");
                if (i + 1 < inputs_len) {
                    try stream.writeAll(", ");
                }
            }
        }
        {
            var i: usize = 0;
            while (i < clobbers_len) : (i += 1) {
                const str_index = self.code.extra[extra_i];
                extra_i += 1;
                const clobber = self.code.nullTerminatedString(str_index);
                try stream.print("{}", .{std.zig.fmtId(clobber)});
                if (i + 1 < clobbers_len) {
                    try stream.writeAll(", ");
                }
            }
        }
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writeOverflowArithmetic(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Zir.Inst.OverflowArithmetic, extended.operand).data;
        const src: LazySrcLoc = .{ .node_offset = extra.node };

        try self.writeInstRef(stream, extra.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.rhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.ptr);
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writePlNodeCall(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Call, inst_data.payload_index);
        const args = self.code.refSlice(extra.end, extra.data.flags.args_len);

        if (extra.data.flags.ensure_result_used) {
            try stream.writeAll("nodiscard ");
        }
        try stream.print(".{s}, ", .{@tagName(@intToEnum(std.builtin.CallOptions.Modifier, extra.data.flags.packed_modifier))});
        try self.writeInstRef(stream, extra.data.callee);
        try stream.writeAll(", [");
        for (args) |arg, i| {
            if (i != 0) try stream.writeAll(", ");
            try self.writeInstRef(stream, arg);
        }
        try stream.writeAll("]) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeBlock(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        try self.writePlNodeBlockWithoutSrc(stream, inst);
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeBlockWithoutSrc(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Block, inst_data.payload_index);
        const body = self.code.extra[extra.end..][0..extra.data.body_len];
        try stream.writeAll("{\n");
        self.indent += 2;
        try self.writeBody(stream, body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");
    }

    fn writePlNodeCondBr(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.CondBr, inst_data.payload_index);
        const then_body = self.code.extra[extra.end..][0..extra.data.then_body_len];
        const else_body = self.code.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];
        try self.writeInstRef(stream, extra.data.condition);
        try stream.writeAll(", {\n");
        self.indent += 2;
        try self.writeBody(stream, then_body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}, {\n");
        self.indent += 2;
        try self.writeBody(stream, else_body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeStructDecl(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const small = @bitCast(Zir.Inst.StructDecl.Small, extended.small);

        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const body_len = if (small.has_body_len) blk: {
            const body_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk body_len;
        } else 0;

        const fields_len = if (small.has_fields_len) blk: {
            const fields_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk fields_len;
        } else 0;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try self.writeFlag(stream, "known_has_bits, ", small.known_has_bits);
        try stream.print("{s}, {s}, ", .{
            @tagName(small.name_strategy), @tagName(small.layout),
        });

        if (decls_len == 0) {
            try stream.writeAll("{}, ");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            extra_index = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}, ");
        }

        const body = self.code.extra[extra_index..][0..body_len];
        extra_index += body.len;

        if (fields_len == 0) {
            assert(body.len == 0);
            try stream.writeAll("{}, {})");
        } else {
            const prev_parent_decl_node = self.parent_decl_node;
            if (src_node) |off| self.parent_decl_node = self.relativeToNodeIndex(off);
            self.indent += 2;
            if (body.len == 0) {
                try stream.writeAll("{}, {\n");
            } else {
                try stream.writeAll("{\n");
                try self.writeBody(stream, body);

                try stream.writeByteNTimes(' ', self.indent - 2);
                try stream.writeAll("}, {\n");
            }

            const bits_per_field = 4;
            const fields_per_u32 = 32 / bits_per_field;
            const bit_bags_count = std.math.divCeil(usize, fields_len, fields_per_u32) catch unreachable;
            var bit_bag_index: usize = extra_index;
            extra_index += bit_bags_count;
            var cur_bit_bag: u32 = undefined;
            var field_i: u32 = 0;
            while (field_i < fields_len) : (field_i += 1) {
                if (field_i % fields_per_u32 == 0) {
                    cur_bit_bag = self.code.extra[bit_bag_index];
                    bit_bag_index += 1;
                }
                const has_align = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;
                const has_default = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;
                const is_comptime = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;
                const unused = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;

                _ = unused;

                const field_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
                extra_index += 1;
                const field_type = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeByteNTimes(' ', self.indent);
                try self.writeFlag(stream, "comptime ", is_comptime);
                try stream.print("{}: ", .{std.zig.fmtId(field_name)});
                try self.writeInstRef(stream, field_type);

                if (has_align) {
                    const align_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(" align(");
                    try self.writeInstRef(stream, align_ref);
                    try stream.writeAll(")");
                }
                if (has_default) {
                    const default_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(" = ");
                    try self.writeInstRef(stream, default_ref);
                }
                try stream.writeAll(",\n");
            }

            self.parent_decl_node = prev_parent_decl_node;
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("})");
        }
        try self.writeSrcNode(stream, src_node);
    }

    fn writeUnionDecl(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const small = @bitCast(Zir.Inst.UnionDecl.Small, extended.small);

        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const tag_type_ref = if (small.has_tag_type) blk: {
            const tag_type_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk tag_type_ref;
        } else .none;

        const body_len = if (small.has_body_len) blk: {
            const body_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk body_len;
        } else 0;

        const fields_len = if (small.has_fields_len) blk: {
            const fields_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk fields_len;
        } else 0;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try stream.print("{s}, {s}, ", .{
            @tagName(small.name_strategy), @tagName(small.layout),
        });
        try self.writeFlag(stream, "autoenum, ", small.auto_enum_tag);

        if (decls_len == 0) {
            try stream.writeAll("{}, ");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            extra_index = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}, ");
        }

        assert(fields_len != 0);

        if (tag_type_ref != .none) {
            try self.writeInstRef(stream, tag_type_ref);
            try stream.writeAll(", ");
        }

        const body = self.code.extra[extra_index..][0..body_len];
        extra_index += body.len;

        const prev_parent_decl_node = self.parent_decl_node;
        if (src_node) |off| self.parent_decl_node = self.relativeToNodeIndex(off);
        self.indent += 2;
        if (body.len == 0) {
            try stream.writeAll("{}, {\n");
        } else {
            try stream.writeAll("{\n");
            try self.writeBody(stream, body);

            try stream.writeByteNTimes(' ', self.indent - 2);
            try stream.writeAll("}, {\n");
        }

        const bits_per_field = 4;
        const fields_per_u32 = 32 / bits_per_field;
        const bit_bags_count = std.math.divCeil(usize, fields_len, fields_per_u32) catch unreachable;
        const body_end = extra_index;
        extra_index += bit_bags_count;
        var bit_bag_index: usize = body_end;
        var cur_bit_bag: u32 = undefined;
        var field_i: u32 = 0;
        while (field_i < fields_len) : (field_i += 1) {
            if (field_i % fields_per_u32 == 0) {
                cur_bit_bag = self.code.extra[bit_bag_index];
                bit_bag_index += 1;
            }
            const has_type = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_align = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_value = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const unused = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;

            _ = unused;

            const field_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
            extra_index += 1;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.print("{}", .{std.zig.fmtId(field_name)});

            if (has_type) {
                const field_type = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeAll(": ");
                try self.writeInstRef(stream, field_type);
            }
            if (has_align) {
                const align_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeAll(" align(");
                try self.writeInstRef(stream, align_ref);
                try stream.writeAll(")");
            }
            if (has_value) {
                const default_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeAll(" = ");
                try self.writeInstRef(stream, default_ref);
            }
            try stream.writeAll(",\n");
        }

        self.parent_decl_node = prev_parent_decl_node;
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("})");
        try self.writeSrcNode(stream, src_node);
    }

    fn writeDecls(self: *Writer, stream: anytype, decls_len: u32, extra_start: usize) !usize {
        const parent_decl_node = self.parent_decl_node;
        const bit_bags_count = std.math.divCeil(usize, decls_len, 8) catch unreachable;
        var extra_index = extra_start + bit_bags_count;
        var bit_bag_index: usize = extra_start;
        var cur_bit_bag: u32 = undefined;
        var decl_i: u32 = 0;
        while (decl_i < decls_len) : (decl_i += 1) {
            if (decl_i % 8 == 0) {
                cur_bit_bag = self.code.extra[bit_bag_index];
                bit_bag_index += 1;
            }
            const is_pub = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const is_exported = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_align = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_section_or_addrspace = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;

            const sub_index = extra_index;

            const hash_u32s = self.code.extra[extra_index..][0..4];
            extra_index += 4;
            const line = self.code.extra[extra_index];
            extra_index += 1;
            const decl_name_index = self.code.extra[extra_index];
            extra_index += 1;
            const decl_index = self.code.extra[extra_index];
            extra_index += 1;
            const align_inst: Zir.Inst.Ref = if (!has_align) .none else inst: {
                const inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                break :inst inst;
            };
            const section_inst: Zir.Inst.Ref = if (!has_section_or_addrspace) .none else inst: {
                const inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                break :inst inst;
            };
            const addrspace_inst: Zir.Inst.Ref = if (!has_section_or_addrspace) .none else inst: {
                const inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                break :inst inst;
            };

            const pub_str = if (is_pub) "pub " else "";
            const hash_bytes = @bitCast([16]u8, hash_u32s.*);
            try stream.writeByteNTimes(' ', self.indent);
            if (decl_name_index == 0) {
                const name = if (is_exported) "usingnamespace" else "comptime";
                try stream.writeAll(pub_str);
                try stream.writeAll(name);
            } else if (decl_name_index == 1) {
                try stream.writeAll("test");
            } else {
                const raw_decl_name = self.code.nullTerminatedString(decl_name_index);
                const decl_name = if (raw_decl_name.len == 0)
                    self.code.nullTerminatedString(decl_name_index + 1)
                else
                    raw_decl_name;
                const test_str = if (raw_decl_name.len == 0) "test " else "";
                const export_str = if (is_exported) "export " else "";
                try stream.print("[{d}] {s}{s}{s}{}", .{
                    sub_index, pub_str, test_str, export_str, std.zig.fmtId(decl_name),
                });
                if (align_inst != .none) {
                    try stream.writeAll(" align(");
                    try self.writeInstRef(stream, align_inst);
                    try stream.writeAll(")");
                }
                if (addrspace_inst != .none) {
                    try stream.writeAll(" addrspace(");
                    try self.writeInstRef(stream, addrspace_inst);
                    try stream.writeAll(")");
                }
                if (section_inst != .none) {
                    try stream.writeAll(" linksection(");
                    try self.writeInstRef(stream, section_inst);
                    try stream.writeAll(")");
                }
            }
            const tag = self.code.instructions.items(.tag)[decl_index];
            try stream.print(" line({d}) hash({}): %{d} = {s}(", .{
                line, std.fmt.fmtSliceHexLower(&hash_bytes), decl_index, @tagName(tag),
            });

            const decl_block_inst_data = self.code.instructions.items(.data)[decl_index].pl_node;
            const sub_decl_node_off = decl_block_inst_data.src_node;
            self.parent_decl_node = self.relativeToNodeIndex(sub_decl_node_off);
            try self.writePlNodeBlockWithoutSrc(stream, decl_index);
            self.parent_decl_node = parent_decl_node;
            try self.writeSrc(stream, decl_block_inst_data.src());
            try stream.writeAll("\n");
        }
        return extra_index;
    }

    fn writeEnumDecl(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const small = @bitCast(Zir.Inst.EnumDecl.Small, extended.small);
        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const tag_type_ref = if (small.has_tag_type) blk: {
            const tag_type_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk tag_type_ref;
        } else .none;

        const body_len = if (small.has_body_len) blk: {
            const body_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk body_len;
        } else 0;

        const fields_len = if (small.has_fields_len) blk: {
            const fields_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk fields_len;
        } else 0;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try stream.print("{s}, ", .{@tagName(small.name_strategy)});
        try self.writeFlag(stream, "nonexhaustive, ", small.nonexhaustive);

        if (decls_len == 0) {
            try stream.writeAll("{}, ");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            extra_index = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}, ");
        }

        if (tag_type_ref != .none) {
            try self.writeInstRef(stream, tag_type_ref);
            try stream.writeAll(", ");
        }

        const body = self.code.extra[extra_index..][0..body_len];
        extra_index += body.len;

        if (fields_len == 0) {
            assert(body.len == 0);
            try stream.writeAll("{}, {})");
        } else {
            const prev_parent_decl_node = self.parent_decl_node;
            if (src_node) |off| self.parent_decl_node = self.relativeToNodeIndex(off);
            self.indent += 2;
            if (body.len == 0) {
                try stream.writeAll("{}, {\n");
            } else {
                try stream.writeAll("{\n");
                try self.writeBody(stream, body);

                try stream.writeByteNTimes(' ', self.indent - 2);
                try stream.writeAll("}, {\n");
            }

            const bit_bags_count = std.math.divCeil(usize, fields_len, 32) catch unreachable;
            const body_end = extra_index;
            extra_index += bit_bags_count;
            var bit_bag_index: usize = body_end;
            var cur_bit_bag: u32 = undefined;
            var field_i: u32 = 0;
            while (field_i < fields_len) : (field_i += 1) {
                if (field_i % 32 == 0) {
                    cur_bit_bag = self.code.extra[bit_bag_index];
                    bit_bag_index += 1;
                }
                const has_tag_value = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;

                const field_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeByteNTimes(' ', self.indent);
                try stream.print("{}", .{std.zig.fmtId(field_name)});

                if (has_tag_value) {
                    const tag_value_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(" = ");
                    try self.writeInstRef(stream, tag_value_ref);
                }
                try stream.writeAll(",\n");
            }
            self.parent_decl_node = prev_parent_decl_node;
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("})");
        }
        try self.writeSrcNode(stream, src_node);
    }

    fn writeOpaqueDecl(
        self: *Writer,
        stream: anytype,
        extended: Zir.Inst.Extended.InstData,
    ) !void {
        const small = @bitCast(Zir.Inst.OpaqueDecl.Small, extended.small);
        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try stream.print("{s}, ", .{@tagName(small.name_strategy)});

        if (decls_len == 0) {
            try stream.writeAll("{})");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            _ = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("})");
        }
        try self.writeSrcNode(stream, src_node);
    }

    fn writeErrorSetDecl(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
        name_strategy: Zir.Inst.NameStrategy,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.ErrorSetDecl, inst_data.payload_index);
        const fields = self.code.extra[extra.end..][0..extra.data.fields_len];

        try stream.print("{s}, ", .{@tagName(name_strategy)});

        try stream.writeAll("{\n");
        self.indent += 2;
        for (fields) |str_index| {
            const name = self.code.nullTerminatedString(str_index);
            try stream.writeByteNTimes(' ', self.indent);
            try stream.print("{},\n", .{std.zig.fmtId(name)});
        }
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");

        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeSwitchBr(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
        special_prong: Zir.SpecialProng,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.SwitchBlock, inst_data.payload_index);
        const special: struct {
            body: []const Zir.Inst.Index,
            end: usize,
        } = switch (special_prong) {
            .none => .{ .body = &.{}, .end = extra.end },
            .under, .@"else" => blk: {
                const body_len = self.code.extra[extra.end];
                const extra_body_start = extra.end + 1;
                break :blk .{
                    .body = self.code.extra[extra_body_start..][0..body_len],
                    .end = extra_body_start + body_len,
                };
            },
        };

        try self.writeInstRef(stream, extra.data.operand);

        if (special.body.len != 0) {
            const prong_name = switch (special_prong) {
                .@"else" => "else",
                .under => "_",
                else => unreachable,
            };
            try stream.print(", {s} => {{\n", .{prong_name});
            self.indent += 2;
            try self.writeBody(stream, special.body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}");
        }

        var extra_index: usize = special.end;
        {
            var scalar_i: usize = 0;
            while (scalar_i < extra.data.cases_len) : (scalar_i += 1) {
                const item_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                const body_len = self.code.extra[extra_index];
                extra_index += 1;
                const body = self.code.extra[extra_index..][0..body_len];
                extra_index += body_len;

                try stream.writeAll(", ");
                try self.writeInstRef(stream, item_ref);
                try stream.writeAll(" => {\n");
                self.indent += 2;
                try self.writeBody(stream, body);
                self.indent -= 2;
                try stream.writeByteNTimes(' ', self.indent);
                try stream.writeAll("}");
            }
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeSwitchBlockMulti(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
        special_prong: Zir.SpecialProng,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.SwitchBlockMulti, inst_data.payload_index);
        const special: struct {
            body: []const Zir.Inst.Index,
            end: usize,
        } = switch (special_prong) {
            .none => .{ .body = &.{}, .end = extra.end },
            .under, .@"else" => blk: {
                const body_len = self.code.extra[extra.end];
                const extra_body_start = extra.end + 1;
                break :blk .{
                    .body = self.code.extra[extra_body_start..][0..body_len],
                    .end = extra_body_start + body_len,
                };
            },
        };

        try self.writeInstRef(stream, extra.data.operand);

        if (special.body.len != 0) {
            const prong_name = switch (special_prong) {
                .@"else" => "else",
                .under => "_",
                else => unreachable,
            };
            try stream.print(", {s} => {{\n", .{prong_name});
            self.indent += 2;
            try self.writeBody(stream, special.body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}");
        }

        var extra_index: usize = special.end;
        {
            var scalar_i: usize = 0;
            while (scalar_i < extra.data.scalar_cases_len) : (scalar_i += 1) {
                const item_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                const body_len = self.code.extra[extra_index];
                extra_index += 1;
                const body = self.code.extra[extra_index..][0..body_len];
                extra_index += body_len;

                try stream.writeAll(", ");
                try self.writeInstRef(stream, item_ref);
                try stream.writeAll(" => {\n");
                self.indent += 2;
                try self.writeBody(stream, body);
                self.indent -= 2;
                try stream.writeByteNTimes(' ', self.indent);
                try stream.writeAll("}");
            }
        }
        {
            var multi_i: usize = 0;
            while (multi_i < extra.data.multi_cases_len) : (multi_i += 1) {
                const items_len = self.code.extra[extra_index];
                extra_index += 1;
                const ranges_len = self.code.extra[extra_index];
                extra_index += 1;
                const body_len = self.code.extra[extra_index];
                extra_index += 1;
                const items = self.code.refSlice(extra_index, items_len);
                extra_index += items_len;

                for (items) |item_ref| {
                    try stream.writeAll(", ");
                    try self.writeInstRef(stream, item_ref);
                }

                var range_i: usize = 0;
                while (range_i < ranges_len) : (range_i += 1) {
                    const item_first = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;
                    const item_last = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(", ");
                    try self.writeInstRef(stream, item_first);
                    try stream.writeAll("...");
                    try self.writeInstRef(stream, item_last);
                }

                const body = self.code.extra[extra_index..][0..body_len];
                extra_index += body_len;
                try stream.writeAll(" => {\n");
                self.indent += 2;
                try self.writeBody(stream, body);
                self.indent -= 2;
                try stream.writeByteNTimes(' ', self.indent);
                try stream.writeAll("}");
            }
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeField(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.Field, inst_data.payload_index).data;
        const name = self.code.nullTerminatedString(extra.field_name_start);
        try self.writeInstRef(stream, extra.lhs);
        try stream.print(", \"{}\") ", .{std.zig.fmtEscapes(name)});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeFieldNamed(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.FieldNamed, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.field_name);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeAs(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Zir.Inst.As, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.dest_type);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.operand);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeNode(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const src_node = self.code.instructions.items(.data)[inst].node;
        const src: LazySrcLoc = .{ .node_offset = src_node };
        try stream.writeAll(") ");
        try self.writeSrc(stream, src);
    }

    fn writeStrTok(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].str_tok;
        const str = inst_data.get(self.code);
        try stream.print("\"{}\") ", .{std.zig.fmtEscapes(str)});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFunc(
        self: *Writer,
        stream: anytype,
        inst: Zir.Inst.Index,
        inferred_error_set: bool,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const src = inst_data.src();
        const extra = self.code.extraData(Zir.Inst.Func, inst_data.payload_index);
        var extra_index = extra.end;

        const ret_ty_body = self.code.extra[extra_index..][0..extra.data.ret_body_len];
        extra_index += ret_ty_body.len;

        const body = self.code.extra[extra_index..][0..extra.data.body_len];
        extra_index += body.len;

        var src_locs: Zir.Inst.Func.SrcLocs = undefined;
        if (body.len != 0) {
            src_locs = self.code.extraData(Zir.Inst.Func.SrcLocs, extra_index).data;
        }
        return self.writeFuncCommon(
            stream,
            ret_ty_body,
            inferred_error_set,
            false,
            false,
            .none,
            .none,
            body,
            src,
            src_locs,
        );
    }

    fn writeFuncExtended(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Zir.Inst.ExtendedFunc, extended.operand);
        const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
        const small = @bitCast(Zir.Inst.ExtendedFunc.Small, extended.small);

        var extra_index: usize = extra.end;
        if (small.has_lib_name) {
            const lib_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
            extra_index += 1;
            try stream.print("lib_name=\"{}\", ", .{std.zig.fmtEscapes(lib_name)});
        }
        try self.writeFlag(stream, "test, ", small.is_test);
        const cc: Zir.Inst.Ref = if (!small.has_cc) .none else blk: {
            const cc = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk cc;
        };
        const align_inst: Zir.Inst.Ref = if (!small.has_align) .none else blk: {
            const align_inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk align_inst;
        };

        const ret_ty_body = self.code.extra[extra_index..][0..extra.data.ret_body_len];
        extra_index += ret_ty_body.len;

        const body = self.code.extra[extra_index..][0..extra.data.body_len];
        extra_index += body.len;

        var src_locs: Zir.Inst.Func.SrcLocs = undefined;
        if (body.len != 0) {
            src_locs = self.code.extraData(Zir.Inst.Func.SrcLocs, extra_index).data;
        }
        return self.writeFuncCommon(
            stream,
            ret_ty_body,
            small.is_inferred_error,
            small.is_var_args,
            small.is_extern,
            cc,
            align_inst,
            body,
            src,
            src_locs,
        );
    }

    fn writeVarExtended(self: *Writer, stream: anytype, extended: Zir.Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Zir.Inst.ExtendedVar, extended.operand);
        const small = @bitCast(Zir.Inst.ExtendedVar.Small, extended.small);

        try self.writeInstRef(stream, extra.data.var_type);

        var extra_index: usize = extra.end;
        if (small.has_lib_name) {
            const lib_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
            extra_index += 1;
            try stream.print(", lib_name=\"{}\"", .{std.zig.fmtEscapes(lib_name)});
        }
        const align_inst: Zir.Inst.Ref = if (!small.has_align) .none else blk: {
            const align_inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk align_inst;
        };
        const init_inst: Zir.Inst.Ref = if (!small.has_init) .none else blk: {
            const init_inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk init_inst;
        };
        try self.writeFlag(stream, ", is_extern", small.is_extern);
        try self.writeOptionalInstRef(stream, ", align=", align_inst);
        try self.writeOptionalInstRef(stream, ", init=", init_inst);
        try stream.writeAll("))");
    }

    fn writeBoolBr(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].bool_br;
        const extra = self.code.extraData(Zir.Inst.Block, inst_data.payload_index);
        const body = self.code.extra[extra.end..][0..extra.data.body_len];
        try self.writeInstRef(stream, inst_data.lhs);
        try stream.writeAll(", {\n");
        self.indent += 2;
        try self.writeBody(stream, body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("})");
    }

    fn writeIntType(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const int_type = self.code.instructions.items(.data)[inst].int_type;
        const prefix: u8 = switch (int_type.signedness) {
            .signed => 'i',
            .unsigned => 'u',
        };
        try stream.print("{c}{d}) ", .{ prefix, int_type.bit_count });
        try self.writeSrc(stream, int_type.src());
    }

    fn writeBreak(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].@"break";

        try self.writeInstIndex(stream, inst_data.block_inst);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, inst_data.operand);
        try stream.writeAll(")");
    }

    fn writeUnreachable(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].@"unreachable";
        const safety_str = if (inst_data.safety) "safe" else "unsafe";
        try stream.print("{s}) ", .{safety_str});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFuncCommon(
        self: *Writer,
        stream: anytype,
        ret_ty_body: []const Zir.Inst.Index,
        inferred_error_set: bool,
        var_args: bool,
        is_extern: bool,
        cc: Zir.Inst.Ref,
        align_inst: Zir.Inst.Ref,
        body: []const Zir.Inst.Index,
        src: LazySrcLoc,
        src_locs: Zir.Inst.Func.SrcLocs,
    ) !void {
        if (ret_ty_body.len == 0) {
            try stream.writeAll("ret_ty=void");
        } else {
            try stream.writeAll("ret_ty={\n");
            self.indent += 2;
            try self.writeBody(stream, ret_ty_body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}");
        }

        try self.writeOptionalInstRef(stream, ", cc=", cc);
        try self.writeOptionalInstRef(stream, ", align=", align_inst);
        try self.writeFlag(stream, ", vargs", var_args);
        try self.writeFlag(stream, ", extern", is_extern);
        try self.writeFlag(stream, ", inferror", inferred_error_set);

        if (body.len == 0) {
            try stream.writeAll(", body={}) ");
        } else {
            try stream.writeAll(", body={\n");
            self.indent += 2;
            try self.writeBody(stream, body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}) ");
        }
        if (body.len != 0) {
            try stream.print("(lbrace={d}:{d},rbrace={d}:{d}) ", .{
                src_locs.lbrace_line, @truncate(u16, src_locs.columns),
                src_locs.rbrace_line, @truncate(u16, src_locs.columns >> 16),
            });
        }
        try self.writeSrc(stream, src);
    }

    fn writeSwitchCapture(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].switch_capture;
        try self.writeInstIndex(stream, inst_data.switch_inst);
        try stream.print(", {d})", .{inst_data.prong_index});
    }

    fn writeDbgStmt(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].dbg_stmt;
        try stream.print("{d}, {d})", .{ inst_data.line, inst_data.column });
    }

    fn writeInstRef(self: *Writer, stream: anytype, ref: Zir.Inst.Ref) !void {
        var i: usize = @enumToInt(ref);

        if (i < Zir.Inst.Ref.typed_value_map.len) {
            return stream.print("@{}", .{ref});
        }
        i -= Zir.Inst.Ref.typed_value_map.len;

        return self.writeInstIndex(stream, @intCast(Zir.Inst.Index, i));
    }

    fn writeInstIndex(self: *Writer, stream: anytype, inst: Zir.Inst.Index) !void {
        _ = self;
        return stream.print("%{d}", .{inst});
    }

    fn writeOptionalInstRef(
        self: *Writer,
        stream: anytype,
        prefix: []const u8,
        inst: Zir.Inst.Ref,
    ) !void {
        if (inst == .none) return;
        try stream.writeAll(prefix);
        try self.writeInstRef(stream, inst);
    }

    fn writeFlag(
        self: *Writer,
        stream: anytype,
        name: []const u8,
        flag: bool,
    ) !void {
        _ = self;
        if (!flag) return;
        try stream.writeAll(name);
    }

    fn writeSrc(self: *Writer, stream: anytype, src: LazySrcLoc) !void {
        const tree = self.file.tree;
        const src_loc: Module.SrcLoc = .{
            .file_scope = self.file,
            .parent_decl_node = self.parent_decl_node,
            .lazy = src,
        };
        // Caller must ensure AST tree is loaded.
        const abs_byte_off = src_loc.byteOffset(self.gpa) catch unreachable;
        const delta_line = std.zig.findLineColumn(tree.source, abs_byte_off);
        try stream.print("{s}:{d}:{d}", .{
            @tagName(src), delta_line.line + 1, delta_line.column + 1,
        });
    }

    fn writeSrcNode(self: *Writer, stream: anytype, src_node: ?i32) !void {
        const node_offset = src_node orelse return;
        const src: LazySrcLoc = .{ .node_offset = node_offset };
        try stream.writeAll(" ");
        return self.writeSrc(stream, src);
    }

    fn writeBody(self: *Writer, stream: anytype, body: []const Zir.Inst.Index) !void {
        for (body) |inst| {
            try stream.writeByteNTimes(' ', self.indent);
            try stream.print("%{d} ", .{inst});
            try self.writeInstToStream(stream, inst);
            try stream.writeByte('\n');
        }
    }
};