const std = @import("std");

const OutList = std.ArrayList(u8);

pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: OutList = .empty;
    errdefer out.deinit(allocator);

    var in_long_comment = false;
    var long_comment_level: usize = 0;
    var in_long_string = false;
    var long_string_level: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        if (!first_line) try out.append(allocator, '\n');
        first_line = false;

        if (in_long_comment) {
            // Look for closing ]=*]
            if (findLongClose(raw_line, long_comment_level)) |end_pos| {
                in_long_comment = false;
                // Process rest of line after comment close
                if (end_pos < raw_line.len) {
                    try preprocessAndProcessLine(allocator, raw_line[end_pos..], &out, &in_long_comment, &long_comment_level, &in_long_string, &long_string_level);
                }
            }
            // If still in long comment, skip entire line
            continue;
        }

        if (in_long_string) {
            // Emit verbatim until we find the closing ]=*]
            if (findLongClose(raw_line, long_string_level)) |end_pos| {
                // Emit everything up to and including the close bracket
                try out.appendSlice(allocator, raw_line[0..end_pos]);
                in_long_string = false;
                // Process rest of line after long string close
                if (end_pos < raw_line.len) {
                    try preprocessAndProcessLine(allocator, raw_line[end_pos..], &out, &in_long_comment, &long_comment_level, &in_long_string, &long_string_level);
                }
            } else {
                // Still in long string - emit entire line verbatim
                try out.appendSlice(allocator, raw_line);
            }
            continue;
        }

        try preprocessAndProcessLine(allocator, raw_line, &out, &in_long_comment, &long_comment_level, &in_long_string, &long_string_level);
    }

    const raw_output = try out.toOwnedSlice(allocator);
    defer allocator.free(raw_output);

    // Post-pass: insert spaces between number literals and identifiers.
    // PICO-8 allows e.g. "32767for" or ".5and" but Lua 5.2 sees malformed numbers.
    return insertNumberSpaces(allocator, raw_output);
}

