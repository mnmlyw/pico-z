const std = @import("std");

const OutList = std.ArrayList(u8);

pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: OutList = .empty;
    errdefer out.deinit(allocator);

    var in_long_comment = false;
    var long_comment_level: usize = 0;

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
                    try processLine(allocator, raw_line[end_pos..], &out, &in_long_comment, &long_comment_level);
                }
            }
            // If still in long comment, skip entire line
            continue;
        }

        try processLine(allocator, raw_line, &out, &in_long_comment, &long_comment_level);
    }

    return out.toOwnedSlice(allocator);
}

fn processLine(allocator: std.mem.Allocator, line: []const u8, out: *OutList, in_long_comment: *bool, long_comment_level: *usize) !void {
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

    // Short-if: if (cond) stmt -> if cond then stmt end
    if (tryShortIf(allocator, trimmed, out, line.len - trimmed.len)) return;

    var i: usize = 0;
    var in_string: u8 = 0;
    var in_long_string = false;
    var long_string_level: usize = 0;

    while (i < line.len) {
        const ch = line[i];

        // Handle long string
        if (in_long_string) {
            if (ch == ']' and matchLongClose(line, i, long_string_level)) {
                const close_len = long_string_level + 2;
                try out.appendSlice(allocator, line[i .. i + close_len]);
                i += close_len;
                in_long_string = false;
            } else {
                try out.append(allocator, ch);
                i += 1;
            }
            continue;
        }

        // Handle string
        if (in_string != 0) {
            if (ch == '\\') {
                try out.append(allocator, ch);
                i += 1;
                if (i < line.len) {
                    try out.append(allocator, line[i]);
                    i += 1;
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
                in_long_string = true;
                long_string_level = level;
                const open_len = level + 2;
                try out.appendSlice(allocator, line[i .. i + open_len]);
                i += open_len;
                continue;
            }
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
        if (ch == '+' or ch == '-' or ch == '*' or ch == '/' or ch == '%' or ch == '\\') {
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
    const rhs = rhs_info.rhs;
    if (rhs.len == 0) return null;

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

fn tryShortIf(allocator: std.mem.Allocator, trimmed: []const u8, out: *OutList, indent: usize) bool {
    // Match: if (cond) stmt   where there's no 'then' on the line
    if (!startsWith(trimmed, "if")) return false;
    if (trimmed.len < 3) return false;

    var i: usize = 2;
    // Skip spaces after 'if'
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
    if (i >= trimmed.len or trimmed[i] != '(') return false;

    // Check no 'then' on this line (outside strings)
    if (containsKeyword(trimmed, "then")) return false;

    // Find matching close paren
    var depth: i32 = 0;
    var j = i;
    while (j < trimmed.len) : (j += 1) {
        if (trimmed[j] == '(') depth += 1;
        if (trimmed[j] == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (depth != 0) return false;

    const cond = trimmed[i + 1 .. j]; // inside parens
    const rest_start = j + 1;
    const rest = std.mem.trim(u8, trimmed[rest_start..], " \t");
    if (rest.len == 0) return false;

    // Check for else clause: "if (cond) stmt1 else stmt2"
    var stmt1 = rest;
    var stmt2: ?[]const u8 = null;
    if (findKeywordInStmt(rest, "else")) |else_pos| {
        stmt1 = std.mem.trim(u8, rest[0..else_pos], " \t");
        stmt2 = std.mem.trim(u8, rest[else_pos + 4 ..], " \t");
    }

    // Write: [indent]if cond then stmt1 [else stmt2] end
    var k: usize = 0;
    while (k < indent) : (k += 1) {
        out.append(allocator, ' ') catch return false;
    }
    out.appendSlice(allocator, "if ") catch return false;
    out.appendSlice(allocator, cond) catch return false;
    out.appendSlice(allocator, " then ") catch return false;
    out.appendSlice(allocator, stmt1) catch return false;
    if (stmt2) |s2| {
        out.appendSlice(allocator, " else ") catch return false;
        out.appendSlice(allocator, s2) catch return false;
    }
    out.appendSlice(allocator, " end") catch return false;
    return true;
}

fn findKeywordInStmt(text: []const u8, keyword: []const u8) ?usize {
    var i: usize = 0;
    var depth: i32 = 0;
    var in_str: u8 = 0;
    while (i < text.len) {
        const ch = text[i];
        if (in_str != 0) {
            if (ch == '\\') {
                i += 2;
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
        } else if (ch == ')' or ch == ']') {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0 and i + keyword.len <= text.len) {
            if (std.mem.eql(u8, text[i .. i + keyword.len], keyword)) {
                if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) {
                    i += 1;
                    continue;
                }
                if (i + keyword.len < text.len and (std.ascii.isAlphanumeric(text[i + keyword.len]) or text[i + keyword.len] == '_')) {
                    i += 1;
                    continue;
                }
                return i;
            }
        }
        i += 1;
    }
    return null;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    if (!std.mem.eql(u8, s[0..prefix.len], prefix)) return false;
    // Must not be followed by alnum or _
    if (s.len > prefix.len) {
        const next = s[prefix.len];
        if (std.ascii.isAlphanumeric(next) or next == '_') return false;
    }
    return true;
}

fn containsKeyword(line: []const u8, keyword: []const u8) bool {
    var i: usize = 0;
    while (i + keyword.len <= line.len) : (i += 1) {
        if (std.mem.eql(u8, line[i .. i + keyword.len], keyword)) {
            // Check word boundaries
            if (i > 0 and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_')) continue;
            if (i + keyword.len < line.len and (std.ascii.isAlphanumeric(line[i + keyword.len]) or line[i + keyword.len] == '_')) continue;
            return true;
        }
    }
    return false;
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

        i += 1;
    }

    // Trim trailing whitespace from RHS
    var end = i;
    while (end > rhs_start and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}

    return .{ .rhs = line[rhs_start..end], .end = i };
}

fn isStatementKeyword(line: []const u8, pos: usize) bool {
    const keywords = [_][]const u8{
        "return", "end", "if", "then", "else", "elseif",
        "do", "while", "for", "repeat", "until", "local", "break", "goto",
    };
    // Check word boundary before
    if (pos > 0 and (std.ascii.isAlphanumeric(line[pos - 1]) or line[pos - 1] == '_')) return false;

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
    while (start > 0) {
        const ch = output[start - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ']' or ch == '[') {
            start -= 1;
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

    // Extract RHS after the operator
    const rhs_info = extractSimpleExpr(line, pos + op_len);
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
