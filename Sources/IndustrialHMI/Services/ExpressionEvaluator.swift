// MARK: - ExpressionEvaluator.swift
//
// Recursive-descent expression parser and evaluator for calculated tags.
//
// ── Architecture ──────────────────────────────────────────────────────────────
//   Source string ──► Tokenizer ──► Token stream ──► Parser ──► ExprNode AST
//                                                                     │
//                                                         ExpressionEvaluator.evaluate()
//                                                                     │
//                                                            EvalResult { TagValue, TagQuality }
//
// ── Tag References ────────────────────────────────────────────────────────────
//   Use curly brace syntax: {TagName}. The Tokenizer emits .tagRef("TagName").
//   The evaluator looks up the tag in the live TagEngine.tags dictionary and
//   propagates the worst quality across all referenced tags in the expression.
//   Missing tags are treated as 0.0 with quality = .bad.
//
// ── Supported Syntax ──────────────────────────────────────────────────────────
//   Arithmetic:   + - * /
//   Comparison:   > < >= <= == !=
//   Logical:      && || !
//   Ternary:      condition ? thenValue : elseValue
//   IF keyword:   if <cond> then <thenValue> else <elseValue>
//   Literals:     integer/decimal numbers, true, false
//   Functions:    abs, sqrt, round, floor, ceil, sign, min, max, avg, sum, clamp, if
//   Grouping:     (expr)
//
// ── Grammar (low → high precedence) ──────────────────────────────────────────
//   expr           = ternary
//   ternary        = or [ '?' or ':' or ]
//   or             = and ( '||' and )*
//   and            = equality ( '&&' equality )*
//   equality       = comparison ( ('=='|'!=') comparison )*
//   comparison     = additive ( ('>'|'<'|'>='|'<=') additive )*
//   additive       = multiplicative ( ('+'|'-') multiplicative )*
//   multiplicative = unary ( ('*'|'/') unary )*
//   unary          = ('-'|'!') unary | primary
//   primary        = NUMBER | BOOL | TAGREF | '(' expr ')' | IDENT args | IF-THEN-ELSE
//
// ── Integration with TagEngine ────────────────────────────────────────────────
//   TagEngine pre-parses each calculated tag's expression into an ExprNode AST
//   at tag registration time (avoiding per-update parse overhead).
//   ExpressionParser.extractTagRefs() provides a fast scan (no full parse) used
//   by TagEngine to build the bidirectional expression dependency graph:
//     expressionDeps[calcTag] = Set<depTag>
//     expressionDependents[depTag] += calcTag
//   When a source tag updates, only its direct dependents are re-evaluated.
//
// ── Error Handling ────────────────────────────────────────────────────────────
//   ExprError: syntaxError, unknownFunction, divisionByZero, circularDependency
//   The non-throwing evaluate(_:tags:) variant catches all errors, logs them,
//   and returns EvalResult(value: .none, quality: .bad) — safe for hot path use.

import Foundation

// MARK: - Errors

enum ExprError: LocalizedError {
    case syntaxError(String)
    case unknownFunction(String)
    case divisionByZero
    case circularDependency(String)

    var errorDescription: String? {
        switch self {
        case .syntaxError(let s):      return "Expression syntax error: \(s)"
        case .unknownFunction(let f):  return "Unknown function: '\(f)'"
        case .divisionByZero:          return "Division by zero in expression"
        case .circularDependency(let n): return "Circular dependency detected for tag '\(n)'"
        }
    }
}

// MARK: - Tokens (private to this file)

private enum Token: Equatable {
    case number(Double)
    case bool(Bool)
    case tagRef(String)     // {TagName}
    case ident(String)      // function name or if/then/else keyword
    case op(String)         // +  -  *  /  >  <  >=  <=  ==  !=  &&  ||  !  ?  :
    case lparen, rparen, comma
    case eof
}

// MARK: - AST