/// Insert a space between number literals and immediately following identifiers.
/// Operates on already-preprocessed output so strings are already properly formed.
fn insertNumberSpaces(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var result: OutList = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_str: u8 = 0;
    var in_long_str = false;
    var long_str_level: usize = 0;

    while (i < source.len) {
        const ch = source[i];

        // Track long strings
        if (in_long_str) {
            if (ch == ']' and matchLongClose(source, i, long_str_level)) {
                const close_len = long_str_level + 2;
                try result.appendSlice(allocator, source[i .. i + close_len]);
                i += close_len;
                in_long_str = false;
            } else {
                try result.append(allocator, ch);
                i += 1;
            }
            continue;
        }

        // Track strings
        if (in_str != 0) {
            if (ch == '\\' and i + 1 < source.len) {
                try result.append(allocator, ch);
                i += 1;
                try result.append(allocator, source[i]);
                i += 1;
                continue;
            }
            if (ch == in_str) in_str = 0;
            try result.append(allocator, ch);
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_str = ch;
            try result.append(allocator, ch);
            i += 1;
            continue;
        }
        if (ch == '[') {
            if (matchLongOpen(source, i)) |level| {
                in_long_str = true;
                long_str_level = level;
                const open_len = level + 2;
                try result.appendSlice(allocator, source[i .. i + open_len]);
                i += open_len;
                continue;
            }
        }

        // Skip comments (-- to end of line)
        if (ch == '-' and i + 1 < source.len and source[i + 1] == '-') {
            // Find end of line
            const line_end = std.mem.indexOfScalar(u8, source[i..], '\n') orelse source.len - i;
            try result.appendSlice(allocator, source[i .. i + line_end]);
            i += line_end;
            continue;
        }

        // Check for number literal start (outside strings)
        const is_num_start = blk: {
            if (std.ascii.isDigit(ch)) {
                // Digit starts a number if not preceded by alpha/underscore/dot
                break :blk (i == 0 or (!std.ascii.isAlphanumeric(source[i - 1]) and source[i - 1] != '_' and source[i - 1] != '.'));
            }
            if (ch == '.' and i + 1 < source.len and std.ascii.isDigit(source[i + 1])) {
                // ".5" style number — only if not part of a larger number (e.g. "1.5")
                // In Lua, "obj.5" is invalid syntax, so ".5" after any non-digit/dot is a number.
                break :blk (i == 0 or (!std.ascii.isDigit(source[i - 1]) and source[i - 1] != '.' and !std.ascii.isHex(source[i - 1])));
            }
            break :blk false;
        };

        if (is_num_start) {
            var end = i;
            if (ch == '0' and end + 1 < source.len and (source[end + 1] == 'x' or source[end + 1] == 'X')) {
                // Hex literal: 0x[0-9a-fA-F]+ with optional fractional part
                end += 2;
                while (end < source.len and (std.ascii.isHex(source[end]) or source[end] == '.')) : (end += 1) {}
            } else if (ch == '0' and end + 1 < source.len and (source[end + 1] == 'b' or source[end + 1] == 'B')) {
                // Binary literal: 0b[01.]+ (PICO-8 extension)
                end += 2;
                while (end < source.len and (source[end] == '0' or source[end] == '1' or source[end] == '.')) : (end += 1) {}
            } else {
                // Decimal literal: [0-9]*[.][0-9]*
                while (end < source.len and (std.ascii.isDigit(source[end]) or source[end] == '.')) : (end += 1) {}
            }
            try result.appendSlice(allocator, source[i..end]);
            // Insert space if followed by alpha/underscore to prevent lexer confusion
            if (end < source.len and (std.ascii.isAlphabetic(source[end]) or source[end] == '_')) {
                try result.append(allocator, ' ');
            }
            i = end;
            continue;
        }

        // Insert space between closing bracket/paren and identifier start.
        // E.g. "F(l)t" -> "F(l) t" — these are separate tokens in PICO-8.
        // Do NOT insert before '.' (field access) or digits (indexing).
        if ((ch == ')' or ch == ']') and i + 1 < source.len) {
            try result.append(allocator, ch);
            i += 1;
            const next = source[i];
            if (std.ascii.isAlphabetic(next) or next == '_') {
                try result.append(allocator, ' ');
            }
            continue;
        }

        try result.append(allocator, ch);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Apply pre-passes (token spacing, short-if/while expansion) and then process a line.
fn preprocessAndProcessLine(allocator: std.mem.Allocator, raw_line: []const u8, out: *OutList, in_long_comment: *bool, long_comment_level: *usize, in_long_string: *bool, long_string_level: *usize) !void {
    // Pre-pass 1: Insert spaces between tokens that PICO-8 allows adjacent
    // but Lua 5.2 doesn't (e.g. "32767for", ".5and", ")t").
    const spaced_line = insertNumberSpaces(allocator, raw_line) catch null;
    defer if (spaced_line) |s| allocator.free(s);

    // Pre-pass 2: Expand PICO-8 short-if/short-while.
    const line_after_spaces = spaced_line orelse raw_line;
    const expanded_line = expandShortIfs(allocator, line_after_spaces) catch null;
    defer if (expanded_line) |e| allocator.free(e);

    try processLine(allocator, expanded_line orelse line_after_spaces, out, in_long_comment, long_comment_level, in_long_string, long_string_level);
}

fn processLine(allocator: std.mem.Allocator, line: []const u8, out: *OutList, in_long_comment: *bool, long_comment_level: *usize, in_long_string: *bool, long_string_level: *usize) !void {
    const trimmed = std.mem.trimLeft(u8, line, " \t");

    // ?msg -> print(msg)
    if (trimmed.len > 0 and trimmed[0] == '?') {
        const indent_len = line.len - trimmed.len;
        try out.appendSlice(allocator, line[0..indent_len]);
        try out.appendSlice(allocator, "print(");
        try out.appendSlice(allocator, trimmed[1..]);
        try out.append(allocator, ')');
        return;
    }

    var i: usize = 0;
    var in_string: u8 = 0;

    while (i < line.len) {
        const ch = line[i];

        // Handle long string
        if (in_long_string.*) {
            if (ch == ']' and matchLongClose(line, i, long_string_level.*)) {
                const close_len = long_string_level.* + 2;
                try out.appendSlice(allocator, line[i .. i + close_len]);
                i += close_len;
                in_long_string.* = false;
            } else {
                try out.append(allocator, ch);
                i += 1;
            }
            continue;
        }

        // Handle string
        if (in_string != 0) {
            if (ch == '\\') {
                i += 1;
                if (i < line.len) {
                    const next = line[i];
                    if (isValidLua52Escape(next)) {
                        // Valid Lua 5.2 escape — pass through verbatim
                        try out.append(allocator, '\\');
                        try out.append(allocator, next);
                    } else {
                        // PICO-8-specific escape (e.g. \^, \*, \#, \-, \|, \+)
                        // Emit backslash as \092 so Lua 5.2 sees a literal '\' byte,
                        // followed by the command character as-is.
                        try out.appendSlice(allocator, "\\092");
                        try out.append(allocator, next);
                    }
                    i += 1;
                } else {
                    try out.append(allocator, '\\');
                }
                continue;
            }
            if (ch == in_string) {
                in_string = 0;
            }
            try out.append(allocator, ch);
            i += 1;
            continue;
        }

        // Start comment
        if (ch == '-' and i + 1 < line.len and line[i + 1] == '-') {
            // Check for long comment --[=*[
            if (i + 2 < line.len and line[i + 2] == '[') {
                if (matchLongOpen(line, i + 2)) |level| {
                    // Long comment start - look for close on same line
                    const content_start = i + 2 + level + 2;
                    if (findLongClose(line[content_start..], level)) |close_offset| {
                        // Closes on same line - skip the comment, continue processing
                        i = content_start + close_offset;
                        continue;
                    } else {
                        // Spans multiple lines
                        in_long_comment.* = true;
                        long_comment_level.* = level;
                        return;
                    }
                }
            }
            // Single-line comment -> rest of line verbatim
            try out.appendSlice(allocator, line[i..]);
            return;
        }

        // Start string
        if (ch == '"' or ch == '\'') {
            in_string = ch;
            try out.append(allocator, ch);
            i += 1;
            continue;
        }

        // Start long string
        if (ch == '[') {
            if (matchLongOpen(line, i)) |level| {
                in_long_string.* = true;
                long_string_level.* = level;
                const open_len = level + 2;
                try out.appendSlice(allocator, line[i .. i + open_len]);
                i += open_len;
                continue;
            }
        }

        // P8SCII button glyph characters -> numeric button IDs
        // These special bytes are used in PICO-8 code as shorthand for button numbers
        if (ch >= 0x80) {
            if (p8sciiButtonId(ch)) |btn_str| {
                try out.appendSlice(allocator, btn_str);
            } else {
                // Unknown high byte outside string/comment — drop it
                // (commonly appears in comments as decorative glyphs)
            }
            i += 1;
            continue;
        }

        // != -> ~=
        if (ch == '!' and i + 1 < line.len and line[i + 1] == '=') {
            try out.appendSlice(allocator, "~=");
            i += 2;
            continue;
        }

        // Bitwise operator shorthands (3-char operators, check before 2-char)
        if (i + 2 < line.len) {
            if (ch == '>' and line[i + 1] == '>' and line[i + 2] == '>') {
                // >>> -> lshr(a, b)
                if (tryBitwiseOp(allocator, line, i, 3, "lshr", out)) |new_i| {
                    i = new_i;
                    continue;
                }
            } else if (ch == '<' and line[i + 1] == '<' and line[i + 2] == '>') {
                // <<> -> rotl(a, b)
                if (tryBitwiseOp(allocator, line, i, 3, "rotl", out)) |new_i| {
                    i = new_i;
                    continue;
                }
            } else if (ch == '>' and line[i + 1] == '>' and line[i + 2] == '<') {
                // >>< -> rotr(a, b)
                if (tryBitwiseOp(allocator, line, i, 3, "rotr", out)) |new_i| {
                    i = new_i;
                    continue;
                }
            }
        }
        // 2-char bitwise: >> -> shr, << -> shl, ^^ -> bxor (not power)
        if (i + 1 < line.len) {
            if (ch == '>' and line[i + 1] == '>' and !(i + 2 < line.len and (line[i + 2] == '>' or line[i + 2] == '<'))) {
                if (tryBitwiseOp(allocator, line, i, 2, "shr", out)) |new_i| {
                    i = new_i;
                    continue;
                }
            } else if (ch == '<' and line[i + 1] == '<' and !(i + 2 < line.len and line[i + 2] == '>')) {
                if (tryBitwiseOp(allocator, line, i, 2, "shl", out)) |new_i| {
                    i = new_i;
                    continue;
                }
            } else if (ch == '^' and line[i + 1] == '^') {
                // ^^ -> bxor (not to be confused with Lua's ^ power operator)
                if (tryBitwiseOp(allocator, line, i, 2, "bxor", out)) |new_i| {
                    i = new_i;
                    continue;
                }
            }
        }

        // Binary literals: 0b[01]+
        if (ch == '0' and i + 1 < line.len and (line[i + 1] == 'b' or line[i + 1] == 'B')) {
            if (i == 0 or !std.ascii.isAlphanumeric(line[i - 1])) {
                var end = i + 2;
                while (end < line.len and (line[end] == '0' or line[end] == '1' or line[end] == '.')) : (end += 1) {}
                if (end > i + 2) {
                    const bin_str = line[i + 2 .. end];
                    const val = parseBinaryLiteral(bin_str);
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
                    try out.appendSlice(allocator, s);
                    i = end;
                    continue;
                }
            }
        }

        // Compound assignments
        if (tryCompoundAssign(allocator, line, i, out)) |new_i| {
            i = new_i;
            continue;
        }

        // Integer division: a\b -> flr(a/(b))
        if (ch == '\\' and i + 1 < line.len and line[i + 1] != '=') {
            if (tryIntDiv(allocator, line, i, out)) |new_i| {
                i = new_i;
                continue;
            }
        }

        // Peek shortcuts: @expr -> peek(expr), %expr -> peek2(expr), $expr -> peek4(expr)
        if (ch == '@' or ch == '$' or (ch == '%' and !isPrevValue(line, i))) {
            if (tryPeekShortcut(allocator, line, i, out)) |new_i| {
                i = new_i;
                continue;
            }
        }

        // Single-char bitwise infix: & -> band(), | -> bor()
        // Must come after compound assignment check (so &= and |= are handled first)
        if (ch == '&' and !(i + 1 < line.len and line[i + 1] == '=')) {
            if (tryBitwiseOp(allocator, line, i, 1, "band", out)) |new_i| {
                i = new_i;
                continue;
            }
        }
        if (ch == '|' and !(i + 1 < line.len and line[i + 1] == '=')) {
            if (tryBitwiseOp(allocator, line, i, 1, "bor", out)) |new_i| {
                i = new_i;
                continue;
            }
        }

        // Unary bitwise NOT: ~expr -> bnot(expr)
        // Must distinguish from ~= (not-equal, already valid Lua)
        if (ch == '~' and !(i + 1 < line.len and line[i + 1] == '=')) {
            const expr_info = extractSimpleExpr(line, i + 1);
            if (expr_info.expr.len > 0) {
                try out.appendSlice(allocator, "bnot(");
                try out.appendSlice(allocator, expr_info.expr);
                try out.append(allocator, ')');
                i = expr_info.end;
                continue;
            }
        }

        // Number literals: consume entirely and insert space before following identifier
        // to avoid Lua 5.2 lexer treating e.g. "32767for" or ".5and" as malformed numbers.
        const is_num_start = blk: {
            if (std.ascii.isDigit(ch)) {
                // Digit starts a number if not preceded by alpha/underscore/dot
                break :blk (i == 0 or (!std.ascii.isAlphanumeric(line[i - 1]) and line[i - 1] != '_' and line[i - 1] != '.'));
            }
            if (ch == '.' and i + 1 < line.len and std.ascii.isDigit(line[i + 1])) {
                // ".5" style number — only if not part of a larger number (e.g. "1.5")
                break :blk (i == 0 or (!std.ascii.isDigit(line[i - 1]) and line[i - 1] != '.' and !std.ascii.isHex(line[i - 1])));
            }
            break :blk false;
        };
        if (is_num_start) {
            var end = i;
            if (ch == '0' and end + 1 < line.len and (line[end + 1] == 'x' or line[end + 1] == 'X')) {
                // Hex literal: 0x[0-9a-fA-F]+ with optional fractional part
                end += 2;
                while (end < line.len and (std.ascii.isHex(line[end]) or line[end] == '.')) : (end += 1) {}
            } else {
                // Decimal literal (possibly starting with '.'): [0-9]*[.][0-9]*
                while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '.')) : (end += 1) {}
            }
            try out.appendSlice(allocator, line[i..end]);
            // Insert space if followed by alpha/underscore to prevent lexer confusion
            if (end < line.len and (std.ascii.isAlphabetic(line[end]) or line[end] == '_')) {
                try out.append(allocator, ' ');
            }
            i = end;
            continue;
        }

        try out.append(allocator, ch);
        i += 1;
    }
}

