// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// O(N) user block filter with strict whitelist recursive-descent static ReDoS rejection.
// Validation rules mirror Java DanmuProvider.BlockFilter 100% identically.

class DanmuRuleValidationResult {
  final bool valid;
  final String error;

  const DanmuRuleValidationResult._(this.valid, this.error);

  static const DanmuRuleValidationResult ok =
      DanmuRuleValidationResult._(true, '');

  factory DanmuRuleValidationResult.fail(String reason) =>
      DanmuRuleValidationResult._(false, reason);
}

class _BranchStats {
  final int unboundedQuants;
  final int detUnboundedQuants;
  final int totalUnboundedQuants;
  final int varQuants;
  final int altGroups;
  final int choices;
  final int maxExpandedLen;
  final int work;

  const _BranchStats(
    this.unboundedQuants,
    this.detUnboundedQuants,
    this.totalUnboundedQuants,
    this.varQuants,
    this.altGroups,
    this.choices,
    this.maxExpandedLen,
    this.work,
  );
}

class _QuantStats {
  static const _QuantStats none = _QuantStats(0, 0, 1, 1, false);
  final int unbounded;
  final int varQuant;
  final int choices;
  final int maxLen;
  final bool lazy;

  const _QuantStats(
    this.unbounded,
    this.varQuant,
    this.choices,
    this.maxLen,
    this.lazy,
  );
}

class _AtomInfo {
  static const int kindOther = 0;
  static const int kindLiteral = 1;
  static const int kindDigit = 2;
  static const int kindSpace = 3;
  static const int kindWord = 4;
  static const int kindAsciiClass = 5;

  static const _AtomInfo other = _AtomInfo(kindOther, -1, null, false);
  static const _AtomInfo dot = _AtomInfo(kindOther, -1, null, true);
  static const _AtomInfo digit = _AtomInfo(kindDigit, -1, null, false);
  static const _AtomInfo space = _AtomInfo(kindSpace, -1, null, false);
  static const _AtomInfo word = _AtomInfo(kindWord, -1, null, false);

  final int kind;
  final int literalCode;
  final List<int>? asciiMask; // 4 x 32-bit ints for 0..127
  final bool isDot;

  const _AtomInfo(this.kind, this.literalCode, this.asciiMask, this.isDot);

  factory _AtomInfo.literal(int code) => _AtomInfo(kindLiteral, code, null, false);

  factory _AtomInfo.asciiClass(List<int> mask) =>
      _AtomInfo(kindAsciiClass, -1, mask, false);

  bool isDisjointFromLiteral(int sepCode) {
    switch (kind) {
      case kindLiteral:
        return _foldAsciiLower(literalCode) != _foldAsciiLower(sepCode);
      case kindDigit:
        return sepCode < 0x30 || sepCode > 0x39;
      case kindSpace:
        return !_isRegexWhitespace(sepCode);
      case kindWord:
        return !((sepCode >= 0x30 && sepCode <= 0x39) ||
            (sepCode >= 0x41 && sepCode <= 0x5A) ||
            (sepCode >= 0x61 && sepCode <= 0x7A) ||
            sepCode == 0x5F);
      case kindAsciiClass:
        if (sepCode < 0 || sepCode >= 128) return true;
        final mask = asciiMask!;
        final folded = _foldAsciiLower(sepCode);
        final matchRaw = (mask[sepCode >>> 5] & (1 << (sepCode & 31))) != 0;
        final matchFold = (mask[folded >>> 5] & (1 << (folded & 31))) != 0;
        return !matchRaw && !matchFold;
      default:
        return false;
    }
  }

  static int _foldAsciiLower(int ch) {
    return (ch >= 0x41 && ch <= 0x5A) ? (ch + 32) : ch;
  }

  static bool _isRegexWhitespace(int ch) {
    return ch == 0x20 ||
        ch == 0x09 ||
        ch == 0x0A ||
        ch == 0x0D ||
        ch == 0x0C ||
        ch == 0x0B ||
        ch == 0x00A0 ||
        ch == 0x1680 ||
        (ch >= 0x2000 && ch <= 0x200A) ||
        ch == 0x2028 ||
        ch == 0x2029 ||
        ch == 0x202F ||
        ch == 0x205F ||
        ch == 0x3000 ||
        ch == 0xFEFF;
  }
}

class _SafeRegexValidator {
  static const int _unboundedChoiceCost = 181;
  static const int _workCap = DanmuBlockFilter.maxTotalWork + 1;

  final String expr;
  final int len;
  int _pos = 0;
  int _wildcardCount = 0;
  int _groupDepth = 0;
  String? _error;

  _SafeRegexValidator(this.expr) : len = expr.length;