indirect enum ExprNode {
    case number(Double)
    case bool(Bool)
    case tagRef(String)
    case binary(BinOp, ExprNode, ExprNode)
    case unary(UnOp, ExprNode)
    case ternary(ExprNode, ExprNode, ExprNode)   // condition ? then : else
    case call(String, [ExprNode])
}

enum BinOp {
    case add, sub, mul, div
    case gt, lt, gte, lte, eq, ne
    case and, or
}

enum UnOp { case neg, not }

// MARK: - Evaluation Result

struct EvalResult {
    var value:   TagValue
    var quality: TagQuality
}

// MARK: - Tokenizer

private struct Tokenizer {
    let src: [Character]
    var pos: Int = 0

    init(_ s: String) { src = Array(s) }

    mutating func nextToken() throws -> Token {
        // skip whitespace
        while pos < src.count && src[pos].isWhitespace { pos += 1 }
        guard pos < src.count else { return .eof }
        let c = src[pos]

        // Tag reference: {TagName}
        if c == "{" {
            pos += 1
            var name = ""
            while pos < src.count && src[pos] != "}" { name.append(src[pos]); pos += 1 }
            guard pos < src.count else { throw ExprError.syntaxError("Unclosed '{'") }
            pos += 1
            guard !name.isEmpty else { throw ExprError.syntaxError("Empty tag reference {}") }
            return .tagRef(name)
        }

        // Numeric literal (integer or decimal, no scientific notation)
        if c.isNumber || (c == "." && pos + 1 < src.count && src[pos + 1].isNumber) {
            var num = ""
            while pos < src.count && (src[pos].isNumber || src[pos] == ".") {
                num.append(src[pos]); pos += 1
            }
            guard let d = Double(num) else { throw ExprError.syntaxError("Invalid number: '\(num)'") }
            return .number(d)
        }

        // Identifiers, keywords, and named constants
        if c.isLetter || c == "_" {
            var id = ""
            while pos < src.count && (src[pos].isLetter || src[pos].isNumber || src[pos] == "_") {
                id.append(src[pos]); pos += 1
            }
            switch id.lowercased() {
            case "true":  return .bool(true)
            case "false": return .bool(false)
            case "if":    return .ident("if")
            case "then":  return .ident("then")
            case "else":  return .ident("else")
            default:      return .ident(id)
            }
        }

        // Operators and punctuation
        pos += 1
        switch c {
        case "(": return .lparen
        case ")": return .rparen
        case ",": return .comma
        case "+": return .op("+")
        case "-": return .op("-")
        case "*": return .op("*")
        case "/": return .op("/")
        case "?": return .op("?")
        case ":": return .op(":")
        case "!":
            if pos < src.count && src[pos] == "=" { pos += 1; return .op("!=") }
            return .op("!")
        case ">":
            if pos < src.count && src[pos] == "=" { pos += 1; return .op(">=") }
            return .op(">")
        case "<":
            if pos < src.count && src[pos] == "=" { pos += 1; return .op("<=") }
            return .op("<")
        case "=":
            guard pos < src.count && src[pos] == "=" else {
                throw ExprError.syntaxError("Use '==' for equality, not '='")
            }
            pos += 1; return .op("==")
        case "&":
            guard pos < src.count && src[pos] == "&" else {
                throw ExprError.syntaxError("Use '&&' for logical AND, not '&'")
            }
            pos += 1; return .op("&&")
        case "|":
            guard pos < src.count && src[pos] == "|" else {
                throw ExprError.syntaxError("Use '||' for logical OR, not '|'")
            }
            pos += 1; return .op("||")
        default:
            throw ExprError.syntaxError("Unexpected character '\(c)'")
        }
    }
}

// MARK: - Recursive-Descent Parser

private struct Parser {
    var tokenizer: Tokenizer
    var lookahead: Token? = nil

    init(_ source: String) { tokenizer = Tokenizer(source) }