fn tryCompoundAssign(allocator: std.mem.Allocator, line: []const u8, pos: usize, out: *OutList) ?usize {
    const ch = line[pos];

    var op: []const u8 = undefined;
    var op_len: usize = undefined;
    var is_func = false;
    var func_name: []const u8 = undefined;

    if (ch == '.' and pos + 2 < line.len and line[pos + 1] == '.' and line[pos + 2] == '=') {
        op = "..";
        op_len = 3;
    } else if (ch == '^' and pos + 2 < line.len and line[pos + 1] == '^' and line[pos + 2] == '=') {
        is_func = true;
        func_name = "bxor";
        op_len = 3;
    } else if ((ch == '>' or ch == '<') and pos + 2 < line.len and line[pos + 1] == ch and line[pos + 2] == '=') {
        is_func = true;
        func_name = if (ch == '>') "shr" else "shl";
        op_len = 3;
    } else if (pos + 1 < line.len and line[pos + 1] == '=') {
        if (ch == '+' or ch == '-' or ch == '*' or ch == '/' or ch == '%' or ch == '\\' or ch == '^') {
            op = &[_]u8{ch};
            op_len = 2;
        } else if (ch == '|') {
            is_func = true;
            func_name = "bor";
            op_len = 2;
        } else if (ch == '&') {
            is_func = true;
            func_name = "band";
            op_len = 2;
        } else {
            return null;
        }
    } else {
        return null;
    }

    const lhs_result = extractLHS(out.items);
    if (lhs_result.lhs.len == 0) return null;

    // Copy LHS to stack buffer to avoid aliasing with out.items
    var lhs_buf: [256]u8 = undefined;
    if (lhs_result.lhs.len > lhs_buf.len) return null;
    @memcpy(lhs_buf[0..lhs_result.lhs.len], lhs_result.lhs);
    const lhs = lhs_buf[0..lhs_result.lhs.len];

    const rhs_start = pos + op_len;
    const rhs_info = extractRHS(line, rhs_start);
    const raw_rhs = rhs_info.rhs;
    // Preprocess RHS so operators like %src>>>4 get transformed
    const processed_rhs = if (raw_rhs.len > 0) (preprocess(allocator, raw_rhs) catch null) else null;
    defer if (processed_rhs) |p| allocator.free(p);
    const rhs = if (processed_rhs) |p| std.mem.trimRight(u8, p, "\n") else raw_rhs;

    // If RHS is empty (continues on next line), only handle simple op cases
    // where we can emit "lhs = lhs op" and let the next line continue the expression
    if (rhs.len == 0) {
        if (is_func or ch == '\\') return null;
        // Remove LHS + trailing whitespace from output
        out.shrinkRetainingCapacity(out.items.len - lhs_result.remove_count);
        out.appendSlice(allocator, lhs) catch return null;
        out.appendSlice(allocator, " = ") catch return null;
        out.appendSlice(allocator, lhs) catch return null;
        out.append(allocator, ' ') catch return null;
        out.appendSlice(allocator, op) catch return null;
        return rhs_info.end;
    }

    // Remove LHS + trailing whitespace from output
    out.shrinkRetainingCapacity(out.items.len - lhs_result.remove_count);

    if (is_func) {
        out.appendSlice(allocator, lhs) catch return null;
        out.appendSlice(allocator, " = ") catch return null;
        out.appendSlice(allocator, func_name) catch return null;
        out.append(allocator, '(') catch return null;
        out.appendSlice(allocator, lhs) catch return null;
        out.appendSlice(allocator, ", ") catch return null;
        out.appendSlice(allocator, rhs) catch return null;
        out.append(allocator, ')') catch return null;
    } else if (ch == '\\') {
        // \= is integer division assign: a \= b -> a = flr(a/(b))
        out.appendSlice(allocator, lhs) catch return null;
        out.appendSlice(allocator, " = flr(") catch return null;
        out.appendSlice(allocator, lhs) catch return null;
        out.appendSlice(allocator, "/(") catch return null;
        out.appendSlice(allocator, rhs) catch return null;
        out.appendSlice(allocator, "))") catch return null;
    } else {
        out.appendSlice(allocator, lhs) catch return null;
        out.appendSlice(allocator, " = ") catch return null;
        out.appendSlice(allocator, lhs) catch return null;
        out.append(allocator, ' ') catch return null;
        out.appendSlice(allocator, op) catch return null;
        out.appendSlice(allocator, " (") catch return null;
        out.appendSlice(allocator, rhs) catch return null;
        out.append(allocator, ')') catch return null;
    }

    return rhs_info.end;
}