  DanmuRuleValidationResult validate() {
    for (var i = 0; i < len; i++) {
      if (_isSurrogateCodeUnit(expr.codeUnitAt(i))) {
        return DanmuRuleValidationResult.fail('正则表达式不支持代理项或扩展平面字符');
      }
    }
    final root = _parseAlternation(isTopLevel: true);
    if (_error != null) {
      return DanmuRuleValidationResult.fail(_error!);
    }
    if (_pos != len) {
      return DanmuRuleValidationResult.fail('正则表达式包含多余的闭合括号');
    }
    if (root == null || root.choices > DanmuBlockFilter.maxTotalChoices) {
      return DanmuRuleValidationResult.fail('正则表达式总回溯分支复杂度过高');
    }
    if (root.totalUnboundedQuants > DanmuBlockFilter.maxTotalUnbounded) {
      return DanmuRuleValidationResult.fail('正则表达式无界量词总数超过安全上限');
    }
    if (root.work > DanmuBlockFilter.maxTotalWork) {
      return DanmuRuleValidationResult.fail('正则表达式总回溯工作量超过安全上限');
    }
    return DanmuRuleValidationResult.ok;
  }

  void _fail(String reason) {
    _error ??= reason;
  }

  static bool _isSurrogateCodeUnit(int codeUnit) {
    return codeUnit >= 0xD800 && codeUnit <= 0xDFFF;
  }

  static int _satAdd(int a, int b) {
    final s = a + b;
    return s >= _workCap ? _workCap : s;
  }

  static int _satMul(int a, int b) {
    final p = a * b;
    return p >= _workCap ? _workCap : p;
  }

  static bool _isQuantStart(int ch) {
    // '*', '+', '?', '{'
    return ch == 0x2A || ch == 0x2B || ch == 0x3F || ch == 0x7B;
  }

  static bool _isHexDigit(int ch) {
    return (ch >= 0x30 && ch <= 0x39) ||
        (ch >= 0x61 && ch <= 0x66) ||
        (ch >= 0x41 && ch <= 0x46);
  }

  static bool _isAsciiPunctuation(int ch) {
    if (ch < 0x21 || ch > 0x7E) return false;
    if (ch >= 0x30 && ch <= 0x39) return false;
    if (ch >= 0x61 && ch <= 0x7A) return false;
    if (ch >= 0x41 && ch <= 0x5A) return false;
    return ch != 0x5F; // '_'
  }

  static int _foldAsciiLower(int ch) {
    return (ch >= 0x41 && ch <= 0x5A) ? (ch + 32) : ch;
  }

  int _peekUnquantifiedLiteralCode() {
    if (_pos >= len) return -1;
    final c = expr.codeUnitAt(_pos);
    if (c == 0x7C || // '|'
        c == 0x29 || // ')'
        c == 0x28 || // '('
        c == 0x5B || // '['
        c == 0x5D || // ']'
        c == 0x7B || // '{'
        c == 0x7D || // '}'
        c == 0x2A || // '*'
        c == 0x2B || // '+'
        c == 0x3F || // '?'
        c == 0x5E || // '^'
        c == 0x24 || // '$'
        c == 0x2E) {
      // '.'
      return -1;
    }
    late final int code;
    late final int afterPos;
    if (c == 0x5C) {
      if (_pos + 1 >= len) return -1;
      final next = expr.codeUnitAt(_pos + 1);
      if (next == 0x74) {
        code = 0x09;
        afterPos = _pos + 2;
      } else if (next == 0x6E) {
        code = 0x0A;
        afterPos = _pos + 2;
      } else if (next == 0x72) {
        code = 0x0D;
        afterPos = _pos + 2;
      } else if (next == 0x66) {
        code = 0x0C;
        afterPos = _pos + 2;
      } else if (_isAsciiPunctuation(next)) {
        code = next;
        afterPos = _pos + 2;
      } else {
        return -1;
      }
    } else {
      code = c;
      afterPos = _pos + 1;
    }
    if (afterPos < len && _isQuantStart(expr.codeUnitAt(afterPos))) {
      return -1;
    }
    return code;
  }

