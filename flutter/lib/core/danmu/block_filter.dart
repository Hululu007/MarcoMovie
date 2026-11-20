// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// O(N) user block filter with strict single-pass static ReDoS rejection.

class DanmuRuleValidationResult {
  final bool valid;
  final String error;

  const DanmuRuleValidationResult._(this.valid, this.error);

  static const DanmuRuleValidationResult ok =
      DanmuRuleValidationResult._(true, '');

  factory DanmuRuleValidationResult.fail(String reason) =>
      DanmuRuleValidationResult._(false, reason);
}

class DanmuBlockFilter {
  static const int maxRules = 100;
  static const int maxRegexLength = 120;
  static const int maxWildcards = 3;

  static const DanmuBlockFilter empty = DanmuBlockFilter._(
    <String>[],
    <RegExp>[],
  );

  final List<String> _plainLowerRules;
  final List<RegExp> _regexRules;

  const DanmuBlockFilter._(this._plainLowerRules, this._regexRules);

  bool get isEmpty => _plainLowerRules.isEmpty && _regexRules.isEmpty;

  int get ruleCount => _plainLowerRules.length + _regexRules.length;

  static DanmuRuleValidationResult validateRule(String rawRule) {
    final trimmed = rawRule.trim();
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

    var inCharClass = false;
    var wildcardCount = 0;
    final len = expr.length;

    for (var i = 0; i < len; i++) {
      final ch = expr.codeUnitAt(i);
      // '\' escape
      if (ch == 0x5C) {
        if (i + 1 >= len) {
          return DanmuRuleValidationResult.fail('正则表达式以未闭合转义符结尾');
        }
        final next = expr.codeUnitAt(i + 1);
        if (!inCharClass && next >= 0x31 && next <= 0x39) {
          return DanmuRuleValidationResult.fail('禁止使用正则反向引用');
        }
        i++;
        continue;
      }
      if (inCharClass) {
        if (ch == 0x5D) {
          inCharClass = false;
        }
        continue;
      }
      // '[' character class start
      if (ch == 0x5B) {
        inCharClass = true;
        if (i + 1 < len && expr.codeUnitAt(i + 1) == 0x5E) {
          i++;
        }
        if (i + 1 < len && expr.codeUnitAt(i + 1) == 0x5D) {
          i++;
        }
        continue;
      }
      // '(?' lookbehind or inline modifier check
      if (ch == 0x28 && i + 1 < len && expr.codeUnitAt(i + 1) == 0x3F) {
        if (i + 2 < len) {
          final m = expr.codeUnitAt(i + 2);
          if (m == 0x3C) {
            return DanmuRuleValidationResult.fail('禁止使用正则后行断言');
          }
          if (m == 0x2D ||
              (m >= 0x61 && m <= 0x7A) ||
              (m >= 0x41 && m <= 0x5A)) {
            return DanmuRuleValidationResult.fail('禁止使用正则内联修饰符');
          }
        }
      }
      // '.*' or '.+'
      if (ch == 0x2E && i + 1 < len) {
        final next = expr.codeUnitAt(i + 1);
        if (next == 0x2A || next == 0x2B) {
          wildcardCount++;
          if (wildcardCount > maxWildcards) {
            return DanmuRuleValidationResult.fail('通配符 .* / .+ 超过 3 次上限');
          }
        }
      }
      // ')' followed by quantifier (*, +, ?, {) -> reject catastrophic backtracking
      if (ch == 0x29 && i + 1 < len) {
        final next = expr.codeUnitAt(i + 1);
        if (next == 0x2A || next == 0x2B || next == 0x3F || next == 0x7B) {
          return DanmuRuleValidationResult.fail('禁止闭合括号后紧跟量词以防回溯风险');
        }
      }
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
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final vr = validateRule(trimmed);
      if (!vr.valid) continue;
      if (trimmed.startsWith('re:')) {
        regexes.add(RegExp(trimmed.substring(3), caseSensitive: false));
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