const ShortKw = struct {
    keyword: []const u8,
    len: usize,
    separator: []const u8,
};

/// Check if a keyword matches at the given position with proper word boundaries.
fn matchKeywordAt(line: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > line.len) return false;
    if (!std.mem.eql(u8, line[pos .. pos + keyword.len], keyword)) return false;
    // Word boundary before
    if (pos > 0 and (std.ascii.isAlphanumeric(line[pos - 1]) or line[pos - 1] == '_')) return false;
    // Word boundary after
    if (pos + keyword.len < line.len and (std.ascii.isAlphanumeric(line[pos + keyword.len]) or line[pos + keyword.len] == '_')) return false;
    return true;
}

/// Expand PICO-8 short-if syntax on a line.
/// Short-if: `if (cond) body` (no `then` keyword) -> `if cond then body end`
/// Can appear mid-line and can be nested.
/// Returns null if no short-ifs found, otherwise a newly allocated line.
fn expandShortIfs(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    // Quick check: does the line contain "if" or "while" at all?
    if (std.mem.indexOf(u8, line, "if") == null and std.mem.indexOf(u8, line, "while") == null) return null;

    var result: OutList = .empty;
    errdefer result.deinit(allocator);

    var ends_needed: usize = 0;
    var i: usize = 0;
    var in_str: u8 = 0;

    while (i < line.len) {
        const ch = line[i];

        // Track strings
        if (in_str != 0) {
            if (ch == '\\' and i + 1 < line.len) {
                try result.append(allocator, ch);
                i += 1;
                try result.append(allocator, line[i]);
                i += 1;
                continue;
            }
            if (ch == in_str) in_str = 0;
            try result.append(allocator, ch);
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_str = ch;
            try result.append(allocator, ch);
            i += 1;
            continue;
        }

        // Skip comments
        if (ch == '-' and i + 1 < line.len and line[i + 1] == '-') {
            // Rest of line is a comment, emit verbatim
            try result.appendSlice(allocator, line[i..]);
            break;
        }

        // Check for short-if: if(cond) body -> if cond then body end
        // Check for short-while: while(cond) body -> while cond do body end
        const short_kw: ?ShortKw = if (ch == 'i' and matchKeywordAt(line, i, "if"))
            ShortKw{ .keyword = "if", .len = 2, .separator = "then" }
        else if (ch == 'w' and matchKeywordAt(line, i, "while"))
            ShortKw{ .keyword = "while", .len = 5, .separator = "do" }
        else
            null;
        if (short_kw) |kw| {
            // Skip whitespace after keyword
            var j = i + kw.len;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}

            if (j < line.len and line[j] == '(') {
                // Find matching close paren
                var depth: i32 = 0;
                var k = j;
                var paren_str: u8 = 0;
                while (k < line.len) : (k += 1) {
                    if (paren_str != 0) {
                        if (line[k] == '\\' and k + 1 < line.len) {
                            k += 1;
                            continue;
                        }
                        if (line[k] == paren_str) paren_str = 0;
                        continue;
                    }
                    if (line[k] == '"' or line[k] == '\'') {
                        paren_str = line[k];
                        continue;
                    }
                    if (line[k] == '(') depth += 1;
                    if (line[k] == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }

                if (depth == 0 and k < line.len) {
                    // k points to closing ')'
                    // Check if separator keyword follows (skip whitespace)
                    var after = k + 1;
                    while (after < line.len and (line[after] == ' ' or line[after] == '\t')) : (after += 1) {}

                    // Check if separator keyword appears anywhere after the closing paren.
                    // If it does, this is a normal if/while, not a short form.
                    // e.g. `if (self.timer or 0) < 5 then` has `then` after `)`.
                    const rest_after_paren = line[k + 1 ..];
                    const has_sep = hasSeparatorKeyword(rest_after_paren, kw.separator);

                    if (!has_sep) {
                        // Short form detected! Check if body is non-empty
                        const body_start = k + 1;
                        const rest = std.mem.trimLeft(u8, line[body_start..], " \t");
                        if (rest.len > 0) {
                            // Emit: keyword COND separator
                            try result.appendSlice(allocator, kw.keyword);
                            try result.append(allocator, ' ');
                            try result.appendSlice(allocator, line[j + 1 .. k]); // condition (inside parens)
                            try result.append(allocator, ' ');
                            try result.appendSlice(allocator, kw.separator);
                            try result.append(allocator, ' ');
                            ends_needed += 1;
                            i = body_start;
                            continue;
                        }
                    }
                }
            }
        }

        try result.append(allocator, ch);
        i += 1;
    }

    if (ends_needed == 0) {
        result.deinit(allocator);
        return null;
    }

    // Append 'end' for each short-if
    while (ends_needed > 0) : (ends_needed -= 1) {
        try result.appendSlice(allocator, " end");
    }

    const slice = try result.toOwnedSlice(allocator);
    return slice;
}