  _BranchStats? _parseAlternation({required bool isTopLevel}) {
    final first = _parseBranch();
    if (_error != null || first == null) return null;
    var maxUnbounded = first.unboundedQuants;
    var maxDetUnbounded = first.detUnboundedQuants;
    var sumTotalUnbounded = first.totalUnboundedQuants;
    var maxVar = first.varQuants;
    var maxAltGroups = first.altGroups;
    var sumChoices = first.choices;
    var maxExpandedLen = first.maxExpandedLen;
    var sumWork = first.work;
    var sumBoundedWork =
        (first.totalUnboundedQuants == 0 && first.choices > 1) ? first.work : 0;
    var branchCount = 1;
    if (isTopLevel) {
      if (!_checkTopLevelTotals(
        sumChoices,
        sumTotalUnbounded,
        sumBoundedWork,
        sumWork,
      )) {
        return null;
      }
    }

    while (_pos < len && expr.codeUnitAt(_pos) == 0x7C) {
      // '|'
      _pos++;
      final next = _parseBranch();
      if (_error != null || next == null) return null;
      branchCount++;
      if (next.unboundedQuants > maxUnbounded) {
        maxUnbounded = next.unboundedQuants;
      }
      if (next.detUnboundedQuants > maxDetUnbounded) {
        maxDetUnbounded = next.detUnboundedQuants;
      }
      sumTotalUnbounded = _satAdd(sumTotalUnbounded, next.totalUnboundedQuants);
      if (next.varQuants > maxVar) {
        maxVar = next.varQuants;
      }
      if (next.altGroups > maxAltGroups) {
        maxAltGroups = next.altGroups;
      }
      if (next.maxExpandedLen > maxExpandedLen) {
        maxExpandedLen = next.maxExpandedLen;
      }
      sumChoices = _satAdd(sumChoices, next.choices);
      sumWork = _satAdd(sumWork, next.work);
      if (next.totalUnboundedQuants == 0 && next.choices > 1) {
        sumBoundedWork = _satAdd(sumBoundedWork, next.work);
      }
      if (isTopLevel) {
        if (!_checkTopLevelTotals(
          sumChoices,
          sumTotalUnbounded,
          sumBoundedWork,
          sumWork,
        )) {
          return null;
        }
      }
    }
    final reportedAltGroups =
        (!isTopLevel && branchCount > 1) ? maxAltGroups + 1 : maxAltGroups;
    return _BranchStats(
      maxUnbounded,
      maxDetUnbounded,
      sumTotalUnbounded,
      maxVar,
      reportedAltGroups,
      sumChoices,
      maxExpandedLen,
      sumWork,
    );
  }

  bool _checkTopLevelTotals(
    int sumChoices,
    int sumTotalUnbounded,
    int sumBoundedWork,
    int sumWork,
  ) {
    if (sumChoices > DanmuBlockFilter.maxTotalChoices) {
      _fail('正则表达式总回溯分支复杂度过高');
      return false;
    }
    if (sumTotalUnbounded > DanmuBlockFilter.maxTotalUnbounded) {
      _fail('正则表达式无界量词总数超过安全上限');
      return false;
    }
    if (sumBoundedWork > DanmuBlockFilter.maxTotalBoundedWork) {
      _fail('正则表达式总回溯工作量超过安全上限');
      return false;
    }
    if (sumWork > DanmuBlockFilter.maxTotalWork) {
      _fail('正则表达式总回溯工作量超过安全上限');
      return false;
    }
    return true;
  }

  _BranchStats? _parseBranch() {
    var unbounded = 0;
    var detUnbounded = 0;
    var totalUnbounded = 0;
    var varQuants = 0;
    var altGroups = 0;
    var choices = 1;
    var maxExpandedLen = 0;
    var work = 0;
    var atomCount = 0;
    var postUnboundedLiterals = 0;
    var postUnboundedNonLiteral = 0;
    final postUnboundedLitCodes =
        List<int>.filled(DanmuBlockFilter.maxPostUnboundedLiterals, 0);
    var postUnboundedLitCount = 0;

    while (_pos < len) {
      final ch = expr.codeUnitAt(_pos);
      if (ch == 0x7C || ch == 0x29) {
        // '|' or ')'
        break;
      }
      atomCount++;

      if (ch == 0x28) {
        // '('
        _pos++;
        if (_pos < len && expr.codeUnitAt(_pos) == 0x3F) {
          // '(?'
          if (_pos + 1 < len && expr.codeUnitAt(_pos + 1) == 0x3A) {
            // '(?:'
            _pos += 2;
          } else if (_pos + 1 < len) {
            final m = expr.codeUnitAt(_pos + 1);
            if (m == 0x3C) {
              _fail('禁止使用正则后行断言');
            } else if (m == 0x2D ||
                (m >= 0x61 && m <= 0x7A) ||
                (m >= 0x41 && m <= 0x5A)) {
              _fail('禁止使用正则内联修饰符');
            } else if (m == 0x3D || m == 0x21) {
              _fail('禁止使用正则环视断言');
            } else {
              _fail('禁止使用不受支持的正则扩展分组');
            }
            return null;
          } else {
            _fail('正则表达式语法错误: 未闭合分组');
            return null;
          }
        }
        _groupDepth++;
        if (_groupDepth > DanmuBlockFilter.maxGroupDepth) {
          _fail('正则分组嵌套层数超过上限');
          return null;
        }
        final inner = _parseAlternation(isTopLevel: false);
        if (_error != null || inner == null) return null;
        _groupDepth--;
        if (_pos >= len || expr.codeUnitAt(_pos) != 0x29) {
          _fail('正则表达式语法错误: 未闭合括号');
          return null;
        }
        _pos++;
        if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
          _fail('禁止闭合括号后紧跟量词以防回溯风险');
          return null;
        }
        if (unbounded > 0) {
          postUnboundedNonLiteral =
              _satAdd(postUnboundedNonLiteral, inner.maxExpandedLen);
          if (postUnboundedNonLiteral >
              DanmuBlockFilter.maxPostUnboundedNonLiteral) {
            _fail('正则表达式无界量词后的非字面后缀超过安全上限');
            return null;
          }
        }
        work = _satAdd(work, _satMul(choices, inner.work));
        unbounded += inner.unboundedQuants;
        detUnbounded += inner.detUnboundedQuants;
        totalUnbounded += inner.totalUnboundedQuants;
        varQuants += inner.varQuants;
        altGroups += inner.altGroups;
        choices = _satMul(choices, inner.choices);
        maxExpandedLen = _satAdd(maxExpandedLen, inner.maxExpandedLen);
        if (!_checkBranchBudget(
          unbounded,
          detUnbounded,
          totalUnbounded,
          varQuants,
          altGroups,
          choices,
          maxExpandedLen,
          work,
        )) {
          return null;
        }
        continue;
      }

      if (_isQuantStart(ch)) {
        _fail('量词缺少前置匹配项');
        return null;
      }
      if (ch == 0x7D || ch == 0x5D) {
        // '}' or ']'
        _fail('正则表达式包含未转义的闭合符号');
        return null;
      }
      if (ch == 0x5E || ch == 0x24) {
        // '^' or '$'
        _pos++;
        if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
          _fail('禁止对零宽断言使用量词');
          return null;
        }
        continue;
      }

