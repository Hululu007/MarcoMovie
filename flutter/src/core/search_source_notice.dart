import 'dart:async';
import 'models.dart';

import 'catpaw_host.dart';

/// User-facing search failures use trusted messages, never server response text,
/// subscription addresses, or download credentials.
String searchSourceNotice(Object error) {
  if (error is DrpySourceException &&
      error.code == 'drpy_verification_required') {
    return '需要完成网站验证码，暂时无法搜索';
  }
  if (error is TimeoutException) return '请求超时，请稍后重试';
  return '暂时无法读取，请稍后重试或更换片源';
}

/// Disambiguate imported sources without exposing configuration URLs or IDs.
String searchSourceLabel(
    CmsSite site, List<CmsSite> sites, List<SubscriptionEntry> subscriptions) {
  final duplicates = sites.where((s) => s.name == site.name).toList();
  if (duplicates.length < 2) return site.name;
  final owners = subscriptions.where((s) => s.id == site.subscriptionId);
  final owner = owners.isEmpty ? '' : owners.first.name.trim();
  final index = duplicates.indexWhere(
      (s) => s.key == site.key && s.subscriptionId == site.subscriptionId);
  return '${site.name}（${owner.isEmpty ? '线路' : owner} ${index + 1}）';
}