    mutating func peek() throws -> Token {
        if lookahead == nil { lookahead = try tokenizer.nextToken() }
        return lookahead!
    }

    @discardableResult
    mutating func consume() throws -> Token {
        if let t = lookahead { lookahead = nil; return t }
        return try tokenizer.nextToken()
    }

    mutating func expect(op expected: String) throws {
        let t = try consume()
        guard t == .op(expected) else {
            throw ExprError.syntaxError("Expected '\(expected)'")
        }
    }

    mutating func expect(ident expected: String) throws {
        let t = try consume()
        guard t == .ident(expected) else {
            throw ExprError.syntaxError("Expected '\(expected.uppercased())'")
        }
    }

    // Grammar (low → high precedence):
    //   expr         = ternary
    //   ternary      = or [ '?' or ':' or ]
    //   or           = and ( '||' and )*
    //   and          = equality ( '&&' equality )*
    //   equality     = comparison ( ('=='|'!=') comparison )*
    //   comparison   = additive ( ('>'|'<'|'>='|'<=') additive )*
    //   additive     = multiplicative ( ('+'|'-') multiplicative )*
    //   multiplicative = unary ( ('*'|'/') unary )*
    //   unary        = ('-'|'!') unary | primary
    //   primary      = NUMBER | BOOL | TAGREF | '(' expr ')' | IDENT args | IF-THEN-ELSE

    mutating func parseExpr() throws -> ExprNode {
        let left = try parseOr()
        if try peek() == .op("?") {
            try consume()
            let thenNode = try parseOr()
            try expect(op: ":")
            let elseNode = try parseOr()
            return .ternary(left, thenNode, elseNode)
        }
        return left
    }

    mutating func parseOr() throws -> ExprNode {
        var node = try parseAnd()
        while try peek() == .op("||") {
            try consume(); node = .binary(.or, node, try parseAnd())
        }
        return node
    }

    mutating func parseAnd() throws -> ExprNode {
        var node = try parseEquality()
        while try peek() == .op("&&") {
            try consume(); node = .binary(.and, node, try parseEquality())
        }
        return node
    }

    mutating func parseEquality() throws -> ExprNode {
        var node = try parseComparison()
        while true {
            let t = try peek()
            if      t == .op("==") { try consume(); node = .binary(.eq, node, try parseComparison()) }
            else if t == .op("!=") { try consume(); node = .binary(.ne, node, try parseComparison()) }
            else { break }
        }
        return node
    }

    mutating func parseComparison() throws -> ExprNode {
        var node = try parseAdditive()
        while true {
            let t = try peek()
            if      t == .op(">")  { try consume(); node = .binary(.gt,  node, try parseAdditive()) }
            else if t == .op("<")  { try consume(); node = .binary(.lt,  node, try parseAdditive()) }
            else if t == .op(">=") { try consume(); node = .binary(.gte, node, try parseAdditive()) }
            else if t == .op("<=") { try consume(); node = .binary(.lte, node, try parseAdditive()) }
            else { break }
        }
        return node
    }

    mutating func parseAdditive() throws -> ExprNode {
        var node = try parseMultiplicative()
        while true {
            let t = try peek()
            if      t == .op("+") { try consume(); node = .binary(.add, node, try parseMultiplicative()) }
            else if t == .op("-") { try consume(); node = .binary(.sub, node, try parseMultiplicative()) }
            else { break }
        }
        return node
    }

    mutating func parseMultiplicative() throws -> ExprNode {
        var node = try parseUnary()
        while true {
            let t = try peek()
            if      t == .op("*") { try consume(); node = .binary(.mul, node, try parseUnary()) }
            else if t == .op("/") { try consume(); node = .binary(.div, node, try parseUnary()) }
            else { break }
        }
        return node
    }