      late final _AtomInfo atom;
      if (ch == 0x5B) {
        // '['
        final parsed = _parseCharClass();
        if (_error != null || parsed == null) return null;
        atom = parsed;
      } else if (ch == 0x5C) {
        // '\'
        final parsed = _parseOutsideEscape();
        if (_error != null) return null;
        if (parsed == null) {
          // Zero-width anchor (\b / \B)
          if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
            _fail('禁止对零宽断言使用量词');
            return null;
          }
          continue;
        }
        atom = parsed;
      } else if (ch == 0x2E) {
        // '.'
        _pos++;
        atom = _AtomInfo.dot;
      } else {
        _pos++;
        atom = _AtomInfo.literal(ch);
      }

      final q = _parseQuantifier(isDot: atom.isDot);
      if (_error != null || q == null) return null;

      final isUnquantifiedLiteral = atom.kind == _AtomInfo.kindLiteral &&
          q.unbounded == 0 &&
          q.varQuant == 0 &&
          q.maxLen == 1;

      if (q.unbounded > 0) {
        final nextLit = q.lazy ? -1 : _peekUnquantifiedLiteralCode();
        final deterministic =
            nextLit >= 0 && atom.isDisjointFromLiteral(nextLit);
        work = _satAdd(work, _satMul(choices, _unboundedChoiceCost));
        totalUnbounded += 1;
        varQuants += 1;
        maxExpandedLen = _satAdd(maxExpandedLen, q.maxLen);
        if (deterministic) {
          detUnbounded += 1;
        } else {
          unbounded += 1;
          choices = _satMul(choices, q.choices);
        }
      } else if (q.varQuant > 0) {
        if (unbounded > 0) {
          postUnboundedNonLiteral = _satAdd(postUnboundedNonLiteral, q.maxLen);
          if (postUnboundedNonLiteral >
              DanmuBlockFilter.maxPostUnboundedNonLiteral) {
            _fail('正则表达式无界量词后的非字面后缀超过安全上限');
            return null;
          }
        }
        work = _satAdd(work, _satMul(choices, _satMul(q.choices, q.maxLen)));
        varQuants += 1;
        choices = _satMul(choices, q.choices);
        maxExpandedLen = _satAdd(maxExpandedLen, q.maxLen);
      } else if (unbounded > 0 && isUnquantifiedLiteral) {
        postUnboundedLiterals++;
        if (postUnboundedLiterals > DanmuBlockFilter.maxPostUnboundedLiterals) {
          _fail('正则表达式无界量词后的字面后缀超过安全上限');
          return null;
        }
        final folded = _foldAsciiLower(atom.literalCode);
        var sameCount = 1;
        for (var k = 0; k < postUnboundedLitCount; k++) {
          if (postUnboundedLitCodes[k] == folded) {
            sameCount++;
          }
        }
        if (sameCount > DanmuBlockFilter.maxPostUnboundedSameChar) {
          _fail('正则表达式无界量词后的重复字符后缀超过安全上限');
          return null;
        }
        postUnboundedLitCodes[postUnboundedLitCount++] = folded;
        final litCost = (choices + 3) ~/ 4;
        work = _satAdd(work, litCost);
        maxExpandedLen = _satAdd(maxExpandedLen, 1);
      } else {
        if (unbounded > 0) {
          postUnboundedNonLiteral = _satAdd(postUnboundedNonLiteral, q.maxLen);
          if (postUnboundedNonLiteral >
              DanmuBlockFilter.maxPostUnboundedNonLiteral) {
            _fail('正则表达式无界量词后的非字面后缀超过安全上限');
            return null;
          }
        }
        work = _satAdd(work, _satMul(choices, q.maxLen));
        maxExpandedLen = _satAdd(maxExpandedLen, q.maxLen);
      }

      if (!_checkBranchBudget(
        unbounded,
        detUnbounded,
        totalUnbounded,
        varQuants,
        altGroups,
        choices,
        maxExpandedLen,
        work,
      )) {
        return null;
      }
    }

    if (atomCount == 0) {
      _fail('正则表达式禁止空分支或空分组');
      return null;
    }
    return _BranchStats(
      unbounded,
      detUnbounded,
      totalUnbounded,
      varQuants,
      altGroups,
      choices,
      maxExpandedLen,
      work,
    );
  }

  bool _checkBranchBudget(
    int unbounded,
    int detUnbounded,
    int totalUnbounded,
    int varQuants,
    int altGroups,
    int choices,
    int maxExpandedLen,
    int work,
  ) {
    if (unbounded > DanmuBlockFilter.maxUnboundedPerBranch) {
      _fail('禁止同分支内组合多个无界量词以防回溯风险');
      return false;
    }
    if (detUnbounded > DanmuBlockFilter.maxDetUnboundedPerBranch) {
      _fail('禁止同分支内组合多个无界量词以防回溯风险');
      return false;
    }
    if (totalUnbounded > DanmuBlockFilter.maxTotalUnbounded) {
      _fail('正则表达式无界量词总数超过安全上限');
      return false;
    }
    if (varQuants > DanmuBlockFilter.maxVarQuantsPerBranch) {
      _fail('禁止同分支内组合过多可变长量词以防回溯风险');
      return false;
    }
    if (altGroups > DanmuBlockFilter.maxAltGroupsPerBranch) {
      _fail('禁止同分支内串联过多交替分组以防回溯风险');
      return false;
    }
    final lenLimit = (varQuants > 0 || altGroups > 0)
        ? DanmuBlockFilter.maxBranchExpandedLen
        : DanmuBlockFilter.maxRegexLength;
    if (maxExpandedLen > lenLimit) {
      _fail('正则表达式分支展开长度超过安全上限');
      return false;
    }
    final choiceLimit = unbounded == 0
        ? DanmuBlockFilter.maxBoundedBranchChoices
        : DanmuBlockFilter.maxBranchChoices;
    if (choices > choiceLimit) {
      _fail('正则表达式回溯复杂度过高');
      return false;
    }
    final workLimit = totalUnbounded > 0
        ? DanmuBlockFilter.maxBranchWork
        : (choices == 1
            ? DanmuBlockFilter.maxRegexLength
            : DanmuBlockFilter.maxBoundedBranchWork);
    if (work > workLimit) {
      _fail('正则表达式回溯工作量超过安全上限');
      return false;
    }
    return true;
  }

  _QuantStats? _parseQuantifier({required bool isDot}) {
    if (_pos >= len) return _QuantStats.none;
    final q = expr.codeUnitAt(_pos);
    if (q == 0x2A || q == 0x2B) {
      // '*' or '+'
      _pos++;
      if (isDot) {
        _wildcardCount++;
        if (_wildcardCount > DanmuBlockFilter.maxWildcards) {
          _fail('通配符 .* / .+ 超过 3 次上限');
          return null;
        }
      }
      var lazy = false;
      if (_pos < len && expr.codeUnitAt(_pos) == 0x3F) {
        _pos++;
        lazy = true;
      }
      if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
        _fail('禁止堆叠或占有型量词');
        return null;
      }
      return _QuantStats(1, 1, _unboundedChoiceCost, 1, lazy);
    }
    if (q == 0x3F) {
      // '?'
      _pos++;
      if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
        _fail('禁止堆叠或占有型量词');
        return null;
      }
      return const _QuantStats(0, 1, 2, 1, false);
    }
    if (q == 0x7B) {
      // '{'
      _pos++;
      final minVal = _parseBoundedInt();
      if (_error != null) return null;
      if (_pos >= len) {
        _fail('正则表达式量词花括号未闭合');
        return null;
      }
      final sep = expr.codeUnitAt(_pos);
      if (sep == 0x7D) {
        // '}'
        _pos++;
        if (minVal == 0) {
          _fail('禁止使用零次量词');
          return null;
        }
        if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
          _fail('禁止堆叠或占有型量词');
          return null;
        }
        return _QuantStats(0, 0, 1, minVal, false);
      }
      if (sep == 0x2C) {
        // ','
        _pos++;
        if (_pos < len && expr.codeUnitAt(_pos) == 0x7D) {
          _pos++;
          if (isDot) {
            _wildcardCount++;
            if (_wildcardCount > DanmuBlockFilter.maxWildcards) {
              _fail('通配符 .* / .+ 超过 3 次上限');
              return null;
            }
          }
          var lazy = false;
          if (_pos < len && expr.codeUnitAt(_pos) == 0x3F) {
            _pos++;
            lazy = true;
          }
          if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
            _fail('禁止堆叠或占有型量词');
            return null;
          }
          return _QuantStats(
            1,
            1,
            _unboundedChoiceCost,
            minVal > 1 ? minVal : 1,
            lazy,
          );
        }
        final maxVal = _parseBoundedInt();
        if (_error != null) return null;
        if (_pos >= len || expr.codeUnitAt(_pos) != 0x7D) {
          _fail('正则表达式量词花括号格式无效');
          return null;
        }
        _pos++;
        if (maxVal < minVal) {
          _fail('正则表达式量词上限小于下限');
          return null;
        }
        if (maxVal == 0) {
          _fail('禁止使用零次量词');
          return null;
        }
        if (maxVal == minVal) {
          if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
            _fail('禁止堆叠或占有型量词');
            return null;
          }
          return _QuantStats(0, 0, 1, maxVal, false);
        }
        var lazy = false;
        if (_pos < len && expr.codeUnitAt(_pos) == 0x3F) {
          _pos++;
          lazy = true;
        }
        if (_pos < len && _isQuantStart(expr.codeUnitAt(_pos))) {
          _fail('禁止堆叠或占有型量词');
          return null;
        }
        return _QuantStats(0, 1, maxVal - minVal + 1, maxVal, lazy);
      }
      _fail('正则表达式量词花括号格式无效');
      return null;
    }
    return _QuantStats.none;
  }

  int _parseBoundedInt() {
    final start = _pos;
    var val = 0;
    while (_pos < len) {
      final d = expr.codeUnitAt(_pos);
      if (d < 0x30 || d > 0x39) break;
      val = val * 10 + (d - 0x30);
      if (val > DanmuBlockFilter.maxQuantifierBound) {
        _fail('正则表达式量词数值超过 20 上限');
        return -1;
      }
      _pos++;
    }
    if (_pos == start) {
      _fail('正则表达式量词花括号缺少数字');
      return -1;
    }
    return val;
  }

  /// Returns null for zero-width anchors (\b / \B); otherwise [_AtomInfo].
  _AtomInfo? _parseOutsideEscape() {
    _pos++; // consume '\'
    if (_pos >= len) {
      _fail('正则表达式以未闭合转义符结尾');
      return null;
    }
    final next = expr.codeUnitAt(_pos);
    if ((next >= 0x31 && next <= 0x39) || next == 0x6B) {
      // '1'..'9' or 'k'
      _fail('禁止使用正则反向引用');
      return null;
    }
    if (next == 0x62 || next == 0x42) {
      // 'b' or 'B'
      _pos++;
      return null;
    }
    if (next == 0x64) {
      // 'd'
      _pos++;
      return _AtomInfo.digit;
    }
    if (next == 0x73) {
      // 's'
      _pos++;
      return _AtomInfo.space;
    }
    if (next == 0x77) {
      // 'w'
      _pos++;
      return _AtomInfo.word;
    }
    if (next == 0x44 || next == 0x57 || next == 0x53) {
      // 'D', 'W', 'S'
      _pos++;
      return _AtomInfo.other;
    }
    if (next == 0x74) {
      _pos++;
      return _AtomInfo.literal(0x09);
    }
    if (next == 0x6E) {
      _pos++;
      return _AtomInfo.literal(0x0A);
    }
    if (next == 0x72) {
      _pos++;
      return _AtomInfo.literal(0x0D);
    }
    if (next == 0x66) {
      _pos++;
      return _AtomInfo.literal(0x0C);
    }
    if (next == 0x78) {
      // 'x'
      _pos++;
      final code = _parseFixedHexEscape(2);
      return _error != null ? null : _AtomInfo.literal(code);
    }
    if (next == 0x75) {
      // 'u'
      _pos++;
      final code = _parseFixedHexEscape(4);
      return _error != null ? null : _AtomInfo.literal(code);
    }
    if (_isAsciiPunctuation(next)) {
      _pos++;
      return _AtomInfo.literal(next);
    }
    _fail('禁止使用不受支持的正则转义序列');
    return null;
  }

  int _parseFixedHexEscape(int digits) {
    if (_pos + digits > len) {
      _fail('正则十六进制转义位数不足');
      return -1;
    }
    var value = 0;
    for (var i = 0; i < digits; i++) {
      final h = expr.codeUnitAt(_pos + i);
      if (!_isHexDigit(h)) {
        _fail('正则十六进制转义格式无效');
        return -1;
      }
      final nibble = h <= 0x39
          ? (h - 0x30)
          : (h <= 0x46 ? (h - 0x41 + 10) : (h - 0x61 + 10));
      value = (value << 4) | nibble;
    }
    _pos += digits;
    if (digits == 4 && _isSurrogateCodeUnit(value)) {
      _fail('正则表达式不支持代理项或扩展平面字符');
      return -1;
    }
    return value;
  }

  static void _setAsciiMaskBit(List<int> mask, int code) {
    if (code >= 0 && code < 128) {
      mask[code >>> 5] |= (1 << (code & 31));
      final folded = _foldAsciiLower(code);
      mask[folded >>> 5] |= (1 << (folded & 31));
    }
  }

  _AtomInfo? _parseCharClass() {
    _pos++; // consume '['
    var negated = false;
    if (_pos < len && expr.codeUnitAt(_pos) == 0x5E) {
      _pos++;
      negated = true;
    }
    var itemCount = 0;
    var prevWasSingleChar = false;
    var prevCharCode = -1;
    var pendingRange = false;
    var trackAsciiMask = !negated;
    final asciiMask = trackAsciiMask ? List<int>.filled(4, 0) : null;

    while (_pos < len && expr.codeUnitAt(_pos) != 0x5D) {
      final c = expr.codeUnitAt(_pos);
      if (c == 0x5B) {
        _fail('禁止在字符类中使用未转义的 [');
        return null;
      }
      if (c == 0x26 && _pos + 1 < len && expr.codeUnitAt(_pos + 1) == 0x26) {
        _fail('禁止在字符类中使用交集语法');
        return null;
      }
      if (c == 0x2D &&
          !pendingRange &&
          itemCount > 0 &&
          _pos + 1 < len &&
          expr.codeUnitAt(_pos + 1) != 0x5D) {
        if (!prevWasSingleChar) {
          _fail('字符类范围不能以简写字符类作为起点');
          return null;
        }
        _pos++;
        pendingRange = true;
        continue;
      }

      late final bool isSingleChar;
      late final int charCode;
      if (c == 0x5C) {
        _pos++;
        if (_pos >= len) {
          _fail('正则表达式以未闭合转义符结尾');
          return null;
        }
        final next = expr.codeUnitAt(_pos);
        if (next == 0x64 ||
            next == 0x44 ||
            next == 0x77 ||
            next == 0x57 ||
            next == 0x73 ||
            next == 0x53) {
          _pos++;
          isSingleChar = false;
          charCode = -1;
          trackAsciiMask = false;
        } else if (next == 0x74) {
          _pos++;
          isSingleChar = true;
          charCode = 0x09;
        } else if (next == 0x6E) {
          _pos++;
          isSingleChar = true;
          charCode = 0x0A;
        } else if (next == 0x72) {
          _pos++;
          isSingleChar = true;
          charCode = 0x0D;
        } else if (next == 0x66) {
          _pos++;
          isSingleChar = true;
          charCode = 0x0C;
        } else if (next == 0x78) {
          _pos++;
          charCode = _parseFixedHexEscape(2);
          if (_error != null) return null;
          isSingleChar = true;
        } else if (next == 0x75) {
          _pos++;
          charCode = _parseFixedHexEscape(4);
          if (_error != null) return null;
          isSingleChar = true;
        } else if (_isAsciiPunctuation(next)) {
          _pos++;
          isSingleChar = true;
          charCode = next;
        } else {
          _fail('禁止在字符类中使用不受支持的转义序列');
          return null;
        }
      } else {
        _pos++;
        isSingleChar = true;
        charCode = c;
      }

      if (pendingRange) {
        if (!isSingleChar) {
          _fail('字符类范围不能以简写字符类作为终点');
          return null;
        }
        if (charCode < prevCharCode) {
          _fail('字符类范围起点大于终点');
          return null;
        }
        if (trackAsciiMask) {
          if (prevCharCode >= 0 && charCode < 128) {
            for (var k = prevCharCode; k <= charCode; k++) {
              _setAsciiMaskBit(asciiMask!, k);
            }
          } else {
            trackAsciiMask = false;
          }
        }
        pendingRange = false;
        prevWasSingleChar = false;
      } else {
        if (trackAsciiMask && isSingleChar) {
          if (charCode >= 0 && charCode < 128) {
            _setAsciiMaskBit(asciiMask!, charCode);
          } else {
            trackAsciiMask = false;
          }
        }
        prevWasSingleChar = isSingleChar;
        prevCharCode = charCode;
      }
      itemCount++;
    }

    if (_pos >= len || expr.codeUnitAt(_pos) != 0x5D) {
      _fail('字符类未闭合');
      return null;
    }
    _pos++; // consume ']'
    if (itemCount == 0) {
      _fail('字符类不能为空');
      return null;
    }
    return trackAsciiMask ? _AtomInfo.asciiClass(asciiMask!) : _AtomInfo.other;
  }
}