const RHSResult = struct { rhs: []const u8, end: usize };

fn extractRHS(line: []const u8, start: usize) RHSResult {
    var i = start;
    // Skip leading whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const rhs_start = i;
    var depth: i32 = 0;
    var in_str: u8 = 0;

    while (i < line.len) {
        const ch = line[i];

        // Track strings
        if (in_str != 0) {
            if (ch == '\\') {
                i += 1;
                if (i < line.len) i += 1;
                continue;
            }
            if (ch == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_str = ch;
            i += 1;
            continue;
        }

        // Stop at comment start (-- outside strings)
        if (ch == '-' and i + 1 < line.len and line[i + 1] == '-') {
            break;
        }

        // Track parens/brackets
        if (ch == '(' or ch == '[') {
            depth += 1;
            i += 1;
            continue;
        }
        if (ch == ')' or ch == ']') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }

        // At depth 0, check for statement keywords
        if (depth == 0 and std.ascii.isAlphabetic(ch)) {
            if (isStatementKeyword(line, i)) break;
        }

        // At depth 0, detect statement boundary: value followed by space then identifier.
        // In Lua, two values can't be adjacent (without an operator between them),
        // so "expr identifier" at depth 0 means a new statement is starting.
        if (depth == 0 and (ch == ' ' or ch == '\t') and i > rhs_start) {
            const prev = line[i - 1];
            const prev_is_value = std.ascii.isAlphanumeric(prev) or prev == '_' or prev == ')' or prev == ']';
            if (prev_is_value) {
                // Skip whitespace to see what follows
                var peek = i;
                while (peek < line.len and (line[peek] == ' ' or line[peek] == '\t')) : (peek += 1) {}
                if (peek < line.len and (std.ascii.isAlphabetic(line[peek]) or line[peek] == '_')) {
                    // Check it's not an operator keyword: and, or, not
                    const is_op_kw = isOperatorKeyword(line, peek);
                    if (!is_op_kw) {
                        // This is a new statement — stop here
                        break;
                    }
                }
            }
        }

        // At depth 0, check for assignment/compound assignment that starts a new statement.
        // E.g. in "expr1 n.y+=expr2", stop before "n.y".
        if (depth == 0 and ch == '=' and i > rhs_start) {
            // Determine what kind of '=' this is
            const prev = line[i - 1];
            // Skip comparison operators: ==, ~=, <=, >=, !=
            if (prev == '=' or prev == '~' or prev == '<' or prev == '>' or prev == '!') {
                i += 1;
                continue;
            }
            // This is a plain '=' or compound assignment (+=, -=, *=, /=, %=, \=, |=, &=)
            // Back up past the operator to find the LHS start
            var lhs_end = i;
            if (prev == '+' or prev == '-' or prev == '*' or prev == '/' or
                prev == '%' or prev == '\\' or prev == '|' or prev == '&')
            {
                lhs_end = i - 1; // skip the operator char
            }
            // Also handle multi-char compound ops: ..=, >>=, <<=, ^^=
            if (lhs_end >= 2) {
                const pp = line[lhs_end - 1];
                if ((prev == '.' and pp == '.') or // ..=
                    (prev == '>' and pp == '>') or // >>=
                    (prev == '<' and pp == '<') or // <<=
                    (prev == '^' and pp == '^')) // ^^=
                {
                    lhs_end -= 1; // skip the second operator char too
                }
            }
            // Now back up past whitespace
            while (lhs_end > rhs_start and (line[lhs_end - 1] == ' ' or line[lhs_end - 1] == '\t')) : (lhs_end -= 1) {}
            // The LHS should be an identifier-like thing (alpha, digit, _, ., ], [)
            if (lhs_end > rhs_start) {
                const lhs_last = line[lhs_end - 1];
                if (std.ascii.isAlphanumeric(lhs_last) or lhs_last == '_' or lhs_last == ']') {
                    // Find start of LHS (back up past identifier chars)
                    var lhs_start = lhs_end;
                    while (lhs_start > rhs_start) {
                        const c = line[lhs_start - 1];
                        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '[' or c == ']') {
                            lhs_start -= 1;
                        } else {
                            break;
                        }
                    }
                    // Only stop if the LHS is distinct from the RHS start
                    // (i.e., there's actual expression content before the LHS)
                    if (lhs_start > rhs_start) {
                        // Trim trailing whitespace
                        var stop = lhs_start;
                        while (stop > rhs_start and (line[stop - 1] == ' ' or line[stop - 1] == '\t')) : (stop -= 1) {}
                        return .{ .rhs = line[rhs_start..stop], .end = lhs_start };
                    }
                }
            }
        }

        i += 1;
    }

    // Trim trailing whitespace from RHS
    var end = i;
    while (end > rhs_start and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}

    return .{ .rhs = line[rhs_start..end], .end = i };
}