    mutating func parseUnary() throws -> ExprNode {
        let t = try peek()
        if t == .op("-") { try consume(); return .unary(.neg, try parseUnary()) }
        if t == .op("!") { try consume(); return .unary(.not, try parseUnary()) }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> ExprNode {
        let t = try consume()
        switch t {
        case .number(let d):  return .number(d)
        case .bool(let b):    return .bool(b)
        case .tagRef(let n):  return .tagRef(n)

        case .lparen:
            let node = try parseExpr()
            let closing = try consume()
            guard closing == .rparen else { throw ExprError.syntaxError("Expected ')' to close '('") }
            return node

        case .ident(let name):
            if name == "if" {
                // IF <cond> THEN <then> ELSE <else>
                let cond = try parseOr()
                try expect(ident: "then")
                let thenNode = try parseOr()
                try expect(ident: "else")
                let elseNode = try parseOr()
                return .ternary(cond, thenNode, elseNode)
            }
            // Function call: name(arg, ...)
            guard try peek() == .lparen else {
                throw ExprError.syntaxError("Expected '(' after function name '\(name)'")
            }
            try consume()   // consume lparen
            var args: [ExprNode] = []
            if try peek() != .rparen {
                args.append(try parseExpr())
                while try peek() == .comma {
                    try consume()
                    args.append(try parseExpr())
                }
            }
            let close = try consume()
            guard close == .rparen else { throw ExprError.syntaxError("Expected ')' after arguments") }
            return .call(name, args)

        default:
            throw ExprError.syntaxError("Unexpected token in expression")
        }
    }
}

// MARK: - ExpressionParser (public entry points)

enum ExpressionParser {

    /// Parse an expression string into an AST. Throws `ExprError` on syntax error.
    static func parse(_ source: String) throws -> ExprNode {
        var parser = Parser(source)
        let node = try parser.parseExpr()
        guard (try? parser.peek()) == .eof else {
            throw ExprError.syntaxError("Unexpected content after expression")
        }
        return node
    }

    /// Extract all `{TagName}` references from an expression string.
    /// Does a simple scan — no full parse needed.
    static func extractTagRefs(from source: String) -> Set<String> {
        var refs = Set<String>()
        var inBrace = false
        var current = ""
        for ch in source {
            if ch == "{" { inBrace = true; current = "" }
            else if ch == "}" { if inBrace && !current.isEmpty { refs.insert(current) }; inBrace = false }
            else if inBrace { current.append(ch) }
        }
        return refs
    }
}

// MARK: - ExpressionEvaluator

enum ExpressionEvaluator {

    /// Evaluate an already-parsed AST against the live tag dictionary.
    /// Returns a `TagValue` and the worst quality observed across all referenced tags.
    /// - Parameter node: Pre-parsed AST (from `ExpressionParser.parse`)
    /// - Parameter tags: The TagEngine's current tag dictionary
    static func evaluate(_ node: ExprNode, tags: [String: Tag]) throws -> EvalResult {
        var worstQuality: TagQuality = .good

        func markQuality(_ name: String) {
            let q = tags[name]?.quality ?? .bad
            if q == .bad { worstQuality = .bad }
            else if q == .uncertain && worstQuality != .bad { worstQuality = .uncertain }
        }

        func eval(_ n: ExprNode) throws -> Double {
            switch n {
            case .number(let d): return d
            case .bool(let b):   return b ? 1.0 : 0.0

            case .tagRef(let name):
                markQuality(name)
                guard let tag = tags[name] else {
                    worstQuality = .bad
                    return 0.0   // treat missing tag as 0 (bad quality already set)
                }
                return tag.value.numericValue ?? 0.0

            case .binary(let op, let l, let r):
                switch op {
                case .add: return try eval(l) + eval(r)
                case .sub: return try eval(l) - eval(r)
                case .mul: return try eval(l) * eval(r)
                case .div:
                    let rval = try eval(r)
                    guard rval != 0 else { throw ExprError.divisionByZero }
                    return try eval(l) / rval
                case .gt:  return try eval(l) > eval(r)  ? 1 : 0
                case .lt:  return try eval(l) < eval(r)  ? 1 : 0
                case .gte: return try eval(l) >= eval(r) ? 1 : 0
                case .lte: return try eval(l) <= eval(r) ? 1 : 0
                case .eq:  return try eval(l) == eval(r) ? 1 : 0
                case .ne:  return try eval(l) != eval(r) ? 1 : 0
                case .and:
                    let lv = try eval(l)
                    return lv == 0 ? 0 : (try eval(r) != 0 ? 1 : 0)
                case .or:
                    let lv = try eval(l)
                    return lv != 0 ? 1 : (try eval(r) != 0 ? 1 : 0)
                }

            case .unary(let op, let sub):
                switch op {
                case .neg: return try -eval(sub)
                case .not: return try eval(sub) == 0 ? 1 : 0
                }

            case .ternary(let cond, let thenNode, let elseNode):
                return try eval(cond) != 0 ? eval(thenNode) : eval(elseNode)

            case .call(let name, let args):
                return try evalBuiltin(name: name, args: args, eval: eval)
            }
        }

        let result = try eval(node)
        return EvalResult(value: .analog(result), quality: worstQuality)
    }