class DanmuBlockFilter {
  static const int maxRules = 100;
  static const int maxRegexLength = 120;
  static const int maxWildcards = 3;
  static const int maxGroupDepth = 6;
  static const int maxQuantifierBound = 20;
  static const int maxUnboundedPerBranch = 1;
  static const int maxDetUnboundedPerBranch = 1;
  static const int maxTotalUnbounded = 2;
  static const int maxVarQuantsPerBranch = 2;
  static const int maxAltGroupsPerBranch = 2;
  static const int maxBranchExpandedLen = 28;
  static const int maxPostUnboundedLiterals = 10;
  static const int maxPostUnboundedSameChar = 4;
  static const int maxPostUnboundedNonLiteral = 2;
  static const int maxBoundedBranchChoices = 16;
  static const int maxBranchChoices = 550;
  static const int maxTotalChoices = 600;
  static const int maxBoundedBranchWork = 100;
  static const int maxTotalBoundedWork = 160;
  static const int maxBranchWork = 620;
  static const int maxTotalWork = 900;

  static final String _warmupOneByte = 'a' * 36;
  static final String _warmupTwoByte = '\u4e00' * 36;

  static const DanmuBlockFilter empty = DanmuBlockFilter._(
    <String>[],
    <RegExp>[],
  );

  final List<String> _plainLowerRules;
  final List<RegExp> _regexRules;