/// Check if a separator keyword (then/do) appears as a whole word in the text,
/// outside of strings. Used to distinguish short-if from normal if.
fn hasSeparatorKeyword(text: []const u8, sep: []const u8) bool {
    var j: usize = 0;
    var in_str: u8 = 0;
    while (j < text.len) : (j += 1) {
        if (in_str != 0) {
            if (text[j] == '\\' and j + 1 < text.len) { j += 1; continue; }
            if (text[j] == in_str) in_str = 0;
            continue;
        }
        if (text[j] == '"' or text[j] == '\'') { in_str = text[j]; continue; }
        if (text[j] == '-' and j + 1 < text.len and text[j + 1] == '-') break; // comment
        if (j + sep.len <= text.len and std.mem.eql(u8, text[j .. j + sep.len], sep)) {
            const before_ok = (j == 0 or (!std.ascii.isAlphanumeric(text[j - 1]) and text[j - 1] != '_'));
            const after_ok = (j + sep.len >= text.len or (!std.ascii.isAlphanumeric(text[j + sep.len]) and text[j + sep.len] != '_'));
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

fn isStatementKeyword(line: []const u8, pos: usize) bool {
    const keywords = [_][]const u8{
        "return", "end", "if", "then", "else", "elseif",
        "do", "while", "for", "repeat", "until", "local", "break", "goto",
    };
    // Check word boundary before — only alpha/underscore counts as part of an identifier.
    // Digits do NOT prevent keyword recognition: in PICO-8, "1return" is number + keyword.
    if (pos > 0 and (std.ascii.isAlphabetic(line[pos - 1]) or line[pos - 1] == '_')) return false;

    for (keywords) |kw| {
        if (pos + kw.len <= line.len and std.mem.eql(u8, line[pos .. pos + kw.len], kw)) {
            // Check word boundary after
            if (pos + kw.len < line.len) {
                const next = line[pos + kw.len];
                if (std.ascii.isAlphanumeric(next) or next == '_') continue;
            }
            return true;
        }
    }
    return false;
}

/// Check if the identifier at pos is an operator keyword (and, or, not)
/// that can appear within an expression.
fn isOperatorKeyword(line: []const u8, pos: usize) bool {
    const keywords = [_][]const u8{ "and", "or", "not" };
    for (keywords) |kw| {
        if (pos + kw.len <= line.len and std.mem.eql(u8, line[pos .. pos + kw.len], kw)) {
            // Check word boundary after
            if (pos + kw.len < line.len) {
                const next = line[pos + kw.len];
                if (std.ascii.isAlphanumeric(next) or next == '_') continue;
            }
            return true;
        }
    }
    return false;
}

const LHSResult = struct { lhs: []const u8, remove_count: usize };

fn extractLHS(output: []const u8) LHSResult {
    var end = output.len;
    // Skip trailing whitespace (between LHS and operator)
    while (end > 0 and (output[end - 1] == ' ' or output[end - 1] == '\t')) : (end -= 1) {}
    var start = end;
    // Walk backward over identifiers, indexing, and function calls (matched parens)
    while (start > 0) {
        const ch = output[start - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ']' or ch == '[') {
            start -= 1;
        } else if (ch == ')') {
            // Walk backward to matching '('
            var depth: i32 = 1;
            start -= 1;
            while (start > 0 and depth > 0) {
                start -= 1;
                if (output[start] == ')') depth += 1;
                if (output[start] == '(') depth -= 1;
            }
            // Continue backward to include function name before '('
        } else {
            break;
        }
    }
    return .{ .lhs = output[start..end], .remove_count = output.len - start };
}

/// Find the end of a long close bracket ]=*] in the given text.
/// Returns the position AFTER the closing bracket, or null if not found.
fn findLongClose(text: []const u8, level: usize) ?usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ']' and matchLongClose(text, i, level)) {
            return i + level + 2;
        }
    }
    return null;
}

