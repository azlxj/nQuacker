// lib/client/nitter_backend.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:quacker/profile/profile_model.dart';
import 'package:quacker/user.dart';
import 'package:logging/logging.dart';

/// Backend بديل يعتمد على Nitter بدلاً من تويتر الرسمي.
/// هذا كود أولي (minimal) يدعم:
/// - getProfileByScreenName
/// - getUserTimeline (تغريدات الحساب)
///
/// ملاحظة: تحتاج تضبط SELECTORs بعد ما تشوف HTML الحقيقي من الـ instance اللي تستخدمه.
class NitterBackend {
  static final _log = Logger('NitterBackend');

  /// غيّر هذا إلى الـ instance المفضل عندك أو خله من الإعدادات
  final String host;

  NitterBackend({this.host = 'nitter.net'});

  Uri _buildUri(String path, [Map<String, String>? params]) {
    return Uri.https(host, path, params);
  }

  /// جلب بروفايل مستخدم عن طريق screenName من Nitter.
  Future<Profile> getProfileByScreenName(String screenName) async {
    final uri = _buildUri('/$screenName');
    _log.info('Nitter profile GET $uri');

    final response = await http.get(uri);

    if (response.statusCode == 404) {
      throw TwitterError(
        uri: uri.toString(),
        code: 404,
        message: 'User not found on Nitter',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TwitterError(
        uri: uri.toString(),
        code: response.statusCode,
        message: 'Nitter error while loading profile',
      );
    }

    final doc = html_parser.parse(response.body);

    // NOTE: هذه الـ selectors تقريبية، تحتاج تضبطها على حسب HTML الحقيقي للـ instance
    final fullNameEl = doc.querySelector('.profile-card-fullname');
    final userNameEl = doc.querySelector('.profile-card-username');
    final avatarEl = doc.querySelector('.profile-card-avatar img');
    final bioEl = doc.querySelector('.profile-bio');
    final statsEls = doc.querySelectorAll('.profile-stat');

    final fullName = fullNameEl?.text.trim().replaceAll('\n', ' ') ?? screenName;
    // في نيتّر غالباً username يكون مثل "@user" فنشيله@
    var username = userNameEl?.text.trim() ?? screenName;
    if (username.startsWith('@')) {
      username = username.substring(1);
    }

    final avatarPath = avatarEl?.attributes['src'];
    final avatarUrl =
        (avatarPath != null && avatarPath.startsWith('http'))
            ? avatarPath
            : (avatarPath != null ? 'https://$host$avatarPath' : null);

    final bio = bioEl?.text.trim() ?? '';

    int followers = 0;
    int following = 0;
    int tweetsCount = 0;

    for (final el in statsEls) {
      final label = el.text.toLowerCase();
      final numberEl = el.querySelector('span');
      final raw = numberEl?.text.trim() ?? '0';
      final value = _parseCount(raw);

      if (label.contains('followers')) {
        followers = value;
      } else if (label.contains('following')) {
        following = value;
      } else if (label.contains('tweets')) {
        tweetsCount = value;
      }
    }

    final user = UserWithExtra.fromJson({
      'id_str': username, // نستخدم username كمعرّف افتراضي
      'name': fullName,
      'screen_name': username,
      'description': bio,
      'followers_count': followers,
      'friends_count': following,
      'statuses_count': tweetsCount,
      'profile_image_url_https': avatarUrl,
      // الحقول الأخرى ممكن تزوّدها لاحقاً حسب الحاجة
    });

    // nQuacker يتوقع Profile(user, pins). هنا لا يوجد pinned من Nitter فنرسل قائمة فاضية
    return Profile(user, const []);
  }

  /// جلب تايملاين المستخدم من Nitter.
  /// يرجّع قائمة من TweetWithCard بسيطة (نملأ الحقول الأساسية فقط).
  Future<List<TweetWithCard>> getUserTimeline(String screenName) async {
    final uri = _buildUri('/$screenName');
    _log.info('Nitter timeline GET $uri');

    final response = await http.get(uri);

    if (response.statusCode == 404) {
      // لا يوجد تغريدات / حساب
      return [];
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TwitterError(
        uri: uri.toString(),
        code: response.statusCode,
        message: 'Nitter error while loading timeline',
      );
    }

    final doc = html_parser.parse(response.body);

    // NOTE: selectors تقريبية، تحتاج تفحص HTML الفعلي
    final tweetEls = doc.querySelectorAll('.timeline-item');

    final tweets = <TweetWithCard>[];

    for (final el in tweetEls) {
      try {
        final contentEl = el.querySelector('.tweet-content');
        final timeEl = el.querySelector('a.tweet-date');
        final statsEl = el.querySelector('.tweet-stats');

        final text = contentEl?.text.trim().replaceAll('\n', ' ') ?? '';

        String? tweetId;
        if (timeEl != null) {
          final href = timeEl.attributes['href'] ?? '';
          // مثلاً: /username/status/1234567890
          final parts = href.split('/');
          tweetId = parts.isNotEmpty ? parts.last : null;
        }

        int replies = 0;
        int retweets = 0;
        int likes = 0;

        if (statsEl != null) {
          final statSpans = statsEl.querySelectorAll('span');
          for (final s in statSpans) {
            final raw = s.text.trim();
            final value = _parseCount(raw);
            final title = s.attributes['title']?.toLowerCase() ?? '';

            if (title.contains('repl')) {
              replies = value;
            } else if (title.contains('retweet')) {
              retweets = value;
            } else if (title.contains('like')) {
              likes = value;
            }
          }
        }

        final tweet = TweetWithCard();
        tweet.idStr = tweetId;
        tweet.fullText = text;
        tweet.text = text;
        tweet.replyCount = replies;
        tweet.retweetCount = retweets;
        tweet.favoriteCount = likes;
        // المستخدم نأخذه من البروفايل (بما أن الصفحة صفحة المستخدم نفسه)
        tweet.user = UserWithExtra.fromJson({
          'id_str': screenName,
          'screen_name': screenName,
        });

        tweets.add(tweet);
      } catch (e, st) {
        _log.warning('Failed to parse Nitter tweet: $e\n$st');
      }
    }

    return tweets;
  }

  int _parseCount(String raw) {
    // يحوّل "1,234" أو "1.2K" أو "3M" إلى رقم صحيح تقريباً
    var s = raw.replaceAll(',', '').toLowerCase();
    if (s.endsWith('k')) {
      final v = double.tryParse(s.substring(0, s.length - 1)) ?? 0;
      return (v * 1000).round();
    }
    if (s.endsWith('m')) {
      final v = double.tryParse(s.substring(0, s.length - 1)) ?? 0;
      return (v * 1000000).round();
    }
    return int.tryParse(s) ?? 0;
  }
}

/// نفس كلاس الخطأ الموجود في client.dart
class TwitterError implements Exception {
  final String uri;
  final int code;
  final String message;

  TwitterError({required this.uri, required this.code, required this.message});

  @override
  String toString() => 'TwitterError{code: $code, message: $message, url: $uri}';
}