    /// Evaluate an expression string end-to-end (parse + evaluate).
    /// Never throws — errors are logged and return `.none / .bad`.
    static func evaluate(_ source: String, tags: [String: Tag]) -> EvalResult {
        do {
            let ast = try ExpressionParser.parse(source)
            return try evaluate(ast, tags: tags)
        } catch {
            Logger.shared.error("ExpressionEvaluator: \(error.localizedDescription) in '\(source)'")
            return EvalResult(value: .none, quality: .bad)
        }
    }

    // MARK: - Built-in Functions

    private static func evalBuiltin(
        name: String,
        args: [ExprNode],
        eval: (ExprNode) throws -> Double
    ) throws -> Double {
        let vals = try args.map { try eval($0) }
        switch name.lowercased() {
        // Single-argument
        case "abs":   try expect(name, count: 1, actual: vals.count); return abs(vals[0])
        case "sqrt":  try expect(name, count: 1, actual: vals.count); return sqrt(vals[0])
        case "round": try expect(name, count: 1, actual: vals.count); return Foundation.round(vals[0])
        case "floor": try expect(name, count: 1, actual: vals.count); return Foundation.floor(vals[0])
        case "ceil":  try expect(name, count: 1, actual: vals.count); return Foundation.ceil(vals[0])
        case "sign":  try expect(name, count: 1, actual: vals.count)
                      return vals[0] > 0 ? 1 : (vals[0] < 0 ? -1 : 0)
        // Two-or-more-argument
        case "min":   guard vals.count >= 2 else { throw argCount(name, 2) }; return vals.min()!
        case "max":   guard vals.count >= 2 else { throw argCount(name, 2) }; return vals.max()!
        // Variadic
        case "avg":   guard vals.count >= 1 else { throw argCount(name, 1) }
                      return vals.reduce(0, +) / Double(vals.count)
        case "sum":   guard vals.count >= 1 else { throw argCount(name, 1) }
                      return vals.reduce(0, +)
        // Three-argument
        case "clamp": try expect(name, count: 3, actual: vals.count)
                      return Swift.max(vals[1], Swift.min(vals[2], vals[0]))
        // Ternary as function
        case "if":    try expect(name, count: 3, actual: vals.count)
                      return vals[0] != 0 ? vals[1] : vals[2]
        default:
            throw ExprError.unknownFunction(name)
        }
    }

    private static func expect(_ name: String, count: Int, actual: Int) throws {
        guard actual == count else { throw argCount(name, count) }
    }

    private static func argCount(_ name: String, _ expected: Int) -> ExprError {
        .syntaxError("\(name)() requires \(expected) argument(s)")
    }
}