fn matchLongOpen(source: []const u8, pos: usize) ?usize {
    if (pos >= source.len or source[pos] != '[') return null;
    var level: usize = 0;
    var i = pos + 1;
    while (i < source.len and source[i] == '=') : (i += 1) {
        level += 1;
    }
    if (i < source.len and source[i] == '[') return level;
    return null;
}

fn matchLongClose(source: []const u8, pos: usize, level: usize) bool {
    if (pos >= source.len or source[pos] != ']') return false;
    var i = pos + 1;
    var count: usize = 0;
    while (i < source.len and source[i] == '=' and count < level) : (i += 1) {
        count += 1;
    }
    if (count == level and i < source.len and source[i] == ']') return true;
    return false;
}

fn tryIntDiv(allocator: std.mem.Allocator, line: []const u8, pos: usize, out: *OutList) ?usize {
    // Extract LHS from output buffer
    const lhs_result = extractLHS(out.items);
    if (lhs_result.lhs.len == 0) return null;

    // Copy LHS to stack buffer to avoid aliasing
    var lhs_buf: [256]u8 = undefined;
    if (lhs_result.lhs.len > lhs_buf.len) return null;
    @memcpy(lhs_buf[0..lhs_result.lhs.len], lhs_result.lhs);
    const lhs = lhs_buf[0..lhs_result.lhs.len];

    // Extract RHS after the backslash
    const rhs_info = extractSimpleExpr(line, pos + 1);
    if (rhs_info.expr.len == 0) return null;

    // Remove LHS from output
    out.shrinkRetainingCapacity(out.items.len - lhs_result.remove_count);

    out.appendSlice(allocator, "flr(") catch return null;
    out.appendSlice(allocator, lhs) catch return null;
    out.appendSlice(allocator, "/(") catch return null;
    out.appendSlice(allocator, rhs_info.expr) catch return null;
    out.appendSlice(allocator, "))") catch return null;

    return rhs_info.end;
}

fn tryBitwiseOp(allocator: std.mem.Allocator, line: []const u8, pos: usize, op_len: usize, func_name: []const u8, out: *OutList) ?usize {
    // Extract LHS from output buffer
    const lhs_result = extractLHS(out.items);
    if (lhs_result.lhs.len == 0) return null;

    // Copy LHS to stack buffer to avoid aliasing
    var lhs_buf: [256]u8 = undefined;
    if (lhs_result.lhs.len > lhs_buf.len) return null;
    @memcpy(lhs_buf[0..lhs_result.lhs.len], lhs_result.lhs);
    const lhs = lhs_buf[0..lhs_result.lhs.len];

    // Extract RHS after the operator — use full arithmetic expression
    // since bitwise ops have lower precedence than +, -, *, / in PICO-8
    const rhs_info = extractBitwiseRHS(line, pos + op_len);
    if (rhs_info.expr.len == 0) return null;

    // Remove LHS from output
    out.shrinkRetainingCapacity(out.items.len - lhs_result.remove_count);

    out.appendSlice(allocator, func_name) catch return null;
    out.append(allocator, '(') catch return null;
    out.appendSlice(allocator, lhs) catch return null;
    out.appendSlice(allocator, ",") catch return null;
    out.appendSlice(allocator, rhs_info.expr) catch return null;
    out.append(allocator, ')') catch return null;

    return rhs_info.end;
}