  const DanmuBlockFilter._(this._plainLowerRules, this._regexRules);

  bool get isEmpty => _plainLowerRules.isEmpty && _regexRules.isEmpty;

  int get ruleCount => _plainLowerRules.length + _regexRules.length;

  static bool _isRuleWhitespace(int ch) {
    return ch <= 0x20 ||
        ch == 0x0085 ||
        ch == 0x00A0 ||
        ch == 0x1680 ||
        (ch >= 0x2000 && ch <= 0x200A) ||
        ch == 0x2028 ||
        ch == 0x2029 ||
        ch == 0x202F ||
        ch == 0x205F ||
        ch == 0x3000 ||
        ch == 0xFEFF;
  }

  static String _trimRule(String raw) {
    var start = 0;
    var end = raw.length;
    while (start < end && _isRuleWhitespace(raw.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isRuleWhitespace(raw.codeUnitAt(end - 1))) {
      end--;
    }
    return (start == 0 && end == raw.length) ? raw : raw.substring(start, end);
  }

  static DanmuRuleValidationResult validateRule(String rawRule) {
    final trimmed = _trimRule(rawRule);
    if (trimmed.isEmpty) {
      return DanmuRuleValidationResult.fail('屏蔽规则不能为空');
    }
    if (!trimmed.startsWith('re:')) {
      return DanmuRuleValidationResult.ok;
    }
    final expr = trimmed.substring(3);
    if (expr.isEmpty) {
      return DanmuRuleValidationResult.fail('正则表达式不能为空');
    }
    if (expr.length > maxRegexLength) {
      return DanmuRuleValidationResult.fail('正则表达式长度超过 120 字符上限');
    }

    final staticCheck = _SafeRegexValidator(expr).validate();
    if (!staticCheck.valid) {
      return staticCheck;
    }

    try {
      RegExp(expr, caseSensitive: false);
    } on FormatException catch (e) {
      return DanmuRuleValidationResult.fail('正则表达式语法错误: ${e.message}');
    }
    return DanmuRuleValidationResult.ok;
  }

  static DanmuBlockFilter compile(Iterable<String> rawRules) {
    final plains = <String>[];
    final regexes = <RegExp>[];
    var accepted = 0;
    for (final raw in rawRules) {
      if (accepted >= maxRules) break;
      final trimmed = _trimRule(raw);
      if (trimmed.isEmpty) continue;
      final vr = validateRule(trimmed);
      if (!vr.valid) continue;
      if (trimmed.startsWith('re:')) {
        final compiled = RegExp(trimmed.substring(3), caseSensitive: false);
        // Eagerly warm both OneByte (Latin-1) and TwoByte (UTF-16/CJK) Dart VM Irregexp
        // native compilation at rule-load time so first-frame UI calls stay < 1ms.
        for (var w = 0; w < 6; w++) {
          compiled.hasMatch(_warmupOneByte);
          compiled.hasMatch(_warmupTwoByte);
        }
        regexes.add(compiled);
      } else {
        plains.add(trimmed.toLowerCase());
      }
      accepted++;
    }
    if (plains.isEmpty && regexes.isEmpty) return empty;
    return DanmuBlockFilter._(
      List<String>.unmodifiable(plains),
      List<RegExp>.unmodifiable(regexes),
    );
  }

  bool isBlocked(String text) {
    if (text.isEmpty || isEmpty) return false;
    if (_plainLowerRules.isNotEmpty) {
      final lower = text.toLowerCase();
      for (var i = 0; i < _plainLowerRules.length; i++) {
        if (lower.contains(_plainLowerRules[i])) return true;
      }
    }
    for (var i = 0; i < _regexRules.length; i++) {
      if (_regexRules[i].hasMatch(text)) return true;
    }
    return false;
  }
}