/// Extract RHS for bitwise operators. Bitwise ops have lower precedence than
/// arithmetic, so the RHS includes +, -, *, / expressions.
/// Stops at bitwise operators, commas, semicolons, and statement keywords.
fn extractBitwiseRHS(line: []const u8, start: usize) struct { expr: []const u8, end: usize } {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const expr_start = i;
    var depth: i32 = 0;
    var in_str: u8 = 0;
    while (i < line.len) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\') { i += 1; if (i < line.len) i += 1; continue; }
            if (ch == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') { in_str = ch; i += 1; continue; }
        if (ch == '(' or ch == '[') { depth += 1; i += 1; continue; }
        if (ch == ')' or ch == ']') {
            if (depth > 0) { depth -= 1; i += 1; continue; }
            break;
        }
        if (depth == 0) {
            // Stop at bitwise operators, delimiters, and comparison ops
            if (ch == ',' or ch == ';' or ch == ' ' or ch == '\t' or
                ch == '>' or ch == '<' or ch == '=' or ch == '~' or
                ch == '&' or ch == '|' or ch == '}' or ch == '{')
                break;
            // Stop at ^^ but not ^
            if (ch == '^' and i + 1 < line.len and line[i + 1] == '^') break;
            if (std.ascii.isAlphabetic(ch) and isStatementKeyword(line, i)) break;
        }
        i += 1;
    }
    // Trim trailing whitespace
    var end = i;
    while (end > expr_start and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
    return .{ .expr = line[expr_start..end], .end = i };
}

/// Extract a simple expression for RHS of \ or peek shortcut.
/// Stops at operators, spaces, commas, and statement keywords at depth 0.
fn extractSimpleExpr(line: []const u8, start: usize) struct { expr: []const u8, end: usize } {
    var i = start;
    // Skip leading whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const expr_start = i;
    var depth: i32 = 0;
    var in_str: u8 = 0;

    while (i < line.len) {
        const ch = line[i];

        if (in_str != 0) {
            if (ch == '\\') {
                i += 1;
                if (i < line.len) i += 1;
                continue;
            }
            if (ch == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_str = ch;
            i += 1;
            continue;
        }

        if (ch == '(' or ch == '[') {
            depth += 1;
            i += 1;
            continue;
        }
        if (ch == ')' or ch == ']') {
            if (depth > 0) {
                depth -= 1;
                i += 1;
                continue;
            }
            break; // unmatched close - stop
        }

        if (depth == 0) {
            // Stop at operators and delimiters
            if (ch == '+' or ch == '-' or ch == '*' or ch == '/' or ch == '%' or
                ch == '\\' or ch == ',' or ch == ';' or ch == ' ' or ch == '\t' or
                ch == '<' or ch == '>' or ch == '=' or ch == '~' or ch == '}' or
                ch == '{')
            {
                break;
            }
            // Stop at statement keywords
            if (std.ascii.isAlphabetic(ch) and isStatementKeyword(line, i)) break;
        }

        i += 1;
    }

    return .{ .expr = line[expr_start..i], .end = i };
}

fn tryPeekShortcut(allocator: std.mem.Allocator, line: []const u8, pos: usize, out: *OutList) ?usize {
    const ch = line[pos];
    const func_name: []const u8 = switch (ch) {
        '@' => "peek",
        '%' => "peek2",
        '$' => "peek4",
        else => return null,
    };

    // The character after the shortcut should be the start of an expression
    if (pos + 1 >= line.len) return null;
    const next = line[pos + 1];
    // Must be followed by something that starts an expression
    if (!std.ascii.isAlphanumeric(next) and next != '(' and next != '_' and next != '-') return null;

    const expr_info = extractSimpleExpr(line, pos + 1);
    if (expr_info.expr.len == 0) return null;

    out.appendSlice(allocator, func_name) catch return null;
    out.append(allocator, '(') catch return null;
    out.appendSlice(allocator, expr_info.expr) catch return null;
    out.append(allocator, ')') catch return null;

    return expr_info.end;
}

fn isPrevValue(line: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    const prev = line[pos - 1];
    return std.ascii.isAlphanumeric(prev) or prev == '_' or prev == ')' or prev == ']';
}

fn parseBinaryLiteral(s: []const u8) f64 {
    var int_part: u32 = 0;
    var frac_part: f64 = 0;
    var in_frac = false;
    var frac_denom: f64 = 1;

    for (s) |ch| {
        if (ch == '.') {
            in_frac = true;
            continue;
        }
        if (in_frac) {
            frac_denom *= 2;
            if (ch == '1') frac_part += 1.0 / frac_denom;
        } else {
            int_part = (int_part << 1) | @as(u32, if (ch == '1') 1 else 0);
        }
    }
    return @as(f64, @floatFromInt(int_part)) + frac_part;
}

/// Check if a character following '\' is a valid Lua 5.2 escape sequence start.
/// Valid: \a \b \f \n \r \t \v \\ \" \' \[ \] \z \xNN \0-\9 (decimal digits)
fn isValidLua52Escape(ch: u8) bool {
    return switch (ch) {
        'a', 'b', 'f', 'n', 'r', 't', 'v', '\\', '"', '\'', '[', ']', 'z', 'x' => true,
        '0'...'9' => true,
        else => false,
    };
}

/// Map P8SCII special glyph bytes to their PICO-8 button ID strings.
/// In PICO-8, these characters can be used directly as btn()/btnp() arguments.
fn p8sciiButtonId(ch: u8) ?[]const u8 {
    return switch (ch) {
        0x83 => "3", // ⬇️ down
        0x8B => "0", // ⬅️ left
        0x8E => "5", // ❎ X button
        0x91 => "1", // ➡️ right
        0x94 => "2", // ⬆️ up  (also 🅾️ in some references)
        0x97 => "4", // 🅾️ O button (also ⬆️ in some references)
        else => null,
    };
}
